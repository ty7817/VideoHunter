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
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
