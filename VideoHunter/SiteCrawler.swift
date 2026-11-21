//
//  SiteCrawler.swift
//  VideoHunter
//
//  整站扫描：从起始页出发，用多个隐藏 WKWebView 并发打开站内页面，
//  收集每一页里的视频地址。并发数可调，默认 3 路。
//

import Foundation
import WebKit
import UIKit
import Combine

struct CrawledPage: Identifiable {
    let id = UUID()
    let url: URL
    let title: String
    let depth: Int
    var items: [MediaItem]
    var images: [ImageItem] = []

    var displayTitle: String {
        if !title.isEmpty { return title }
        let last = url.lastPathComponent
        if !last.isEmpty && last != "/" { return last.removingPercentEncoding ?? last }
        return url.host ?? url.absoluteString
    }
}

// MARK: - 单页抓取结果

struct CrawlImage {
    let url: String
    let width: Int
    let height: Int
    let alt: String
    let frame: String
    let via: String
    let context: String
    let isIframe: Bool
}

struct CrawlHarvest {
    let url: URL?
    let title: String
    let links: [String]
    let media: [(url: String, kind: String, thumb: String, isIframe: Bool)]
    let images: [CrawlImage]
}

// MARK: - 抓取工作线程

final class CrawlWorker: NSObject {

    private var webView: WKWebView?
    private var pending = false
    private var completion: ((CrawlHarvest) -> Void)?
    private var buffer: [String: (url: String, kind: String, thumb: String, isIframe: Bool)] = [:]
    private var order: [String] = []
    private var imageBuffer: [String: CrawlImage] = [:]
    private var imageOrder: [String] = []
    private var settleWork: DispatchWorkItem?
    private var timeoutWork: DispatchWorkItem?
    private var generation = 0
    private var pageURL: URL?
    private var pageTitle = ""
    var allowCrossSiteFrames = false

    private static let autoScrollScript = """
    (function () {
      try {
        var body = document.body;
        if (!body) { return true; }
        var step = Math.max(window.innerHeight, 320) * 0.9;
        var round = 0;
        var timer = setInterval(function () {
          try {
            window.scrollBy(0, step);
            round++;
            if (round >= 6 || window.scrollY + window.innerHeight >= body.scrollHeight - 4) {
              clearInterval(timer);
            }
          } catch (e) { clearInterval(timer); }
        }, 100);
      } catch (e) {}
      return true;
    })();
    """

