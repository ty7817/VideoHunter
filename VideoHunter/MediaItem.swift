//
//  MediaItem.swift
//  VideoHunter
//
//  从网页里识别出来的一个媒体地址。
//

import Foundation

enum MediaKind: String, CaseIterable {
    case hls
    case mp4
    case dash
    case webm
    case other

    var label: String {
        switch self {
        case .hls: return "HLS"
        case .mp4: return "MP4"
        case .dash: return "DASH"
        case .webm: return "WEBM"
        case .other: return "MEDIA"
        }
    }

    var symbolName: String {
        switch self {
        case .hls: return "dot.radiowaves.left.and.right"
        case .mp4: return "film"
        case .dash: return "square.stack.3d.up"
        case .webm: return "globe"
        case .other: return "play.rectangle"
        }
    }

    /// 数字越小越优先展示。
    var rank: Int {
        switch self {
        case .hls: return 0
        case .mp4: return 1
        case .dash: return 2
        case .webm: return 3
        case .other: return 4
        }
    }
}

enum Playability: Equatable {
    /// AVPlayer 可以直接播放（HLS / MP4）。
    case native
    /// 需要复制到 Safari 或第三方播放器。
    case external
    /// blob: 之类只在网页内部有效。
    case inPage

    var rank: Int {
        switch self {
        case .native: return 0
        case .external: return 1
        case .inPage: return 2
        }
    }

    var hint: String {
        switch self {
        case .native:
            return "内置播放器可以直接播放这个链接。"
        case .external:
            return "这个格式 AVPlayer 不支持，可以复制链接用 Safari、VLC 等播放器打开。"
        case .inPage:
            return "这是网页内部生成的加密媒体流（blob:），只能在原网页里播放，无法单独提取。"
        }
    }
}

struct MediaItem: Identifiable, Hashable {
    let id: UUID
    let url: URL
    var kind: MediaKind
    let source: String
    let pageTitle: String
    let frameURL: String?
    let createdAt: Date

    init(
        url: URL,
        kind: MediaKind,
        source: String,
        pageTitle: String = "",
        frameURL: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = UUID()
        self.url = url
        self.kind = kind
        self.source = source
        self.pageTitle = pageTitle
        self.frameURL = frameURL
        self.createdAt = createdAt
    }

    var key: String { url.absoluteString }

    var host: String { url.host ?? (url.scheme ?? "") }

    var fileName: String {
        let last = url.lastPathComponent
        if last.isEmpty || last == "/" {
            return url.absoluteString
        }
        return last.removingPercentEncoding ?? last
    }

    var isInPageOnly: Bool {
        guard let scheme = url.scheme?.lowercased() else { return true }
        return scheme == "blob" || scheme == "data"
    }

    var playability: Playability {
        if isInPageOnly { return .inPage }
        switch kind {
        case .hls, .mp4:
            return .native
        case .dash, .webm, .other:
            return .external
        }
    }
}
