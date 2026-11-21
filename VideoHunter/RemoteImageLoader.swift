import Foundation
import UIKit
import ImageIO

/// 限制图片/视频首帧的同时加载数量，避免快速滚动时打满网络和 CPU。
actor AsyncLimiter {
    private var limit: Int
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        let safeLimit = max(1, min(6, limit))
        self.limit = safeLimit
        self.available = safeLimit
    }

    func updateLimit(_ newValue: Int) {
        let safe = max(1, min(6, newValue))
        guard safe != limit else { return }
        if safe > limit {
            available += safe - limit
            limit = safe
            while available > 0, !waiters.isEmpty {
                available -= 1
                waiters.removeFirst().resume()
            }
        } else {
            let reduction = limit - safe
            available = max(0, available - reduction)
            limit = safe
        }
    }

    func withPermit<T>(_ operation: () async -> T) async -> T {
        await acquire()
        defer { release() }
        return await operation()
    }

    private func acquire() async {
        if available > 0 {
            available -= 1
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters.append(continuation)
        }
    }

    private func release() {
        if waiters.isEmpty {
            available = min(limit, available + 1)
        } else {
            let next = waiters.removeFirst()
            next.resume()
        }
    }
}

enum RemoteImageLoader {
    /// 图片/视频预览图同时请求数量，跟随设置中心的「图片并发」。
    private static let loadLimiter = AsyncLimiter(limit: AppSettings.shared.imageConcurrency)
    private static var maxOriginalPixelSize: CGFloat { AppSettings.shared.imageQuality.maxPixelSize }
    private static let maxDownloadBytes = 30 * 1024 * 1024