    func prepare() {
        guard webView == nil else { return }

        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.allowsInlineMediaPlayback = false

        let controller = WKUserContentController()
        controller.addUserScript(
            WKUserScript(
                source: InjectedScript.source,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            )
        )
        for script in PluginStore.shared.userScripts() {
            controller.addUserScript(script)
        }
        controller.add(self, name: MediaSniffer.handlerName)
        controller.add(self, name: ImageSniffer.handlerName)
        configuration.userContentController = controller

        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 2, height: 2), configuration: configuration)
        view.navigationDelegate = self
        view.customUserAgent = BrowserController.mobileUserAgentString
        SiteCrawler.attachToWindow(view)
        webView = view
    }

    func load(
        _ url: URL,
        settle: TimeInterval = 0.55,
        timeout: TimeInterval = 16,
        completion: @escaping (CrawlHarvest) -> Void
    ) {
        guard !pending, let view = webView else {
            completion(CrawlHarvest(url: url, title: "", links: [], media: [], images: []))
            return
        }

        pending = true
        buffer.removeAll()
        order.removeAll()
        imageBuffer.removeAll()
        imageOrder.removeAll()
        pageTitle = ""
        pageURL = url
        self.completion = completion
        generation &+= 1
        let gen = generation

        view.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 18))

        timeoutWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.pending, gen == self.generation else { return }
            self.webView?.stopLoading()
            self.harvest(gen)
        }
        timeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: work)
    }

    func stop() {
        pending = false
        generation &+= 1
        settleWork?.cancel()
        settleWork = nil
        timeoutWork?.cancel()
        timeoutWork = nil
        completion = nil
        webView?.stopLoading()
        if let view = webView {
            view.configuration.userContentController.removeScriptMessageHandler(forName: MediaSniffer.handlerName)
            view.configuration.userContentController.removeScriptMessageHandler(forName: ImageSniffer.handlerName)
            view.removeFromSuperview()
        }
        webView = nil
    }

    // MARK: - 抓取流程

    private func scheduleHarvest(after delay: TimeInterval) {
        guard pending else { return }
        settleWork?.cancel()
        let gen = generation
        let work = DispatchWorkItem { [weak self] in
            self?.harvest(gen)
        }
        settleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func harvest(_ gen: Int) {
        guard pending, gen == generation, let view = webView else { return }

        view.evaluateJavaScript(Self.autoScrollScript) { [weak self] _, _ in
            guard let self = self, self.pending, gen == self.generation else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { [weak self] in
                guard let self = self, self.pending, gen == self.generation else { return }
                view.evaluateJavaScript("window.__vhRescan ? (window.__vhRescan(), true) : true") { [weak self] _, _ in
                    guard let self = self, self.pending, gen == self.generation else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                        guard let self = self, self.pending, gen == self.generation else { return }
                        self.collect(gen)
                    }
                }
            }
        }
    }

    private func collect(_ gen: Int) {
        guard pending, gen == generation, let view = webView else { return }
        let script = "window.__vhCollectLinks ? window.__vhCollectLinks(80) : '{\"links\":[],\"media\":[]}'"
        view.evaluateJavaScript(script) { [weak self] result, _ in
            guard let self = self, self.pending, gen == self.generation else { return }
            self.finish(payload: result as? String)
        }
    }

    private func finish(payload: String?) {
        guard pending else { return }
        pending = false
        settleWork?.cancel()
        timeoutWork?.cancel()

        if let view = webView {
            pageURL = view.url ?? pageURL
            if let title = view.title, !title.isEmpty {
                pageTitle = title
            }
        }

        var links: [String] = []
        var payloadTitle = ""
        var payloadURL = ""

        if let payload = payload, let data = payload.data(using: .utf8) {
            do {
                let object = try JSONSerialization.jsonObject(with: data, options: [])
                if let dict = object as? [String: Any] {
                    if let rawLinks = dict["links"] as? [String] {
                        links = rawLinks
                    }
                    if let title = dict["title"] as? String {
                        payloadTitle = title
                    }
                    if let address = dict["url"] as? String {
                        payloadURL = address
                    }
                    if let rawMedia = dict["media"] as? [[String: Any]] {
                        for entry in rawMedia {
                            guard let raw = entry["url"] as? String else { continue }
                            let kind = (entry["kind"] as? String) ?? ""
                            let thumb = (entry["thumb"] as? String) ?? ""
                            let isIframe = (entry["isIframe"] as? Bool) ?? false
                            append(url: raw, kind: kind, thumb: thumb, isIframe: isIframe)
                        }
                    }
                }
            } catch {
                // 页面结构异常时忽略链接，仍然把已抓到的媒体交回去。
            }
        }

        if pageTitle.isEmpty && !payloadTitle.isEmpty {
            pageTitle = payloadTitle
        }
        if let address = URL(string: payloadURL), address.scheme != nil {
            pageURL = address
        }

        let media = order.compactMap { buffer[$0] }
        let images = imageOrder.compactMap { imageBuffer[$0] }
        let handler = completion
        completion = nil
        handler?(CrawlHarvest(url: pageURL, title: pageTitle, links: links, media: media, images: images))
    }

    private func append(url: String, kind: String, thumb: String, isIframe: Bool = false) {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let parsed = URL(string: trimmed), parsed.scheme != nil else { return }
        guard !MediaSniffer.isSegment(parsed) else { return }
        if let existing = buffer[trimmed] {
            if existing.thumb.isEmpty && !thumb.isEmpty {
                buffer[trimmed] = (url: trimmed, kind: existing.kind, thumb: thumb, isIframe: existing.isIframe || isIframe)
            }
            return
        }
        buffer[trimmed] = (url: trimmed, kind: kind, thumb: thumb, isIframe: isIframe)
        order.append(trimmed)
    }

    private func appendImage(_ body: [String: Any]) {
        guard let raw = body["url"] as? String,
              let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return }
        let trimmed = url.absoluteString
        guard imageBuffer.index(forKey: trimmed) == nil else { return }
        let width = (body["width"] as? NSNumber)?.intValue ?? 0
        let height = (body["height"] as? NSNumber)?.intValue ?? 0
        let alt = (body["alt"] as? String) ?? ""
        let frame = (body["frame"] as? String) ?? ""
        let via = (body["via"] as? String) ?? "img"
        let context = (body["context"] as? String) ?? ""
        let isIframe = (body["isIframe"] as? Bool) ?? false
        imageBuffer[trimmed] = CrawlImage(
            url: trimmed,
            width: width,
            height: height,
            alt: alt,
            frame: frame,
            via: via,
            context: context,
            isIframe: isIframe
        )
        imageOrder.append(trimmed)
    }
}

