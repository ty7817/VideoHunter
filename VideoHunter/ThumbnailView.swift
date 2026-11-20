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
    private static let cache = NSCache<NSString, UIImage>()

    static func cached(for url: URL) -> UIImage? {
        cache.object(forKey: url.absoluteString as NSString)
    }

    static func load(for url: URL, referer: String?) async -> UIImage? {
        if let cached = cached(for: url) { return cached }
        let image = await RemoteImageLoader.thumbnail(for: url, referer: referer, maxWidth: 300)
        if let image {
            cache.setObject(image, forKey: url.absoluteString as NSString)
        }
        return image
    }
}

enum VideoFrameStore {
    private static let cache = NSCache<NSString, UIImage>()

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
        return await Task.detached(priority: .utility) { () -> UIImage? in
            do {
                let cgImage = try generator.copyCGImage(at: time, actualTime: nil)
                let image = UIImage(cgImage: cgImage)
                cache.setObject(image, forKey: key)
                return image
            } catch {
                return nil
            }
        }.value
    }
}

struct MediaThumbnail: View {
    let item: MediaItem
    var width: CGFloat = 64
    var height: CGFloat = 40

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
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06))
        )
        .task(id: "\(item.key)|\(item.thumbnailURL?.absoluteString ?? "")") {
            await loadThumbnail()
        }
    }

    private func loadThumbnail() async {
        loading = true
        failed = false

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
