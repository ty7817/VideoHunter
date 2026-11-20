//
//  SiteCrawler.swift
//  VideoHunter
//
//  整站扫描：从一个页面出发，逐页打开站内链接，收集每个页面里的视频地址。
//  用独立的隐藏 WKWebView 运行同样的注入脚本，因此 JS 渲染出来的视频也能抓到。
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

    var displayTitle: String {
        if !title.isEmpty { return title }
        let last = url.lastPathComponent
        if !last.isEmpty && last != "/" { return last.removingPercentEncoding ?? last }
        return url.host ?? url.absoluteString
    }
}

final class SiteCrawler: NSObject, ObservableObject {

    // MARK: - 可调整的设置

    @Published var maxPages: Int = 60
    @Published var maxDepth: Int = 3
    @Published var onlySameSite: Bool = true
    @Published var includeSubdomains: Bool = true

    // MARK: - 运行状态

    @Published private(set) var isRunning = false
    @Published private(set) var visitedCount = 0
    @Published private(set) var foundCount = 0
    @Published private(set) var currentURL = ""
    @Published private(set) var pages: [CrawledPage] = []
    @Published private(set) var statusText = ""
    @Published private(set) var elapsedSeconds = 0
    @Published private(set) var startHost = ""
    @Published private(set) var sitemapCount = 0

    private struct Candidate {
        let url: URL
        let depth: Int
    }

    private var webView: WKWebView?
    private var queue: [Candidate] = []
    private var queuedKeys: Set<String> = []
    private var visitedKeys: Set<String> = []
    private var mediaKeys: Set<String> = []
    private var pageBuffer: [String: MediaItem] = [:]
    private var pageOrder: [String] = []

    private var currentDepth = 0
    private var generation = 0
    private var pagePending = false
    private var startedAt: Date?
    private var settleWork: DispatchWorkItem?
    private var timeoutWork: DispatchWorkItem?
    private var clock: Timer?

    private var baseHost = ""
    private var baseSite = ""
    private var landingURL: URL?

    private static let queueLimit = 500
    private static let sitemapLimit = 150
    private static let maxSitemapChildren = 3

    // MARK: - 对外接口

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
        statusText = "正在读取 sitemap.xml…"

        enqueue(url, depth: 0)
        prepareWebView()
        startClock()