// MARK: - 调度器

final class SiteCrawler: NSObject, ObservableObject {

    // MARK: 设置

    @Published var maxPages: Int = 60
    @Published var maxDepth: Int = 3
    @Published var concurrency: Int = 3
    @Published var onlySameSite: Bool = true
    @Published var includeSubdomains: Bool = true
    @Published private(set) var allowCrossSiteFrames = false

    // MARK: 状态

    @Published private(set) var isRunning = false
    @Published private(set) var visitedCount = 0
    @Published private(set) var foundCount = 0
    @Published private(set) var foundImageCount = 0
    @Published private(set) var currentURL = ""
    @Published private(set) var pages: [CrawledPage] = []
    @Published private(set) var statusText = ""
    @Published private(set) var elapsedSeconds = 0
    @Published private(set) var startHost = ""
    @Published private(set) var sitemapCount = 0
    @Published private(set) var activeWorkers = 0
    @Published private(set) var pagesPerMinute = 0

    private struct Candidate {
        let url: URL
        let depth: Int
    }

    private var workers: [CrawlWorker] = []
    private var idleWorkers: [CrawlWorker] = []
    private var queue: [Candidate] = []
    private var queuedKeys: Set<String> = []
    private var visitedKeys: Set<String> = []
    private var mediaKeys: Set<String> = []
    private var imageKeys: Set<String> = []
    private var activeCount = 0
    private var hitLimit = false

    private var startedAt: Date?
    private var clock: Timer?
    private var sitemapPending = false

    private var baseHost = ""
    private var baseSite = ""
    private var landingURL: URL?

    private static let queueLimit = 600
    private static let sitemapLimit = 150
    private static let maxSitemapChildren = 3
    private static let maxConcurrency = 4

    // MARK: - 对外接口

    func setAllowCrossSiteFrames(_ enabled: Bool) {
        allowCrossSiteFrames = enabled
        workers.forEach { $0.allowCrossSiteFrames = enabled }
    }

    func start(from url: URL) {
        guard !isRunning else { return }
        reset()

        guard let host = url.host?.lowercased(), !host.isEmpty else {
            statusText = "这个地址没有域名，无法做整站扫描"
            return
        }

        landingURL = url
        baseHost = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        baseSite = Self.siteKey(host)
        startHost = baseHost
        isRunning = true
        startedAt = Date()
        elapsedSeconds = 0

        let count = max(1, min(concurrency, Self.maxConcurrency))
        workers = (0..<count).map { _ in
            let worker = CrawlWorker()
            worker.allowCrossSiteFrames = allowCrossSiteFrames
            worker.prepare()
            return worker
        }
        idleWorkers = workers

        enqueue(url, depth: 0)

        if onlySameSite {
            sitemapPending = true
            statusText = "启动 \(count) 路并发，同时读取 sitemap.xml…"
            loadSitemapSeed(baseURL: url)
        } else {
            statusText = "启动 \(count) 路并发扫描"
        }

        pump()
        startClock()
    }

