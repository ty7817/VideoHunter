//
//  ThumbnailView.swift
//  VideoHunter
//
//  视频预览图：优先用页面 poster / og:image / 列表图，
//  带 Cookie + Referer 多次尝试；仍失败时对 MP4 抽取视频首帧兜底。
//

import SwiftUI
import UIKit
import AVFoundation

enum ThumbnailStore {
    static var maxWidth: CGFloat {
        AppSettings.shared.thumbnailSize.thumbnailMaxWidth
    }

    static func cached(for url: URL) -> UIImage? {
        RemoteImageLoader.cachedThumbnail(for: url, maxWidth: maxWidth)
    }

    static func load(for url: URL, referer: String?) async -> UIImage? {
        await RemoteImageLoader.thumbnail(for: url, referer: referer, maxWidth: maxWidth)
    }
}

enum VideoFrameStore {
    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 80
        cache.totalCostLimit = 24 * 1024 * 1024
        return cache
    }()

    static func applyCacheLimit(_ megabytes: Int) {
        cache.totalCostLimit = max(8, megabytes) * 1024 * 1024
    }
    private static let frameLimiter = AsyncLimiter(limit: 2)

    static func frame(for item: MediaItem) async -> UIImage? {
        guard item.kind == .mp4 else { return nil }
        let key = item.url.absoluteString as NSString
        if let cached = cache.object(forKey: key) { return cached }

        var headers: [String: String] = [
            "User-Agent": BrowserController.mobileUserAgentString,
            "Accept": "video/mp4,video/*;q=0.9,*/*;q=0.5"
        ]
        if let referer = item.frameURL, !referer.isEmpty {
            headers["Referer"] = referer
        }
        if let cookies = HTTPCookieStorage.shared.cookies(for: item.url), !cookies.isEmpty {
            let fields = HTTPCookie.requestHeaderFields(with: cookies)
            if let cookie = fields["Cookie"] { headers["Cookie"] = cookie }
        }
        let asset = AVURLAsset(url: item.url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 360, height: 240)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 2, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 2, preferredTimescale: 600)

        let time = CMTime(seconds: 1.0, preferredTimescale: 600)
        return await frameLimiter.withPermit {
            let cgImage: CGImage? = await Task.detached(priority: .utility) {
                do {
                    return try generator.copyCGImage(at: time, actualTime: nil)
                } catch {
                    return nil
                }
            }.value
            guard let cgImage else { return nil }
            let image = UIImage(cgImage: cgImage)
            cache.setObject(image, forKey: key, cost: cost(of: image))
            return image
        }
    }

    static func clearMemory() {
        cache.removeAllObjects()
    }

    private static func cost(of image: UIImage) -> Int {
        if let cgImage = image.cgImage {
            return max(1, cgImage.bytesPerRow * cgImage.height)
        }
        return max(1, Int(image.size.width * image.scale * image.size.height * image.scale * 4))
    }
}

struct MediaThumbnail: View {
    let item: MediaItem
    var width: CGFloat = 0
    var height: CGFloat = 0

    @ObservedObject private var settings = AppSettings.shared
    @State private var image: UIImage?
    @State private var loading = false
    @State private var failed = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(MediaRowView.tint(item.kind).opacity(0.14))

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else if loading {
                ProgressView()
                    .controlSize(.mini)
                    .tint(MediaRowView.tint(item.kind))
            } else {
                Image(systemName: failed ? "exclamationmark.triangle" : item.kind.symbolName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(MediaRowView.tint(item.kind))
            }
        }
        .frame(width: resolvedWidth, height: resolvedHeight)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06))
        )
        .task(id: "\(item.key)|\(item.thumbnailURL?.absoluteString ?? "")") {
            await loadThumbnail()
        }
    }

    private var resolvedWidth: CGFloat {
        width > 0 ? width : settings.thumbnailSize.width
    }

    private var resolvedHeight: CGFloat {
        height > 0 ? height : settings.thumbnailSize.height
    }

    private func loadThumbnail() async {
        // 列表复用时先把旧图清掉，避免新条目瞬间闪出上一条视频的封面。
        image = nil
        loading = true
        failed = false

        guard settings.loadVideoThumbnails else {
            loading = false
            return
        }

        if let url = item.thumbnailURL {
            if let cached = ThumbnailStore.cached(for: url) {
                image = cached
                loading = false
                return
            }
            if let loaded = await ThumbnailStore.load(for: url, referer: item.frameURL) {
                guard !Task.isCancelled else { return }
                image = loaded
                loading = false
                return
            }
        }

        guard !Task.isCancelled else { return }
        if let frame = await VideoFrameStore.frame(for: item) {
            guard !Task.isCancelled else { return }
            image = frame
            loading = false
            return
        }

        guard !Task.isCancelled else { return }
        failed = true
        loading = false
    }
}
