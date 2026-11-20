import Foundation
import UIKit

enum RemoteImageLoader {
    static let thumbnailCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 260
        cache.totalCostLimit = 40 * 1024 * 1024
        return cache
    }()

    static let originalCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 40
        cache.totalCostLimit = 90 * 1024 * 1024
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

    static func image(for url: URL, referer: String?) async -> UIImage? {
        let key = url.absoluteString as NSString
        if let cached = originalCache.object(forKey: key) { return cached }
        guard let data = await fetchData(url: url, referer: referer),
              let image = UIImage(data: data) else { return nil }
        originalCache.setObject(image, forKey: key, cost: cost(of: image))
        return image
    }

    static func thumbnail(for url: URL, referer: String?, maxWidth: CGFloat) async -> UIImage? {
        let key = "\(url.absoluteString)|\(Int(maxWidth))" as NSString
        if let cached = thumbnailCache.object(forKey: key) { return cached }
        guard let data = await fetchData(url: url, referer: referer),
              let image = UIImage(data: data) else { return nil }
        let thumb = downscaled(image, maxWidth: maxWidth)
        thumbnailCache.setObject(thumb, forKey: key, cost: cost(of: thumb))
        return thumb
    }

    static func clearMemory() {
        thumbnailCache.removeAllObjects()
        originalCache.removeAllObjects()
    }

    private static func fetchData(url: URL, referer: String?) async -> Data? {
        if url.scheme?.lowercased() == "data" {
            return decodeDataURI(url.absoluteString)
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
                guard !data.isEmpty, data.count <= 30 * 1024 * 1024 else { continue }
                if UIImage(data: data) != nil { return data }
            } catch {
                continue
            }
        }
        return nil
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

    private static func downscaled(_ image: UIImage, maxWidth: CGFloat) -> UIImage {
        let pixelWidth = image.size.width * image.scale
        let pixelHeight = image.size.height * image.scale
        guard pixelWidth > 0, pixelHeight > 0 else { return image }

        var scale = min(1, (maxWidth * UIScreen.main.scale) / pixelWidth)
        let maxPixels: CGFloat = 4_000_000
        let currentPixels = pixelWidth * pixelHeight
        if currentPixels * scale * scale > maxPixels {
            scale = min(scale, sqrt(maxPixels / currentPixels))
        }
        if scale >= 0.98 { return image }

        let target = CGSize(width: max(1, floor(pixelWidth * scale)),
                            height: max(1, floor(pixelHeight * scale)))
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }

    private static func cost(of image: UIImage) -> Int {
        Int(image.size.width * image.scale * image.size.height * image.scale * 4)
    }

    private static var userAgent: String {
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
    }
}
