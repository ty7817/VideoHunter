//
//  ThumbnailView.swift
//  VideoHunter
//
//  视频预览图：优先用页面里的 poster / og:image / 列表缩略图，
//  带 Referer 和 UA 下载，解码后缩小缓存，失败时回落到类型图标。
//

import SwiftUI
import UIKit

enum ThumbnailStore {

    private static let cache = NSCache<NSString, UIImage>()

    static func cached(for url: URL) -> UIImage? {
        cache.object(forKey: url.absoluteString as NSString)
    }

    static func load(for url: URL, referer: String?) async -> UIImage? {
        if let cached = cached(for: url) {
            return cached
        }

        var request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 12)
        request.setValue(BrowserController.mobileUserAgentString, forHTTPHeaderField: "User-Agent")
        request.setValue("image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
        if let referer = referer, !referer.isEmpty {
            request.setValue(referer, forHTTPHeaderField: "Referer")
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode < 400 else { return nil }
            guard data.count < 12 * 1024 * 1024, let image = UIImage(data: data) else { return nil }
            let small = downscale(image, maxWidth: 240)
            cache.setObject(small, forKey: url.absoluteString as NSString)
            return small
        } catch {
            return nil
        }
    }

    private static func downscale(_ image: UIImage, maxWidth: CGFloat) -> UIImage {
        let width = image.size.width
        guard width > maxWidth, width > 0 else { return image }
        let scale = maxWidth / width
        let size = CGSize(width: maxWidth, height: max(image.size.height * scale, 1))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}

struct MediaThumbnail: View {
    let item: MediaItem
    var width: CGFloat = 64
    var height: CGFloat = 40

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(MediaRowView.tint(item.kind).opacity(0.14))

            if let image = image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: item.kind.symbolName)
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
        .task(id: item.thumbnailURL?.absoluteString) {
            guard let url = item.thumbnailURL else { return }
            if let cached = ThumbnailStore.cached(for: url) {
                image = cached
                return
            }
            let loaded = await ThumbnailStore.load(for: url, referer: item.frameURL)
            guard !Task.isCancelled else { return }
            if let loaded = loaded {
                image = loaded
            }
        }
    }
}
