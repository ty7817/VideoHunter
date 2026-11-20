//
//  PlayerView.swift
//  VideoHunter
//
//  内置播放器。HLS / MP4 走 AVPlayer，并带上 Referer / UA，尽量减少 403。
//

import SwiftUI
import AVKit
import UIKit

struct PlayerViewController: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.showsPlaybackControls = true
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.videoGravity = .resizeAspect
        return controller
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {
        if uiViewController.player !== player {
            uiViewController.player = player
        }
    }
}

struct PlayerScreen: View {
    let item: MediaItem
    let referer: String?

    @Environment(\.dismiss) private var dismiss

    @State private var player: AVPlayer?
    @State private var errorText: String?
    @State private var statusObservation: NSKeyValueObservation?
    @State private var didCopy = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let player = player {
                PlayerViewController(player: player)
                    .ignoresSafeArea()
            } else {
                ProgressView()
                    .tint(.white)
            }

            VStack(spacing: 0) {
                topBar
                Spacer()
                if let errorText = errorText {
                    errorCard(errorText)
                }
                Spacer()
            }
        }
        .onAppear(perform: start)
        .onDisappear(perform: stop)
    }

    // MARK: - 顶部栏

    private var topBar: some View {
        HStack(spacing: 12) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .frame(width: 34, height: 34)
                    .background(.ultraThinMaterial, in: Circle())
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(item.fileName)
                    .font(.footnote.weight(.semibold))
                    .lineLimit(1)
                Text("\(item.kind.label) · \(item.host)")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.65))
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button {
                UIPasteboard.general.string = item.url.absoluteString
                didCopy = true
            } label: {
                Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 34, height: 34)
                    .background(.ultraThinMaterial, in: Circle())
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 20)
        .background(
            LinearGradient(
                colors: [Color.black.opacity(0.65), Color.clear],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    // MARK: - 错误提示

    private func errorCard(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title2)
                .foregroundStyle(.yellow)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.9))
                .multilineTextAlignment(.center)
            HStack(spacing: 10) {
                Button("重新加载", action: reload)
                    .buttonStyle(.borderedProminent)
                Button("Safari") {
                    UIApplication.shared.open(item.url)
                }
                .buttonStyle(.bordered)
                Button("复制") {
                    UIPasteboard.general.string = item.url.absoluteString
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(20)
        .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal, 32)
    }

    // MARK: - 播放生命周期

    private func start() {
        guard player == nil else { return }
        activateAudioSession()
        let newPlayer = Self.makePlayer(for: item, referer: referer)
        player = newPlayer
        observeFailure(of: newPlayer)
        newPlayer.play()
    }

    private func reload() {
        errorText = nil
        statusObservation?.invalidate()
        statusObservation = nil
        player?.pause()

        let newPlayer = Self.makePlayer(for: item, referer: referer)
        player = newPlayer
        observeFailure(of: newPlayer)
        newPlayer.play()
    }

    private func stop() {
        statusObservation?.invalidate()
        statusObservation = nil
        player?.pause()
        player = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    private func observeFailure(of player: AVPlayer) {
        statusObservation = player.currentItem?.observe(\.status, options: [.new]) { item, _ in
            guard item.status == .failed else { return }
            let message = item.error?.localizedDescription ?? "无法播放这个链接"
            DispatchQueue.main.async {
                errorText = message
            }
        }
    }

    private func activateAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback, options: [])
        try? session.setActive(true)
    }

    // MARK: - 组装播放器

    private static func makePlayer(for item: MediaItem, referer: String?) -> AVPlayer {
        var headers: [String: String] = [
            "User-Agent": BrowserController.mobileUserAgentString,
            "Accept": "*/*"
        ]

        if let referer = referer, let refererURL = URL(string: referer) {
            headers["Referer"] = referer
            if let scheme = refererURL.scheme, let host = refererURL.host {
                headers["Origin"] = "\(scheme)://\(host)"
            }
        }

        let options: [String: Any] = ["AVURLAssetHTTPHeaderFieldsKey": headers]
        let asset = AVURLAsset(url: item.url, options: options)
        let player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        player.allowsExternalPlayback = true
        return player
    }
}
