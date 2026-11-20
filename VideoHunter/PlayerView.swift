//
//  PlayerView.swift
//  VideoHunter
//
//  自绘播放界面：AVPlayerLayer + 自定义控制条，支持倍速、画面填充、
//  手势快进、自动隐藏控制条、画中画、AirPlay 和播放队列。
//

import SwiftUI
import Combine
import AVKit
import AVFoundation
import MediaPlayer
import UIKit

// MARK: - 画面层

final class PlayerLayerContainer: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }

    var playerLayer: AVPlayerLayer {
        layer as! AVPlayerLayer
    }
}

struct PlayerSurface: UIViewRepresentable {
    let player: AVPlayer
    let gravity: AVLayerVideoGravity
    let onLayerReady: (AVPlayerLayer) -> Void

    func makeUIView(context: Context) -> PlayerLayerContainer {
        let view = PlayerLayerContainer()
        view.backgroundColor = .black
        view.playerLayer.player = player
        view.playerLayer.videoGravity = gravity
        onLayerReady(view.playerLayer)
        return view
    }

    func updateUIView(_ view: PlayerLayerContainer, context: Context) {
        if view.playerLayer.player !== player {
            view.playerLayer.player = player
        }
        view.playerLayer.videoGravity = gravity
    }
}

struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = .white
        view.activeTintColor = UIColor.systemBlue
        view.prioritizesVideoDevices = true
        return view
    }

    func updateUIView(_ view: AVRoutePickerView, context: Context) {}
}

// MARK: - 播放页

struct PlayerScreen: View {
    let item: MediaItem
    let referer: String?
    let playlist: [MediaItem]

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @State private var index: Int
    @State private var player: AVPlayer?
    @State private var isPlaying = false
    @State private var isBuffering = false
    @State private var duration: Double = 0
    @State private var position: Double = 0
    @State private var isScrubbing = false
    @State private var rate: Float = 1.0
    @State private var fillScreen = false
    @State private var showControls = true
    @State private var errorText: String?
    @State private var didCopy = false

    @State private var timeObserver: Any?
    @State private var observations: [NSKeyValueObservation] = []
    @State private var pipController: AVPictureInPictureController?
    @State private var hideWork: DispatchWorkItem?
    @State private var remoteTargets: [(MPRemoteCommand, Any)] = []

    init(item: MediaItem, referer: String?, playlist: [MediaItem] = []) {
        self.item = item
        self.referer = referer
        let queue = playlist.isEmpty ? [item] : playlist
        self.playlist = queue
        let start = queue.firstIndex(where: { $0.id == item.id }) ?? 0
        _index = State(initialValue: start)
    }

    private var currentItem: MediaItem {
        guard !playlist.isEmpty else { return item }
        let safeIndex = min(max(index, 0), playlist.count - 1)
        return playlist[safeIndex]
    }

    private var canGoPrevious: Bool { index > 0 }
    private var canGoNext: Bool { index + 1 < playlist.count }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let player = player {
                PlayerSurface(
                    player: player,
                    gravity: fillScreen ? .resizeAspectFill : .resizeAspect,
                    onLayerReady: setupPictureInPicture
                )
                .ignoresSafeArea()
            } else {
                ProgressView()
                    .tint(.white)
            }