    func cancel() {
        guard isRunning else { return }
        isRunning = false
        sitemapPending = false
        queue.removeAll()
        workers.forEach { $0.stop() }
        workers.removeAll()
        idleWorkers.removeAll()
        activeCount = 0
        activeWorkers = 0
        clock?.invalidate()
        clock = nil
        statusText = pages.isEmpty
            ? "扫描已取消，共查看 \(visitedCount) 个页面，没有留下结果"
            : "扫描已取消，已保留 \(pages.count) 个页面、\(foundCount) 个视频、\(foundImageCount) 张图片"
    }

    // MARK: - 状态复位

    private func reset() {
        queue.removeAll()
        queuedKeys.removeAll()
        visitedKeys.removeAll()
        mediaKeys.removeAll()
        imageKeys.removeAll()
        workers.forEach { $0.stop() }
        workers.removeAll()
        idleWorkers.removeAll()
        activeCount = 0
        activeWorkers = 0
        hitLimit = false
        sitemapPending = false

        pages = []
        visitedCount = 0
        foundCount = 0
        foundImageCount = 0
        currentURL = ""
        statusText = ""
        elapsedSeconds = 0
        pagesPerMinute = 0
        sitemapCount = 0
        activeWorkers = 0
        clock?.invalidate()
        clock = nil
    }

