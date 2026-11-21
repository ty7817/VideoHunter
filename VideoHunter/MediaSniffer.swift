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

    /// 主文档地址，用于判断 iframe 是否跨站。
    var mainDocumentURL: URL?
    /// 默认只接收主文档和同站 iframe；用户可显式打开跨站 iframe。
    var allowCrossSiteFrames = false

    private var generation = 0
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

    func beginGeneration(_ value: Int) {
        generation = value
        reset()
    }

    func advance(to value: Int) {
        guard value > generation else { return }
        generation = value
        reset()
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == Self.handlerName else { return }
        guard let body = message.body as? [String: Any] else { return }
        if let incoming = body["generation"] as? NSNumber {
            let value = incoming.intValue
            if value < generation { return }
            if value > generation { advance(to: value) }
        }
        guard FramePolicy.shouldAccept(
            frameInfo: message.frameInfo,
            body: body,
            mainURL: mainDocumentURL,
            allowCrossSite: allowCrossSiteFrames
        ) else { return }
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
        let isIframe = (body["isIframe"] as? Bool) ?? !message.frameInfo.isMainFrame

        var thumb: URL?
        if let rawThumb = body["thumb"] as? String,
           let thumbURL = URL(string: rawThumb),
           thumbURL.scheme != nil {
            thumb = thumbURL
        }

        ingest(MediaItem(
            url: url,
            kind: kind,
            source: source,
            pageTitle: title,
            frameURL: frame,
            thumbnailURL: thumb,
            isIframe: isIframe
        ))
    }

    // MARK: - 入库

    private func ingest(_ item: MediaItem) {
        if let existing = store[item.key] {
            // 同一个地址，如果这次识别出了更精确的类型或补上了预览图，就升级一下。
            var updated = existing
            var changed = false
            if item.kind.rank < existing.kind.rank {
                updated.kind = item.kind
                changed = true
            }
            if existing.thumbnailURL == nil, item.thumbnailURL != nil {
                updated.thumbnailURL = item.thumbnailURL
                changed = true
            }
            if changed {
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