            // 手势层：双击播放/暂停，横向拖动快进快退，单击呼出/收起控制条。
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    togglePlayback()
                }
                .onTapGesture {
                    toggleControls()
                }
                .gesture(
                    DragGesture(minimumDistance: 24)
                        .onEnded { value in
                            let horizontal = abs(value.translation.width)
                            let vertical = abs(value.translation.height)
                            guard horizontal > vertical else { return }
                            let delta = Double(value.translation.width) / 6.0
                            seek(to: position + delta)
                            revealControls()
                        }
                )

            if let errorText = errorText {
                errorCard(errorText)
            }

            if isBuffering && errorText == nil {
                ProgressView()
                    .tint(.white)
                    .scaleEffect(1.3)
            }

            if showControls || errorText != nil {
                controlsLayer
                    .transition(.opacity)
            }
        }
        .statusBarHidden(true)
        .onAppear(perform: start)
        .onDisappear(perform: stop)
        .onChange(of: index) { _ in
            switchToCurrent()
        }
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .background:
                if isPlaying, let player {
                    player.play()
                    player.rate = rate
                }
                updateNowPlayingInfo()
            case .active:
                updateNowPlayingInfo()
            default:
                break
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { note in
            guard let finished = note.object as? AVPlayerItem, finished === player?.currentItem else { return }
            handlePlaybackEnd()
        }
    }

    // MARK: - 控制层

    private var controlsLayer: some View {
        VStack(spacing: 0) {
            topBar
            Spacer()
            transportRow
            Spacer()
            bottomBar
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .foregroundStyle(.white)
        .background(
            LinearGradient(
                colors: [
                    Color.black.opacity(0.6),
                    Color.black.opacity(0.05),
                    Color.black.opacity(0.05),
                    Color.black.opacity(0.8)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        )
    }

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
                Text(currentItem.fileName)
                    .font(.footnote.weight(.semibold))
                    .lineLimit(1)
                Text("\(currentItem.category.label) · \(currentItem.kind.label) · \(currentItem.host)")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button {
                UIPasteboard.general.string = currentItem.url.absoluteString
                didCopy = true
                revealControls()
            } label: {
                Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 34, height: 34)
                    .background(.ultraThinMaterial, in: Circle())
            }

            Menu {
                Button {
                    UIApplication.shared.open(currentItem.url)
                } label: {
                    Label("在 Safari 中打开", systemImage: "safari")
                }
                Button {
                    reload()
                } label: {
                    Label("重新加载", systemImage: "arrow.clockwise")
                }
                if canGoNext {
                    Button {
                        index += 1
                    } label: {
                        Label("播放下一个", systemImage: "forward.end")
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 34, height: 34)
                    .background(.ultraThinMaterial, in: Circle())
            }
        }
        .padding(.top, 8)
    }

    private var transportRow: some View {
        HStack(spacing: 44) {
            Button {
                if canGoPrevious { index -= 1 }
            } label: {
                Image(systemName: "backward.end.fill")
                    .font(.system(size: 22, weight: .semibold))
            }
            .opacity(canGoPrevious ? 1 : 0.25)
            .disabled(!canGoPrevious)

            Button {
                togglePlayback()
            } label: {
                Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 62, weight: .regular))
                    .shadow(color: .black.opacity(0.4), radius: 8)
            }

            Button {
                if canGoNext { index += 1 }
            } label: {
                Image(systemName: "forward.end.fill")
                    .font(.system(size: 22, weight: .semibold))
            }
            .opacity(canGoNext ? 1 : 0.25)
            .disabled(!canGoNext)
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Text(Self.timeText(position))
                    .font(.caption2.monospacedDigit())
                    .frame(width: 44, alignment: .leading)

                Slider(
                    value: Binding(
                        get: { min(max(position, 0), max(duration, 1)) },
                        set: { position = $0 }
                    ),
                    in: 0...max(duration, 1),
                    onEditingChanged: { editing in
                        isScrubbing = editing
                        if !editing {
                            seek(to: position)
                        }
                        revealControls()
                    }
                )
                .tint(.white)

                Text(Self.timeText(duration))
                    .font(.caption2.monospacedDigit())
                    .frame(width: 44, alignment: .trailing)
            }

            HStack(spacing: 22) {
                Menu {
                    ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { value in
                        Button {
                            setRate(Float(value))
                        } label: {
                            HStack {
                                Text(Self.speedText(Float(value)))
                                if rate == Float(value) {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    Text(Self.speedText(rate))
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.ultraThinMaterial, in: Capsule())
                }

                Button {
                    fillScreen.toggle()
                    revealControls()
                } label: {
                    Image(systemName: fillScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                        .font(.footnote.weight(.semibold))
                }

                Button {
                    togglePictureInPicture()
                    revealControls()
                } label: {
                    Image(systemName: "pip")
                        .font(.footnote.weight(.semibold))
                }

                AirPlayButton()
                    .frame(width: 26, height: 26)

                Spacer()

                if playlist.count > 1 {
                    Text("\(index + 1) / \(playlist.count)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.75))
                }
            }
        }
        .padding(.bottom, 12)
    }

    // MARK: - 错误卡片

    private func errorCard(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title2)
                .foregroundStyle(.yellow)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.9))
                .multilineTextAlignment(.center)
                .lineLimit(4)

            HStack(spacing: 10) {
                Button("重新加载") { reload() }
                    .buttonStyle(.borderedProminent)
                if canGoNext {
                    Button("播放下一个") { index += 1 }
                        .buttonStyle(.bordered)
                }
                Button("Safari") { UIApplication.shared.open(currentItem.url) }
                    .buttonStyle(.bordered)
            }
            .tint(.white)
        }
        .padding(20)
        .background(Color.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal, 32)
    }

    // MARK: - 生命周期

    private func start() {
        guard player == nil else { return }
        UIApplication.shared.isIdleTimerDisabled = true
        activateAudioSession()
        startRemoteControls()
        buildPlayer(for: currentItem)
        scheduleControlHide()
    }

    private func stop() {
        teardownPlayer()
        stopRemoteControls()
        UIApplication.shared.isIdleTimerDisabled = false
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    private func switchToCurrent() {
        teardownPlayer()
        errorText = nil
        buildPlayer(for: currentItem)
        showControls = true
        scheduleControlHide()
    }

    private func buildPlayer(for media: MediaItem) {
        activateAudioSession()
        didCopy = false
        duration = 0
        position = 0
        errorText = nil

        let newPlayer = Self.makePlayer(for: media, referer: media.frameURL ?? referer)
        player = newPlayer
        observe(newPlayer)
        attachTimeObserver(newPlayer)
        newPlayer.play()
        newPlayer.rate = rate
        isPlaying = true
        updateNowPlayingInfo()
    }

    private func teardownPlayer() {
        hideWork?.cancel()
        hideWork = nil

        if let observer = timeObserver, let player = player {
            player.removeTimeObserver(observer)
        }
        timeObserver = nil

        observations.forEach { $0.invalidate() }
        observations = []

        player?.pause()
        player = nil
        isPlaying = false
        isBuffering = false
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        if let pip = pipController, pip.isPictureInPictureActive {
            pip.stopPictureInPicture()
        }
        pipController = nil
    }

    private func reload() {
        teardownPlayer()
        buildPlayer(for: currentItem)
        revealControls()
    }

    // MARK: - 观察

    private func observe(_ player: AVPlayer) {
        observations.forEach { $0.invalidate() }
        observations = []

        let status = player.currentItem?.observe(\.status, options: [.new]) { item, _ in
            DispatchQueue.main.async {
                switch item.status {
                case .failed:
                    self.errorText = item.error?.localizedDescription ?? "无法播放这个链接"
                    self.isPlaying = false
                case .readyToPlay:
                    let seconds = item.duration.seconds
                    if seconds.isFinite && seconds > 0 {
                        self.duration = seconds
                    }
                    self.updateNowPlayingInfo()
                default:
                    break
                }
            }
        }

        let control = player.observe(\.timeControlStatus, options: [.new]) { player, _ in
            DispatchQueue.main.async {
                self.isBuffering = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
            }
        }

        if let status = status { observations.append(status) }
        observations.append(control)
    }

    private func attachTimeObserver(_ player: AVPlayer) {
        if let observer = timeObserver {
            player.removeTimeObserver(observer)
            timeObserver = nil
        }

        let observer = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { time in
            if !self.isScrubbing {
                let seconds = time.seconds
                if seconds.isFinite && seconds >= 0 {
                    self.position = seconds
                }
            }
            if let item = player.currentItem {
                let seconds = item.duration.seconds
                if seconds.isFinite && seconds > 0 {
                    self.duration = seconds
                }
            }
            self.updateNowPlayingInfo()
        }
        timeObserver = observer
    }

    // MARK: - 播放控制

    private func togglePlayback() {
        guard let player = player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            if duration > 0, position >= duration - 0.3 {
                seek(to: 0)
            }
            player.play()
            player.rate = rate
            isPlaying = true
        }
        updateNowPlayingInfo()
        revealControls()
    }

    private func seek(to seconds: Double) {
        guard let player = player else { return }
        let upper = duration > 0 ? duration : seconds
        let target = min(max(seconds, 0), max(upper, 0))
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        position = target
        updateNowPlayingInfo()
    }

    private func setRate(_ value: Float) {
        rate = value
        guard let player = player else { return }
        if isPlaying {
            player.rate = value
        }
        updateNowPlayingInfo()
        revealControls()
    }

    private func handlePlaybackEnd() {
        if canGoNext {
            index += 1
        } else {
            isPlaying = false
            position = duration
            updateNowPlayingInfo()
            revealControls()
        }
    }

    // MARK: - 控制条显隐

    private func revealControls() {
        withAnimation(.easeInOut(duration: 0.2)) {
            showControls = true
        }
        scheduleControlHide()
    }

    private func toggleControls() {
        withAnimation(.easeInOut(duration: 0.2)) {
            showControls.toggle()
        }
        if showControls {
            scheduleControlHide()
        }
    }

    private func scheduleControlHide() {
        hideWork?.cancel()
        guard isPlaying, errorText == nil else { return }
        let work = DispatchWorkItem {
            withAnimation(.easeOut(duration: 0.25)) {
                showControls = false
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5, execute: work)
    }

    // MARK: - 画中画 / 音频

    private func setupPictureInPicture(_ layer: AVPlayerLayer) {
        DispatchQueue.main.async {
            if pipController == nil, AVPictureInPictureController.isPictureInPictureSupported() {
                pipController = AVPictureInPictureController(playerLayer: layer)
            }
        }
    }

    private func togglePictureInPicture() {
        guard let pip = pipController else { return }
        if pip.isPictureInPictureActive {
            pip.stopPictureInPicture()
        } else {
            pip.startPictureInPicture()
        }
    }

    // MARK: - 后台播放与锁屏控制

    private func updateNowPlayingInfo() {
        guard let player = player, player.currentItem != nil else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        let media = currentItem
        info[MPMediaItemPropertyTitle] = media.fileName
        info[MPMediaItemPropertyArtist] = media.pageTitle.isEmpty ? "视频猎手" : media.pageTitle
        info[MPMediaItemPropertyAlbumTitle] = media.category.label
        info[MPMediaItemPropertyPlaybackDuration] = duration
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = position
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? Double(rate) : 0
        info[MPNowPlayingInfoPropertyMediaType] = NSNumber(value: MPNowPlayingInfoMediaType.video.rawValue)
        info[MPNowPlayingInfoPropertyExternalContentIdentifier] = media.url.absoluteString
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func startRemoteControls() {
        guard remoteTargets.isEmpty else { return }
        UIApplication.shared.beginReceivingRemoteControlEvents()
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true
        center.togglePlayPauseCommand.isEnabled = true
        center.nextTrackCommand.isEnabled = true
        center.previousTrackCommand.isEnabled = true
        center.changePlaybackPositionCommand.isEnabled = true

        let play = center.playCommand.addTarget { _ in
            DispatchQueue.main.async {
                guard let player = self.player else { return }
                if self.duration > 0, self.position >= self.duration - 0.3 {
                    self.seek(to: 0)
                }
                player.play()
                player.rate = self.rate
                self.isPlaying = true
                self.updateNowPlayingInfo()
            }
            return .success
        }

        let pause = center.pauseCommand.addTarget { _ in
            DispatchQueue.main.async {
                self.player?.pause()
                self.isPlaying = false
                self.updateNowPlayingInfo()
            }
            return .success
        }

        let toggle = center.togglePlayPauseCommand.addTarget { _ in
            DispatchQueue.main.async {
                self.togglePlayback()
            }
            return .success
        }

        let next = center.nextTrackCommand.addTarget { _ in
            DispatchQueue.main.async {
                if self.canGoNext { self.index += 1 }
            }
            return .success
        }

        let previous = center.previousTrackCommand.addTarget { _ in
            DispatchQueue.main.async {
                if self.canGoPrevious { self.index -= 1 }
            }
            return .success
        }

        let positionChange = center.changePlaybackPositionCommand.addTarget { event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            DispatchQueue.main.async {
                self.seek(to: event.positionTime)
            }
            return .success
        }

        remoteTargets = [
            (center.playCommand, play),
            (center.pauseCommand, pause),
            (center.togglePlayPauseCommand, toggle),
            (center.nextTrackCommand, next),
            (center.previousTrackCommand, previous),
            (center.changePlaybackPositionCommand, positionChange)
        ]
    }

    private func stopRemoteControls() {
        for (command, token) in remoteTargets {
            command.removeTarget(token)
        }
        remoteTargets.removeAll()
        UIApplication.shared.endReceivingRemoteControlEvents()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    private func activateAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback, options: [])
        try? session.setActive(true)
    }

    // MARK: - 工具

    private static func timeText(_ seconds: Double) -> String {
        guard seconds.isFinite && seconds > 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let remain = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remain)
        }
        return String(format: "%d:%02d", minutes, remain)
    }

    private static func speedText(_ rate: Float) -> String {
        if abs(rate - 1.0) < 0.001 { return "1x" }
        if abs(rate - 0.75) < 0.001 { return "0.75x" }
        if abs(rate - 1.25) < 0.001 { return "1.25x" }
        if abs(rate - 1.5) < 0.001 { return "1.5x" }
        if abs(rate - 2.0) < 0.001 { return "2x" }
        if abs(rate - 0.5) < 0.001 { return "0.5x" }
        return String(format: "%.2gx", Double(rate))
    }

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
        if let cookies = HTTPCookieStorage.shared.cookies(for: item.url), !cookies.isEmpty {
            let fields = HTTPCookie.requestHeaderFields(with: cookies)
            if let cookie = fields["Cookie"] { headers["Cookie"] = cookie }
        }

        let options: [String: Any] = ["AVURLAssetHTTPHeaderFieldsKey": headers]
        let asset = AVURLAsset(url: item.url, options: options)
        let player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        player.allowsExternalPlayback = true
        player.preventsDisplaySleepDuringVideoPlayback = true
        player.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
        return player
    }
}