    private func startClock() {
        clock?.invalidate()
        clock = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self, let started = self.startedAt else { return }
            let seconds = Int(Date().timeIntervalSince(started))
            self.elapsedSeconds = seconds
            if seconds > 1 {
                self.pagesPerMinute = Int(Double(self.visitedCount) / Double(seconds) * 60)
            }
        }
    }

    // MARK: - 队列

    private func enqueue(_ url: URL, depth: Int) {
        guard depth <= maxDepth else { return }
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return }
        if onlySameSite && !inScope(url) { return }
        if Self.isOtherResource(url) { return }

        let key = Self.key(url)
        if queuedKeys.contains(key) { return }
        if queue.count >= Self.queueLimit { return }

        queuedKeys.insert(key)
        insert(Candidate(url: url, depth: depth))
    }

    private func insert(_ candidate: Candidate) {
        let score = Self.priority(candidate.url)
        var index = queue.endIndex
        for (offset, existing) in queue.enumerated() {
            if existing.depth > candidate.depth {
                index = offset
                break
            }
            if existing.depth == candidate.depth && Self.priority(existing.url) < score {
                index = offset
                break
            }
        }
        queue.insert(candidate, at: index)
    }

    // MARK: - 调度

    private func pump() {
        guard isRunning else { return }

        while activeCount < workers.count && !queue.isEmpty && !hitLimit {
            let candidate = queue.removeFirst()
            let key = Self.key(candidate.url)
            if visitedKeys.contains(key) { continue }

            if visitedKeys.count >= maxPages {
                hitLimit = true
                queue.removeAll()
                break
            }

            visitedKeys.insert(key)
            visitedCount = visitedKeys.count
            dispatch(candidate)
        }

        if queue.isEmpty && activeCount == 0 && !sitemapPending {
            finish(reason: hitLimit ? "已达到页数上限" : nil)
        }
    }

    private func dispatch(_ candidate: Candidate) {
        guard let worker = idleWorkers.popLast() else { return }
        activeCount += 1
        activeWorkers = activeCount
        currentURL = candidate.url.absoluteString

        worker.load(candidate.url, settle: 0.55, timeout: 16) { [weak self] harvest in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.handle(harvest, candidate: candidate, worker: worker)
            }
        }
    }

    private func handle(_ harvest: CrawlHarvest, candidate: Candidate, worker: CrawlWorker) {
        activeCount = max(0, activeCount - 1)
        activeWorkers = activeCount
        idleWorkers.append(worker)

        guard isRunning else { return }

        let pageURL = harvest.url ?? candidate.url
        if harvest.url != nil {
            let key = Self.key(pageURL)
            if !visitedKeys.contains(key) {
                visitedKeys.insert(key)
                visitedCount = visitedKeys.count
            }
        }

        var kept: [MediaItem] = []
        for entry in harvest.media {
            guard let url = URL(string: entry.url), url.scheme != nil else { continue }
            guard !MediaSniffer.isSegment(url) else { continue }
            guard !mediaKeys.contains(entry.url) else { continue }
            mediaKeys.insert(entry.url)

            var kind = MediaKind(rawValue: entry.kind) ?? .other
            if kind == .other {
                kind = MediaSniffer.inferKind(url)
            }

            var thumb: URL?
            if let thumbURL = URL(string: entry.thumb), thumbURL.scheme != nil {
                thumb = thumbURL
            }

            kept.append(MediaItem(
                url: url,
                kind: kind,
                source: "page",
                pageTitle: harvest.title,
                frameURL: pageURL.absoluteString,
                thumbnailURL: thumb,
                isIframe: entry.isIframe
            ))
        }

        var keptImages: [ImageItem] = []
        for entry in harvest.images {
            guard let url = URL(string: entry.url), url.scheme != nil else { continue }
            guard !imageKeys.contains(entry.url) else { continue }
            imageKeys.insert(entry.url)
            keptImages.append(ImageItem(
                url: url,
                width: entry.width,
                height: entry.height,
                alt: entry.alt,
                pageTitle: harvest.title,
                frameURL: entry.frame,
                source: entry.via,
                context: entry.context,
                isIframe: entry.isIframe
            ))
        }

        if !kept.isEmpty || !keptImages.isEmpty {
            pages.append(CrawledPage(
                url: pageURL,
                title: harvest.title,
                depth: candidate.depth,
                items: kept,
                images: keptImages
            ))
            foundCount += kept.count
            foundImageCount += keptImages.count
        }

        for link in harvest.links {
            guard let url = URL(string: link) else { continue }
            enqueue(url, depth: candidate.depth + 1)
        }

        pump()
    }

    // MARK: - sitemap 预加载

    private func loadSitemapSeed(baseURL: URL) {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            sitemapPending = false
            pump()
            return
        }
        components.path = "/sitemap.xml"
        components.query = nil
        components.fragment = nil

        guard let sitemapURL = components.url else {
            sitemapPending = false
            pump()
            return
        }

        fetchSitemap(sitemapURL) { [weak self] locs, isIndex in
            DispatchQueue.main.async {
                guard let self = self, self.isRunning else { return }

                if isIndex && !locs.isEmpty {
                    let children = locs.filter { $0.lowercased().contains(".xml") }
                    let picks = Array(children.prefix(Self.maxSitemapChildren))

                    if picks.isEmpty {
                        self.sitemapPending = false
                        self.pump()
                        return
                    }

                    let group = DispatchGroup()
                    let lock = NSLock()
                    var collected: [String] = []

                    for text in picks {
                        guard let childURL = URL(string: text) else { continue }
                        group.enter()
                        self.fetchSitemap(childURL) { childLocs, _ in
                            lock.lock()
                            collected.append(contentsOf: childLocs)
                            lock.unlock()
                            group.leave()
                        }
                    }

                    group.notify(queue: .main) {
                        guard self.isRunning else { return }
                        self.seed(with: collected)
                        self.sitemapPending = false
                        self.pump()
                    }
                } else {
                    self.seed(with: locs)
                    self.sitemapPending = false
                    self.pump()
                }
            }
        }
    }

    private func seed(with locs: [String]) {
        var added = 0
        for text in locs {
            guard added < Self.sitemapLimit else { break }
            guard let url = URL(string: text) else { continue }
            if Self.isOtherResource(url) { continue }
            if onlySameSite && !inScope(url) { continue }
            enqueue(url, depth: 1)
            added += 1
        }
        sitemapCount = added
        if added > 0 {
            statusText = "sitemap 读到 \(added) 个页面，继续并发扫描"
        }
    }

    private func fetchSitemap(_ url: URL, completion: @escaping ([String], Bool) -> Void) {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.setValue(BrowserController.mobileUserAgentString, forHTTPHeaderField: "User-Agent")

        let task = URLSession.shared.dataTask(with: request) { data, response, _ in
            guard let data = data, let text = String(data: data, encoding: .utf8) else {
                completion([], false)
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status < 400 else {
                completion([], false)
                return
            }

            let isIndex = text.contains("<sitemapindex")
            var locs: [String] = []
            let pieces = text.components(separatedBy: "<loc>")
            for piece in pieces.dropFirst() {
                guard let end = piece.range(of: "</loc>") else { continue }
                let value = String(piece[..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                if value.hasPrefix("http") {
                    locs.append(value)
                }
                if locs.count >= 3000 { break }
            }
            completion(locs, isIndex)
        }
        task.resume()
    }

    // MARK: - 结束

    private func finish(reason: String?) {
        guard isRunning else { return }
        isRunning = false
        sitemapPending = false
        queue.removeAll()
        workers.forEach { $0.stop() }
        workers.removeAll()
        idleWorkers.removeAll()
        activeCount = 0
        activeWorkers = 0
        clock?.invalidate()
        clock = nil

        let seconds = Int(Date().timeIntervalSince(startedAt ?? Date()))
        elapsedSeconds = seconds
        let note = reason ?? ""

        if pages.isEmpty {
            statusText = "扫描结束：共查看 \(visitedKeys.count) 个页面，没有发现视频或图片。\(note)"
        } else {
            statusText = "扫描结束：共查看 \(visitedKeys.count) 个页面，发现 \(foundCount) 个视频、\(foundImageCount) 张图片，用时 \(seconds) 秒。\(note)"
        }
    }

    // MARK: - 范围与工具

    private func inScope(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        if !onlySameSite { return true }
        if host == baseHost { return true }
        if host == "www." + baseHost { return true }
        if includeSubdomains && Self.siteKey(host) == baseSite { return true }
        return false
    }

    private static let twoPartSuffixes: Set<String> = [
        "com.cn", "net.cn", "org.cn", "gov.cn", "edu.cn",
        "co.uk", "org.uk", "com.hk", "com.tw", "com.sg",
        "co.jp", "ne.jp", "or.jp", "co.kr", "com.au", "co.nz"
    ]

    static func siteKey(_ host: String) -> String {
        let parts = host.split(separator: ".").map(String.init)
        if parts.count <= 2 { return host }
        let lastTwo = parts.suffix(2).joined(separator: ".")
        if twoPartSuffixes.contains(lastTwo), parts.count >= 3 {
            return parts.suffix(3).joined(separator: ".")
        }
        return lastTwo
    }

    static func key(_ url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.fragment = nil
        let text = components?.url?.absoluteString ?? url.absoluteString
        return text.lowercased()
    }

    static func attachToWindow(_ view: UIView) {
        view.alpha = 0.02
        view.isUserInteractionEnabled = false
        if let window = keyWindow() {
            window.addSubview(view)
        }
    }

    static func keyWindow() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes
        for scene in scenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            if let window = windowScene.keyWindow {
                return window
            }
            if let window = windowScene.windows.first(where: { $0.isKeyWindow }) {
                return window
            }
        }
        for scene in scenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            if let window = windowScene.windows.first {
                return window
            }
        }
        return nil
    }

    private static let otherExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "webp", "svg", "ico", "bmp", "heic",
        "css", "js", "json", "xml", "txt", "pdf", "zip", "rar", "7z", "gz", "tar",
        "apk", "ipa", "exe", "dmg", "msi", "pkg",
        "doc", "docx", "xls", "xlsx", "ppt", "pptx", "rtf",
        "mp3", "m4a", "wav", "ogg", "flac", "aac",
        "mp4", "m3u8", "m3u", "m4v", "mov", "webm", "flv", "mpd", "ts", "m4s", "vtt", "key"
    ]

    private static func isOtherResource(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if ext.isEmpty { return false }
        return otherExtensions.contains(ext)
    }

    private static func priority(_ url: URL) -> Int {
        var text = url.path.lowercased()
        if let query = url.query {
            text += "?" + query.lowercased()
        }
        let words = [
            "video", "watch", "play", "movie", "film", "episode", "detail", "vod",
            "media", "post", "article", "list", "channel", "show", "drama", "mv", "tv", "page"
        ]
        var score = 0
        for word in words where text.contains(word) {
            score += 1
        }
        if url.pathComponents.count <= 3 { score += 1 }
        return score
    }
}

