//
//  FramePolicy.swift
//  VideoHunter
//
//  过滤广告 iframe 与跨站 iframe，避免把页面里的统计/广告资源当成视频或图片。
//  默认只接受主文档和同站 iframe；用户可以在菜单里显式打开“包含跨站 iframe”。
//

import Foundation
import WebKit

enum FramePolicy {

    private static let adHosts: [String] = [
        "doubleclick.net",
        "googlesyndication.com",
        "googleadservices.com",
        "adservice.google.com",
        "amazon-adsystem.com",
        "taboola.com",
        "outbrain.com",
        "criteo.com",
        "criteo.net",
        "scorecardresearch.com",
        "quantserve.com",
        "adnxs.com",
        "adsrvr.org",
        "rubiconproject.com",
        "pubmatic.com",
        "openx.net",
        "smartadserver.com",
        "moatads.com",
        "imasdk.googleapis.com",
        "doubleverify.com",
        "advertising.com",
        "yieldmo.com",
        "sharethrough.com",
        "teads.tv",
        "spotxchange.com",
        "springserve.com",
        "innovid.com",
        "undertone.com"
    ]

    private static let adPathWords: Set<String> = [
        "ad", "ads", "advert", "adverts", "advertisement", "advertising",
        "banner", "banners", "sponsor", "sponsored", "prebid", "vast",
        "tracking", "tracker", "analytics", "pixel", "beacon"
    ]

    static func shouldAccept(
        frameInfo: WKFrameInfo,
        body: [String: Any],
        mainURL: URL?,
        allowCrossSite: Bool
    ) -> Bool {
        if frameInfo.isMainFrame { return true }

        let frameString = (body["frame"] as? String)
            ?? frameInfo.request.url?.absoluteString
            ?? ""
        guard let frameURL = URL(string: frameString),
              let frameHost = frameURL.host?.lowercased() else {
            return false
        }

        if isAdFrame(host: frameHost, path: frameURL.path) {
            return false
        }
        if allowCrossSite { return true }
        guard let mainHost = mainURL?.host?.lowercased(), !mainHost.isEmpty else {
            return false
        }
        return isSameSite(mainHost, frameHost)
    }

    static func isAdFrame(host: String, path: String) -> Bool {
        let host = host.lowercased()
        for adHost in adHosts {
            if host == adHost || host.hasSuffix("." + adHost) {
                return true
            }
        }
        let words = path.lowercased().split(separator: "/").map(String.init)
        for word in words {
            if adPathWords.contains(word) {
                return true
            }
        }
        return false
    }

    static func isSameSite(_ mainHost: String, _ frameHost: String) -> Bool {
        if mainHost == frameHost { return true }
        if frameHost.hasSuffix("." + mainHost) { return true }
        if mainHost.hasSuffix("." + frameHost) { return true }

        let mainParts = mainHost.split(separator: ".")
        let frameParts = frameHost.split(separator: ".")
        guard mainParts.count >= 2, frameParts.count >= 2 else { return false }
        return mainParts.suffix(2).joined(separator: ".") == frameParts.suffix(2).joined(separator: ".")
    }
}