        if onlySameSite {
            loadSitemapSeed(baseURL: url)
        } else {
            pump()
        }
    }

    func cancel() {
        guard isRunning else { return }
        isRunning = false
        pagePending = false
        generation &+= 1
        settleWork?.cancel()
        settleWork = nil
        timeoutWork?.cancel()
        timeoutWork = nil
        clock?.invalidate()
        clock = nil
        webView?.stopLoading()
        teardown()
        statusText = pages.isEmpty
            ? "扫描已取消，共查看 \(visitedCount) 个页面，没有留下结果"
            : "扫描已取消，已保留 \(pages.count) 个页面、\(foundCount) 个视频"
    }

    // MARK: - 状态复位

    private func reset() {
        settleWork?.cancel()
        settleWork = nil
        timeoutWork?.cancel()
        timeoutWork = nil
        clock?.invalidate()
        clock = nil
        webView?.stopLoading()
        teardown()

        queue.removeAll()
        queuedKeys.removeAll()
        visitedKeys.removeAll()
        mediaKeys.removeAll()
        pageBuffer.removeAll()
        pageOrder.removeAll()

        pages = []
        visitedCount = 0
        foundCount = 0
        currentURL = ""
        statusText = ""
        elapsedSeconds = 0
        sitemapCount = 0
        currentDepth = 0
        pagePending = false
        generation &+= 1
    }

    private func prepareWebView() {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        // 扫描时不需要真的播放视频，禁止自动播放，省流量也省时间。
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
        controller.add(self, name: MediaSniffer.handlerName)
        configuration.userContentController = controller

        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 2, height: 2), configuration: configuration)
        view.navigationDelegate = self
        view.customUserAgent = BrowserController.mobileUserAgentString
        view.isUserInteractionEnabled = false
        // 挂到窗口上（几乎透明、2×2），这样页面不会被当成后台标签页，JS 定时器和懒加载才会跑。
        view.alpha = 0.02
        if let window = Self.keyWindow() {
            window.addSubview(view)
        }
        webView = view
    }

    private static func keyWindow() -> UIWindow? {
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

    private func teardown() {
        guard let view = webView else { return }
        view.stopLoading()
        view.navigationDelegate = nil
        view.configuration.userContentController.removeScriptMessageHandler(forName: MediaSniffer.handlerName)
        view.removeFromSuperview()
        webView = nil
    }

    private func startClock() {
        clock?.invalidate()
        clock = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self, let started = self.startedAt else { return }
            self.elapsedSeconds = Int(Date().timeIntervalSince(started))
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

    /// 浅层优先，其次按关键词打分，尽量先扫“视频列表 / 详情页”这类链接。
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

    private func pump() {
        guard isRunning else { return }
        while !queue.isEmpty {
            let candidate = queue.removeFirst()
            let key = Self.key(candidate.url)
            if visitedKeys.contains(key) { continue }
            if visitedKeys.count >= maxPages {
                finish(reason: "已达到页数上限")
                return
            }
            visitedKeys.insert(key)
            visitedCount = visitedKeys.count
            currentDepth = candidate.depth
            loadPage(candidate)
            return
        }
        finish(reason: nil)
    }

    // MARK: - 页面加载

    private func loadPage(_ candidate: Candidate) {
        guard let view = webView else { return }
        currentURL = candidate.url.absoluteString
        pageBuffer.removeAll()
        pageOrder.removeAll()
        pagePending = true
        generation &+= 1
        let gen = generation
        statusText = "正在扫描第 \(visitedKeys.count) / \(maxPages) 页"

        view.load(URLRequest(url: candidate.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20))

        timeoutWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, gen == self.generation, self.pagePending else { return }
            self.webView?.stopLoading()
            self.harvest(gen)
        }
        timeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 22, execute: work)
    }

    private func scheduleHarvest(after delay: TimeInterval) {
        guard pagePending else { return }
        settleWork?.cancel()
        let gen = generation
        let work = DispatchWorkItem { [weak self] in
            self?.harvest(gen)
        }
        settleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// 先做一次完整重扫（补上加载后期才出现的地址），再取链接。
    private func harvest(_ gen: Int) {
        guard gen == generation, pagePending, let view = webView else { return }

        // 先往下滚一遍，触发懒加载 / 无限滚动列表里的视频；页面很长的站点也能多抓到一些。
        view.evaluateJavaScript(Self.autoScrollScript) { [weak self] _, _ in
            guard let self = self, gen == self.generation, self.pagePending else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                guard let self = self, gen == self.generation, self.pagePending else { return }
                view.evaluateJavaScript("window.__vhRescan ? (window.__vhRescan(), true) : true") { [weak self] _, _ in
                    guard let self = self, gen == self.generation, self.pagePending else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                        guard let self = self, gen == self.generation, self.pagePending else { return }
                        self.collectLinks(gen)
                    }
                }
            }
        }
    }

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

    private func collectLinks(_ gen: Int) {
        guard gen == generation, let view = webView else { return }
        let script = "window.__vhCollectLinks ? window.__vhCollectLinks(80) : '{\"links\":[],\"media\":[]}'"
        view.evaluateJavaScript(script) { [weak self] result, _ in
            guard let self = self, gen == self.generation, self.pagePending else { return }
            self.finishPage(payload: result as? String)
        }
    }

    private func finishPage(payload: String?) {
        guard pagePending else { return }
        pagePending = false
        settleWork?.cancel()
        timeoutWork?.cancel()

        let pageURL = webView?.url ?? landingURL
        var title = ""
        if let view = webView, let value = view.title, !value.isEmpty {
            title = value
        }

        var links: [String] = []
        var payloadMedia: [(String, String)] = []

        if let payload = payload, let data = payload.data(using: .utf8) {
            do {
                let object = try JSONSerialization.jsonObject(with: data, options: [])
                if let dict = object as? [String: Any] {
                    if let rawLinks = dict["links"] as? [String] {
                        links = rawLinks
                    }
                    if let rawMedia = dict["media"] as? [[String: Any]] {
                        for entry in rawMedia {
                            if let raw = entry["url"] as? String {
                                payloadMedia.append((raw, (entry["kind"] as? String) ?? ""))
                            }
                        }
                    }
                }
            } catch {
                // 页面结构异常时忽略，继续下一页。
            }
        }

        for pair in payloadMedia {
            appendMedia(raw: pair.0, kindRaw: pair.1, title: title, pageURL: pageURL, via: "link")
        }

        var kept: [MediaItem] = []
        for key in pageOrder {
            guard let item = pageBuffer[key] else { continue }
            if mediaKeys.contains(item.key) { continue }
            mediaKeys.insert(item.key)
            kept.append(item)
        }

        if !kept.isEmpty, let pageURL = pageURL {
            pages.append(CrawledPage(url: pageURL, title: title, depth: currentDepth, items: kept))
            foundCount += kept.count
        }

        for raw in links {
            guard let url = URL(string: raw) else { continue }
            enqueue(url, depth: currentDepth + 1)
        }

        pump()
    }

    private func appendMedia(raw: String, kindRaw: String, title: String, pageURL: URL?, via: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let url = URL(string: trimmed), url.scheme != nil else { return }
        guard url.absoluteString != "about:blank" else { return }
        guard !MediaSniffer.isSegment(url) else { return }

        let key = url.absoluteString
        if pageBuffer[key] != nil { return }
        if mediaKeys.contains(key) { return }

        var kind = MediaKind(rawValue: kindRaw) ?? .other
        if kind == .other {
            kind = MediaSniffer.inferKind(url)
        }

        let item = MediaItem(
            url: url,
            kind: kind,
            source: via,
            pageTitle: title,
            frameURL: pageURL?.absoluteString
        )
        pageBuffer[key] = item
        pageOrder.append(key)
    }

    // MARK: - 结束

    private func finish(reason: String?) {
        guard isRunning else { return }
        isRunning = false
        pagePending = false
        settleWork?.cancel()
        settleWork = nil
        timeoutWork?.cancel()
        timeoutWork = nil
        generation &+= 1
        clock?.invalidate()
        clock = nil
        webView?.stopLoading()
        teardown()

        let seconds = Int(Date().timeIntervalSince(startedAt ?? Date()))
        elapsedSeconds = seconds
        let note = reason ?? ""

        if pages.isEmpty {
            statusText = "扫描结束：共查看 \(visitedKeys.count) 个页面，没有发现视频。\(note)"
        } else {
            statusText = "扫描结束：共查看 \(visitedKeys.count) 个页面，发现 \(foundCount) 个视频，用时 \(seconds) 秒。\(note)"
        }
    }

    // MARK: - sitemap 预加载

    private func loadSitemapSeed(baseURL: URL) {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            pump()
            return
        }
        components.path = "/sitemap.xml"
        components.query = nil
        components.fragment = nil

        guard let sitemapURL = components.url else {
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
                        self.pump()
                    }
                } else {
                    self.seed(with: locs)
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
            statusText = "sitemap 里读到 \(added) 个页面，开始逐页扫描"
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

// MARK: - 收到的媒体地址

extension SiteCrawler: WKScriptMessageHandler {

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard isRunning, pagePending else { return }
        guard message.name == MediaSniffer.handlerName else { return }
        guard let body = message.body as? [String: Any] else { return }
        guard let raw = body["url"] as? String else { return }

        var title = (body["title"] as? String) ?? ""
        if title.isEmpty, let value = webView?.title {
            title = value
        }
        appendMedia(
            raw: raw,
            kindRaw: (body["kind"] as? String) ?? "",
            title: title,
            pageURL: webView?.url,
            via: (body["via"] as? String) ?? "dom"
        )
    }
}

