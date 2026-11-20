//
//  VideoHunterApp.swift
//  VideoHunter
//

import SwiftUI
import AVFoundation

@main
struct VideoHunterApp: App {

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