    static let thumbnailCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 240
        cache.totalCostLimit = 36 * 1024 * 1024
        return cache
    }()

    static let originalCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 12
        cache.totalCostLimit = 72 * 1024 * 1024
        return cache
    }()

    static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.httpCookieStorage = HTTPCookieStorage.shared
        configuration.httpShouldSetCookies = true
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 28
        configuration.urlCache = URLCache(memoryCapacity: 24 * 1024 * 1024,
                                          diskCapacity: 120 * 1024 * 1024,
                                          diskPath: "vh.image.cache")
        return URLSession(configuration: configuration)
    }()

    static func cachedThumbnail(for url: URL, maxWidth: CGFloat) -> UIImage? {
        let key = "\(url.absoluteString)|\(Int(maxWidth))" as NSString
        return thumbnailCache.object(forKey: key)
    }

    static func image(for url: URL, referer: String?) async -> UIImage? {
        let key = "\(url.absoluteString)|\(Int(maxOriginalPixelSize))" as NSString
        if let cached = originalCache.object(forKey: key) { return cached }
        guard let data = await fetchData(url: url, referer: referer),
              let image = decodedImage(from: data, maxPixelSize: maxOriginalPixelSize) else { return nil }
        originalCache.setObject(image, forKey: key, cost: cost(of: image))
        return image
    }

    static func thumbnail(for url: URL, referer: String?, maxWidth: CGFloat) async -> UIImage? {
        let key = "\(url.absoluteString)|\(Int(maxWidth))" as NSString
        if let cached = thumbnailCache.object(forKey: key) { return cached }
        guard let data = await fetchData(url: url, referer: referer),
              let image = decodedImage(from: data, maxPixelSize: thumbnailPixelSize(for: maxWidth)) else { return nil }
        thumbnailCache.setObject(image, forKey: key, cost: cost(of: image))
        return image
    }

    static func updateConcurrency(_ value: Int) async {
        await loadLimiter.updateLimit(value)
    }

    static func applyCacheLimits(thumbnailMB: Int, originalMB: Int) {
        thumbnailCache.totalCostLimit = max(12, thumbnailMB) * 1024 * 1024
        originalCache.totalCostLimit = max(24, originalMB) * 1024 * 1024
    }

    static func clearMemory() {
        thumbnailCache.removeAllObjects()
        originalCache.removeAllObjects()
    }

    static func clearDiskCache() {
        thumbnailCache.removeAllObjects()
        originalCache.removeAllObjects()
        session.configuration.urlCache?.removeAllCachedResponses()
        URLCache.shared.removeAllCachedResponses()
    }

    private static func fetchData(url: URL, referer: String?) async -> Data? {
        await loadLimiter.withPermit {
            await fetchDataWithoutPermit(url: url, referer: referer)
        }
    }

    private static func fetchDataWithoutPermit(url: URL, referer: String?) async -> Data? {
        if url.scheme?.lowercased() == "data" {
            guard let data = decodeDataURI(url.absoluteString),
                  data.count <= maxDownloadBytes,
                  containsImageData(data) else { return nil }
            return data
        }

        var candidates: [String?] = []
        if let referer, !referer.isEmpty {
            candidates.append(referer)
            if let origin = originString(from: referer), origin != referer {
                candidates.append(origin)
            }
        }
        candidates.append(nil)

        var visited: [String] = []
        for candidate in candidates {
            let marker = candidate ?? "<none>"
            if visited.contains(marker) { continue }
            visited.append(marker)

            var request = URLRequest(url: url,
                                     cachePolicy: .returnCacheDataElseLoad,
                                     timeoutInterval: 15)
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("image/avif,image/webp,image/apng,image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
            request.setValue("zh-CN,zh;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
            if let referer = candidate {
                request.setValue(referer, forHTTPHeaderField: "Referer")
            }
            let cookies = HTTPCookieStorage.shared.cookies(for: url)
            if let cookies, !cookies.isEmpty {
                let fields = HTTPCookie.requestHeaderFields(with: cookies)
                for (name, value) in fields {
                    request.setValue(value, forHTTPHeaderField: name)
                }
            }

            do {
                let (data, response) = try await session.data(for: request)
                if let http = response as? HTTPURLResponse, !(200..<400).contains(http.statusCode) {
                    continue
                }
                if let mime = response.mimeType?.lowercased(),
                   mime.contains("text/html") || mime.contains("text/plain") {
                    continue
                }
                guard !data.isEmpty,
                      data.count <= maxDownloadBytes,
                      containsImageData(data) else { continue }
                return data
            } catch {
                continue
            }
        }
        return nil
    }

    private static func containsImageData(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        return CGImageSourceGetCount(source) > 0
    }

    /// 使用 ImageIO 按目标像素尺寸解码，避免 UIImage(data:) 先把整张原图展开。
    private static func decodedImage(from data: Data, maxPixelSize: CGFloat) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, Int(maxPixelSize))
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }

    private static func thumbnailPixelSize(for maxWidth: CGFloat) -> CGFloat {
        min(1600, max(160, maxWidth * UIScreen.main.scale))
    }

    private static func originString(from raw: String) -> String? {
        guard let url = URL(string: raw), let scheme = url.scheme, let host = url.host else { return nil }
        var origin = "\(scheme)://\(host)"
        if let port = url.port { origin += ":\(port)" }
        return origin
    }

    private static func decodeDataURI(_ raw: String) -> Data? {
        guard raw.lowercased().hasPrefix("data:"),
              let comma = raw.firstIndex(of: ",") else { return nil }
        let meta = String(raw[raw.index(raw.startIndex, offsetBy: 5)..<comma]).lowercased()
        let payload = String(raw[raw.index(after: comma)...])
        if meta.contains(";base64") {
            return Data(base64Encoded: payload, options: [.ignoreUnknownCharacters])
        }
        if let decoded = payload.removingPercentEncoding {
            return Data(decoded.utf8)
        }
        return nil
    }

    private static func cost(of image: UIImage) -> Int {
        if let cgImage = image.cgImage {
            return max(1, cgImage.bytesPerRow * cgImage.height)
        }
        return max(1, Int(image.size.width * image.scale * image.size.height * image.scale * 4))
    }

    private static var userAgent: String {
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
    }
}
