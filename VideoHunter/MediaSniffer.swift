//
//  MediaSniffer.swift
//  VideoHunter
//
//  接收注入脚本上报的媒体地址，去重、排序后交给界面展示。
//

import Foundation
import WebKit
import Combine

final class MediaSniffer: NSObject, ObservableObject, WKScriptMessageHandler {

    static let handlerName = "vhMedia"

    /// 单个页面最多保留多少条，避免某些站点把列表撑爆。
    private static let maxItems = 200

    @Published private(set) var items: [MediaItem] = []

    private var store: [String: MediaItem] = [:]
    private var order: [String] = []
    private var flushWork: DispatchWorkItem?

    // MARK: - 生命周期

    func reset() {
        flushWork?.cancel()
        flushWork = nil
        store.removeAll()
        order.removeAll()
        if !items.isEmpty {
            items = []
        }
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == Self.handlerName else { return }
        guard let body = message.body as? [String: Any] else { return }
        guard let raw = (body["url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return
        }
        guard let url = URL(string: raw), url.scheme != nil else { return }
        guard !Self.isSegment(url) else { return }
        guard url.absoluteString != "about:blank" else { return }

        var kind = MediaKind(rawValue: (body["kind"] as? String) ?? "") ?? .other
        if kind == .other {
            kind = Self.inferKind(url)
        }

        let title = (body["title"] as? String) ?? ""
        let frame = body["frame"] as? String
        let source = (body["via"] as? String) ?? "dom"

        ingest(MediaItem(url: url, kind: kind, source: source, pageTitle: title, frameURL: frame))
    }

    // MARK: - 入库

    private func ingest(_ item: MediaItem) {
        if let existing = store[item.key] {
            // 同一个地址，如果这次识别出了更精确的类型，就升级一下。
            if item.kind.rank < existing.kind.rank {
                var updated = existing
                updated.kind = item.kind
                store[item.key] = updated
                scheduleFlush()
            }
            return
        }
        guard store.count < Self.maxItems else { return }
        store[item.key] = item
        order.append(item.key)
        scheduleFlush()
    }

    private func scheduleFlush() {
        flushWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.flush()
        }
        flushWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func flush() {
        let snapshot = order.compactMap { store[$0] }.sorted(by: Self.isOrderedBefore)
        if snapshot != items {
            items = snapshot
        }
    }

    private static func isOrderedBefore(_ lhs: MediaItem, _ rhs: MediaItem) -> Bool {
        if lhs.playability.rank != rhs.playability.rank {
            return lhs.playability.rank < rhs.playability.rank
        }
        if lhs.kind.rank != rhs.kind.rank {
            return lhs.kind.rank < rhs.kind.rank
        }
        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt < rhs.createdAt
        }
        return lhs.key < rhs.key
    }

    // MARK: - 类型判断

    static func isSegment(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ["ts", "m4s", "cmfv", "cmfa", "aac", "vtt", "key"].contains(ext)
    }

    static func inferKind(_ url: URL) -> MediaKind {
        switch url.pathExtension.lowercased() {
        case "m3u8", "m3u":
            return .hls
        case "mpd":
            return .dash
        case "mp4", "m4v", "mov":
            return .mp4
        case "webm", "flv", "ogv":
            return .webm
        default:
            return .other
        }
    }

    /// 判断一次主文档导航的响应是不是可以直接播放的媒体文件。
    static func kind(for url: URL, mimeType: String?) -> MediaKind? {
        let ext = url.pathExtension.lowercased()
        let mime = (mimeType ?? "").lowercased()
        if mime.contains("text/html") { return nil }

        if ext == "m3u8" || ext == "m3u" || mime.contains("mpegurl") { return .hls }
        if ext == "mpd" || mime.contains("dash+xml") { return .dash }
        if ext == "mp4" || ext == "m4v" || ext == "mov"
            || mime == "video/mp4" || mime == "video/quicktime" || mime == "video/x-m4v" {
            return .mp4
        }
        if ext == "webm" || mime == "video/webm" { return .webm }
        return nil
    }
}