// MARK: - Worker 的代理与消息

extension CrawlWorker: WKNavigationDelegate {

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === self.webView, pending else { return }
        if let title = webView.title, !title.isEmpty {
            pageTitle = title
        }
        if let url = webView.url {
            pageURL = url
        }
        scheduleHarvest(after: 0.55)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard webView === self.webView, pending else { return }
        let nsError = error as NSError
        if nsError.code == NSURLErrorCancelled { return }
        scheduleHarvest(after: 0.15)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard webView === self.webView, pending else { return }
        let nsError = error as NSError
        if nsError.code == NSURLErrorCancelled { return }
        scheduleHarvest(after: 0.1)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard webView === self.webView else {
            decisionHandler(.allow)
            return
        }
        guard let url = navigationAction.request.url, let scheme = url.scheme?.lowercased() else {
            decisionHandler(.cancel)
            return
        }
        guard scheme == "http" || scheme == "https" else {
            decisionHandler(.cancel)
            return
        }

        if let kind = MediaSniffer.kind(for: url, mimeType: nil) {
            decisionHandler(.cancel)
            append(url: url.absoluteString, kind: kind.rawValue, thumb: "")
            return
        }

        if navigationAction.targetFrame == nil {
            decisionHandler(.cancel)
            return
        }

