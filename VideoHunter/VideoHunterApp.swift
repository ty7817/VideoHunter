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
        WindowGroup {
            ContentView()
        }
    }
}