// MARK: - 页面加载回调

extension SiteCrawler: WKNavigationDelegate {

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === self.webView, pagePending else { return }

        if let finalURL = webView.url, finalURL.absoluteString != "about:blank" {
            let key = Self.key(finalURL)
            if !visitedKeys.contains(key) {
                visitedKeys.insert(key)
                visitedCount = visitedKeys.count
            }
        }
        scheduleHarvest(after: 0.8)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard webView === self.webView, pagePending else { return }
        let nsError = error as NSError
        if nsError.code == NSURLErrorCancelled { return }
        scheduleHarvest(after: 0.15)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard webView === self.webView, pagePending else { return }
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

        // 目标是媒体直链时，记录下来，不真的去加载。
        if let kind = MediaSniffer.kind(for: url, mimeType: nil) {
            decisionHandler(.cancel)
            appendMedia(raw: url.absoluteString, kindRaw: kind.rawValue, title: webView.title ?? "", pageURL: url, via: "direct")
            return
        }

        // target=_blank 一类的新窗口，转成爬取任务，不弹新窗口。
        if navigationAction.targetFrame == nil {
            decisionHandler(.cancel)
            enqueue(url, depth: currentDepth + 1)
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
            appendMedia(raw: url.absoluteString, kindRaw: kind.rawValue, title: webView.title ?? "", pageURL: url, via: "direct")
            pagePending = false
            pump()
            return
        }
        decisionHandler(.allow)
    }
}