        decisionHandler(.allow)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        guard webView === self.webView else {
            decisionHandler(.allow)
            return
        }
        if navigationResponse.isForMainFrame,
           let url = navigationResponse.response.url,
           let kind = MediaSniffer.kind(for: url, mimeType: navigationResponse.response.mimeType) {
            decisionHandler(.cancel)
            append(url: url.absoluteString, kind: kind.rawValue, thumb: "")
            finish(payload: nil)
            return
        }
        decisionHandler(.allow)
    }
}

extension CrawlWorker: WKScriptMessageHandler {

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard pending, let body = message.body as? [String: Any] else { return }
        guard FramePolicy.shouldAccept(
            frameInfo: message.frameInfo,
            body: body,
            mainURL: pageURL,
            allowCrossSite: allowCrossSiteFrames
        ) else { return }

        if message.name == ImageSniffer.handlerName {
            appendImage(body)
            return
        }

        guard message.name == MediaSniffer.handlerName, let raw = body["url"] as? String else { return }
        let isIframe = (body["isIframe"] as? Bool) ?? !message.frameInfo.isMainFrame
        append(
            url: raw,
            kind: (body["kind"] as? String) ?? "",
            thumb: (body["thumb"] as? String) ?? "",
            isIframe: isIframe
        )
    }
}
