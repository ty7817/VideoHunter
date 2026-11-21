import Foundation
import WebKit
import Combine

enum ImageCategory: String, CaseIterable, Identifiable {
    case screenshot
    case cover
    case product
    case art
    case wallpaper
    case avatar
    case icon
    case other

    var id: String { rawValue }

    var label: String {
        switch self {
        case .screenshot: return "截图"
        case .cover: return "封面海报"
        case .product: return "商品图"
        case .art: return "插画艺术"
        case .wallpaper: return "壁纸背景"
        case .avatar: return "头像"
        case .icon: return "图标"
        case .other: return "其他"
        }
    }

    var symbolName: String {
        switch self {
        case .screenshot: return "camera.viewfinder"
        case .cover: return "rectangle.on.rectangle"
        case .product: return "bag"
        case .art: return "paintbrush.pointed"
        case .wallpaper: return "photo.on.rectangle.angled"
        case .avatar: return "person.crop.circle"
        case .icon: return "app.dashed"
        case .other: return "photo"
        }
    }

    var sortRank: Int {
        switch self {
        case .screenshot: return 0
        case .cover: return 1
        case .product: return 2
        case .art: return 3
        case .wallpaper: return 4
        case .avatar: return 5
        case .icon: return 6
        case .other: return 7
        }
    }
}

struct ImageItem: Identifiable, Hashable {
    let id: UUID
    let url: URL
    var width: Int
    var height: Int
    var alt: String
    let pageTitle: String
    let frameURL: String
    let source: String
    let context: String
    let createdAt: Date
    let isIframe: Bool

    init(id: UUID = UUID(),
         url: URL,
         width: Int,
         height: Int,
         alt: String,
         pageTitle: String,
         frameURL: String,
         source: String,
         context: String,
         createdAt: Date = Date(),
         isIframe: Bool = false) {
        self.id = id
        self.url = url
        self.width = max(0, width)
        self.height = max(0, height)
        self.alt = alt
        self.pageTitle = pageTitle
        self.frameURL = frameURL
        self.source = source
        self.context = context
        self.createdAt = createdAt
        self.isIframe = isIframe
    }

    var key: String { url.absoluteString }
    var category: ImageCategory { ImageClassifier.category(for: self) }
    var area: Int64 { Int64(width) * Int64(height) }

    var fileName: String {
        let name = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
        return name.isEmpty ? (url.host ?? "网页图片") : name
    }

    var host: String { url.host ?? "" }

    var resolutionText: String {
        if width > 0 && height > 0 { return "\(width) × \(height)" }
        return "尺寸待加载"
    }

    var isLarge: Bool {
        width >= 1200 || height >= 1200 || area >= 1_500_000
    }

    static func == (lhs: ImageItem, rhs: ImageItem) -> Bool { lhs.key == rhs.key }
    func hash(into hasher: inout Hasher) { hasher.combine(key) }
}

enum ImageClassifier {
    static func category(for item: ImageItem) -> ImageCategory {
        let urlText = (item.url.absoluteString + " " + item.url.path).lowercased()
        let elementText = (item.alt + " " + item.context).lowercased()

        func has(_ words: [String]) -> Bool {
            for word in words {
                if urlText.contains(word) || elementText.contains(word) { return true }
            }
            return false
        }

        if has(["screenshot", "screen shot", "screen-shot", "screen_capture", "screen-capture", "截图", "截屏"]) {
            return .screenshot
        }
        if has(["avatar", "headshot", "profile_pic", "profile-pic", "userpic", "头像"]) {
            return .avatar
        }
        if has(["product", "goods", "sku", "商品", "主图", "白底图", "detail_img"]) {
            return .product
        }
        if has(["poster", "cover", "banner", "海报", "封面", "剧照", "keyart", "key-art"]) {
            return .cover
        }
        if has(["illustration", "artwork", "drawing", "插画", "原画", "概念图", "concept", "cg_"]) {
            return .art
        }
        if has(["wallpaper", "壁纸", "背景图", "desktop background"]) {
            return .wallpaper
        }

        let tiny = item.width > 0 && item.height > 0 && item.width <= 96 && item.height <= 96
        if tiny || has(["icon", "logo", "favicon", "emoji", "sprite", "图标"]) {
            return .icon
        }

        if item.height > 0 && item.width / item.height >= 3 && item.width >= 800 {
            return .cover
        }
        return .other
    }
}

final class ImageSniffer: NSObject, ObservableObject, WKScriptMessageHandler {
    static let handlerName = "vhImage"
    private static var maxItems: Int { max(100, AppSettings.shared.maxImageItems) }

    @Published private(set) var items: [ImageItem] = []

    var mainDocumentURL: URL?
    var allowCrossSiteFrames = false
    private var generation = 0

    private var publishWorkItem: DispatchWorkItem?

    func reset() {
        publishWorkItem?.cancel()
        publishWorkItem = nil
        items = []
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

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.name == Self.handlerName,
              AppSettings.shared.scanImages,
              let body = message.body as? [String: Any] else { return }
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
        guard let raw = body["url"] as? String,
              !raw.isEmpty,
              let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return }

        let width = intValue(body["width"])
        let height = intValue(body["height"])
        let alt = (body["alt"] as? String) ?? ""
        let title = (body["title"] as? String) ?? ""
        let frame = (body["frame"] as? String) ?? ""
        let via = (body["via"] as? String) ?? "img"
        let context = (body["context"] as? String) ?? ""
        let isIframe = (body["isIframe"] as? Bool) ?? !message.frameInfo.isMainFrame

        if let index = items.firstIndex(where: { $0.url.absoluteString == url.absoluteString }) {
            var existing = items[index]
            var changed = false
            if existing.width == 0 && width > 0 {
                existing.width = width
                changed = true
            }
            if existing.height == 0 && height > 0 {
                existing.height = height
                changed = true
            }
            if existing.alt.isEmpty && !alt.isEmpty {
                existing.alt = alt
                changed = true
            }
            if !changed { return }
            items[index] = existing
            schedulePublish()
            return
        }

        guard items.count < Self.maxItems else { return }

        let item = ImageItem(url: url,
                             width: width,
                             height: height,
                             alt: alt,
                             pageTitle: title,
                             frameURL: frame,
                             source: via,
                             context: context,
                             isIframe: isIframe)
        items.append(item)
        schedulePublish()
    }

    private func intValue(_ value: Any?) -> Int {
        if let number = value as? NSNumber { return max(0, number.intValue) }
        if let text = value as? String { return max(0, Int(text) ?? 0) }
        return 0
    }

    private func schedulePublish() {
        publishWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.items.sort { lhs, rhs in
                if lhs.category.sortRank != rhs.category.sortRank {
                    return lhs.category.sortRank < rhs.category.sortRank
                }
                if lhs.area != rhs.area { return lhs.area > rhs.area }
                return lhs.createdAt > rhs.createdAt
            }
        }
        publishWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }
}
