//
//  VideoHunterApp.swift
//  VideoHunter
//

import SwiftUI
import AVFoundation
import UIKit

/// 2.4：background URLSession 的系统回调入口。
/// App 被后台唤醒时，先把 completionHandler 交给 DownloadManager，
/// 等所有下载事件处理完再由 URLSession delegate 调用，避免被系统强杀。
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == DownloadManager.backgroundSessionIdentifier else {
            completionHandler()
            return
        }
        DownloadManager.shared.setBackgroundSessionCompletionHandler(completionHandler)
    }
}

@main
struct VideoHunterApp: App {

    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback, options: [])

        // 2.5：把持久化的图片并发和缓存预算应用到运行时。
        let settings = AppSettings.shared
        RemoteImageLoader.applyCacheLimits(
            thumbnailMB: settings.thumbnailCacheMB,
            originalMB: settings.originalCacheMB
        )
        VideoFrameStore.applyCacheLimit(settings.videoFrameCacheMB)
        Task {
            await RemoteImageLoader.updateConcurrency(settings.imageConcurrency)
        }
    }

    var body: some Scene {
        // 每个浏览器窗口拥有独立的 ContentView / BrowserController，
        // iPad 上可通过 openWindow(id: "browser") 新建第二个浏览窗口。
        WindowGroup(id: "browser") {
            ContentView()
        }

        // 独立的设置窗口。设置页本身也可以作为全屏页面打开；
        // 这个 scene 用于 iPad 多窗口和“在独立窗口打开设置”。
        WindowGroup("设置", id: "settings") {
            SettingsWindowView()
        }
    }
}
