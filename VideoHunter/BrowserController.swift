//
//  BrowserController.swift
//  VideoHunter
//
//  管理 WKWebView、地址栏状态、Cookie 同步，以及直接打开媒体链接时的处理。
//

import UIKit
import WebKit
import Combine

final class BrowserController: NSObject, ObservableObject {

    static let mobileUserAgentString = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
    static let desktopUserAgentString = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    /// 内置的示例 HLS 流，用来验证播放链路。
    static let demoURL = "https://devstreaming-cdn.apple.com/videos/streaming/examples/bipbop_4x3/bipbop_4x3_variant.m3u8"

    @Published var addressText = ""
    @Published var isLoading = false
    @Published var progress: Double = 0
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var pageTitle = ""
    @Published var hasLoadedPage = false
    @Published var desktopUserAgent = false
    @Published var directItem: MediaItem?
    @Published var lastError: String?

    let sniffer = MediaSniffer()

    private(set) var webView: WKWebView!

    private var observations: [NSKeyValueObservation] = []
    private var snifferSubscription: AnyCancellable?
    private var pluginObserver: NSObjectProtocol?

    var pageURLString: String? { webView.url?.absoluteString }
    var pageURL: URL? { webView.url }

    // MARK: - 初始化

    override init() {
        super.init()

        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = .audio
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true

        let userContentController = WKUserContentController()
        userContentController.add(sniffer, name: MediaSniffer.handlerName)
        configuration.userContentController = userContentController

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.keyboardDismissMode = .onDrag
        if #available(iOS 16.4, *) {
            webView.isInspectable = true
        }
        self.webView = webView

        applyUserScripts()

        pluginObserver = NotificationCenter.default.addObserver(
            forName: .vhPluginsChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            self.applyUserScripts()
            if self.hasLoadedPage {
                self.webView.reload()
            }
        }

        setupObservers()

        // 让 ContentView 能感知 sniffer.items 的变化。
        snifferSubscription = sniffer.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    deinit {
        if let observer = pluginObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        observations.forEach { $0.invalidate() }
        snifferSubscription?.cancel()
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: MediaSniffer.handlerName)
        webView?.stopLoading()
    }

    /// 重新装载内置嗅探脚本和用户插件脚本；插件改动后调用它会立即生效。
    private func applyUserScripts() {
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
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
    }

    private func setupObservers() {
        observations.append(webView.observe(\.estimatedProgress, options: [.new]) { [weak self] view, _ in
            let value = view.estimatedProgress
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.progress = Double(value)
            }
        })

        observations.append(webView.observe(\.isLoading, options: [.new]) { [weak self] view, _ in
            let loading = view.isLoading
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isLoading = loading
            }
        })
    }

    // MARK: - 导航控制

    func load(_ url: URL) {
        lastError = nil

        // 直接粘贴 m3u8 / mp4 等媒体直链时，不必先在网页里打开，直接进播放器。
        if let kind = MediaSniffer.kind(for: url, mimeType: nil) {
            let item = MediaItem(url: url, kind: kind, source: "address", pageTitle: url.lastPathComponent)
            directItem = item
            return
        }

        hasLoadedPage = true
        let request = URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 25)
        webView.load(request)
    }

    func load(_ raw: String) {
        guard let url = Self.normalizedURL(from: raw) else {
            lastError = "链接格式不正确"
            return
        }
        load(url)
    }

    func goBack() {
        guard webView.canGoBack else { return }
        webView.goBack()
        syncState()
    }

    func goForward() {
        guard webView.canGoForward else { return }
        webView.goForward()
        syncState()
    }

    func reload() {
        guard hasLoadedPage else { return }
        webView.reload()
    }

    func rescan() {
        guard hasLoadedPage else { return }
        webView.evaluateJavaScript("window.__vhRescan ? window.__vhRescan() : true") { _, _ in }
    }

    func goHome() {
        webView.stopLoading()
        webView.loadHTMLString("", baseURL: nil)
        sniffer.reset()
        hasLoadedPage = false
        addressText = ""
        pageTitle = ""
        directItem = nil
        canGoBack = false
        canGoForward = false
        isLoading = false
        progress = 0
    }

    func setDesktopUserAgent(_ enabled: Bool) {
        desktopUserAgent = enabled
        webView.customUserAgent = enabled ? Self.desktopUserAgentString : Self.mobileUserAgentString
    }

    func clearWebsiteData() {
        let dataTypes = WKWebsiteDataStore.allWebsiteDataTypes()
        WKWebsiteDataStore.default().removeData(ofTypes: dataTypes, modifiedSince: .distantPast) { }
    }

    // MARK: - 内部

    private func syncState() {
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        if let url = webView.url, !url.absoluteString.isEmpty, url.absoluteString != "about:blank" {
            addressText = url.absoluteString
        }
        if let title = webView.title, !title.isEmpty {
            pageTitle = title
        }
    }

    private func syncCookies() {
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
            let storage = HTTPCookieStorage.shared
            for cookie in cookies {
                storage.setCookie(cookie)
            }
        }
    }

    private func playDirect(_ url: URL, kind: MediaKind) {
        isLoading = false
        let item = MediaItem(url: url, kind: kind, source: "direct", pageTitle: webView.title ?? "")
        directItem = item
    }

    private func handleFailure(_ error: Error) {
        isLoading = false
        let nsError = error as NSError
        if nsError.code == NSURLErrorCancelled { return }
        lastError = "加载失败：\(nsError.localizedDescription)"
    }

    // MARK: - 地址规范化

    static func normalizedURL(from raw: String) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        // 带空格当成搜索词处理，方便直接搜片名。
        if text.contains(" ") {
            let query = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? text
            return URL(string: "https://www.bing.com/search?q=\(query)")
        }

        let lowercased = text.lowercased()
        if !lowercased.hasPrefix("http://") && !lowercased.hasPrefix("https://") {
            text = "https://" + text
        }

        if let url = URL(string: text), let host = url.host, !host.isEmpty {
            return url
        }

        if let encoded = text.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed),
           let url = URL(string: encoded), let host = url.host, !host.isEmpty {
            return url
        }

        return nil
    }
}

// MARK: - WKNavigationDelegate

extension BrowserController: WKNavigationDelegate {

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isLoading = true
        progress = 0
        syncState()
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        // 主文档开始渲染，说明页面已经切换，清空上一页的识别结果。
        sniffer.reset()
        syncState()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
        progress = 1
        syncState()
        syncCookies()
        rescan()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handleFailure(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        handleFailure(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        lastError = "网页进程被系统回收，正在重新加载"
        webView.reload()
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // 处理 target=_blank 一类的新窗口链接，直接在当前 WebView 里打开。
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
            webView.load(URLRequest(url: url))
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        // 直接粘贴 m3u8 / mp4 链接时，WebView 会尝试下载，这里拦下来直接进播放器。
        if navigationResponse.isForMainFrame,
           let url = navigationResponse.response.url,
           let kind = MediaSniffer.kind(for: url, mimeType: navigationResponse.response.mimeType) {
            decisionHandler(.cancel)
            playDirect(url, kind: kind)
            return
        }
        decisionHandler(.allow)
    }
}

// MARK: - WKUIDelegate

extension BrowserController: WKUIDelegate {

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = navigationAction.request.url {
            webView.load(URLRequest(url: url))
        }
        return nil
    }
}
