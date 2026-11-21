//
//  SettingsView.swift
//  VideoHunter
//
//  2.5 设置中心：八个分区全部接到真实偏好；播放信息从 AVAsset 轨道读取，
//  读取不到的字段明确标“未知”，不伪造码率/帧率。
//  2.5-settings-center
//  2.5-settings-center-build3
//

import SwiftUI
import AVFoundation
import CoreMedia
import UIKit

struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var plugins = PluginStore.shared
    @ObservedObject private var playback = PlaybackSession.shared
    @Environment(\.dismiss) private var dismiss

    @State private var showPluginManager = false
    @State private var showResetConfirm = false

    var body: some View {
        NavigationStack {
            List {
                headerSection
                pluginSection
                backgroundSection
                videoSection
                playerSection
                appearanceSection
                imageSection
                aiSection
                playbackSection
                resetSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("设置中心")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
            .sheet(isPresented: $showPluginManager) {
                PluginListView()
            }
            .confirmationDialog("恢复默认设置？", isPresented: $showResetConfirm, titleVisibility: .visible) {
                Button("恢复默认", role: .destructive) {
                    settings.resetToDefaults()
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("只重置偏好。插件脚本、离线媒体库和已下载文件不会被删除。")
            }
        }
    }

    // MARK: - 顶部

    private var headerSection: some View {
        Section {
            VStack(spacing: 12) {
                HStack(spacing: 14) {
                    Image(systemName: "play.rectangle.on.rectangle.fill")
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [settings.accent.color, settings.accent.color.opacity(0.55)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 58, height: 58)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(settings.accent.color.opacity(0.12))
                        )

                    VStack(alignment: .leading, spacing: 4) {
                        Text("视频猎手")
                            .font(.title2.weight(.bold))
                        Text(versionText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("网页视频嗅探 · 图片采集 · 本地播放")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 0)
                }

                HStack(spacing: 8) {
                    summaryChip(icon: "film.stack", text: "视频 \(settings.maxVideoItems)")
                    summaryChip(icon: "photo.stack", text: "图片 \(settings.maxImageItems)")
                    summaryChip(icon: "puzzlepiece.extension", text: "插件 \(plugins.enabledPlugins.count)")
                }
            }
            .padding(.vertical, 8)
        }
        .listRowBackground(Color.clear)
    }

    private func summaryChip(icon: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption2.weight(.semibold))
            Text(text)
                .font(.caption2.weight(.semibold))
        }
        .foregroundStyle(settings.accent.color)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(settings.accent.color.opacity(0.10), in: Capsule())
    }

    private var versionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "2.5"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "9"
        return "版本 \(version) · Build \(build)"
    }

    // MARK: - 插件

    private var pluginSection: some View {
        Section {
            Button {
                showPluginManager = true
            } label: {
                HStack(spacing: 12) {
                    settingIcon("puzzlepiece.extension", color: .purple)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("插件管理")
                            .foregroundStyle(.primary)
                        Text("\(plugins.plugins.count) 个脚本 · \(plugins.enabledPlugins.count) 个启用")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }

            Toggle(isOn: $settings.pluginsEnabled) {
                Label("启用用户脚本注入", systemImage: "puzzlepiece")
            }

            LabeledContent("脚本运行位置", value: "文档开始时 / 匹配域名")
        } header: {
            Text("插件")
        } footer: {
            Text("插件是自定义 JavaScript 脚本，可按域名在网页加载前注入。关闭总开关后，所有插件脚本停止运行；内置嗅探脚本不受影响。")
        }
    }

    // MARK: - 后台

    private var backgroundSection: some View {
        Section {
            Toggle(isOn: $settings.backgroundPlayback) {
                Label("后台播放", systemImage: "play.circle")
            }
            Toggle(isOn: $settings.autoPictureInPicture) {
                Label("切后台自动画中画", systemImage: "pip")
            }
            Toggle(isOn: $settings.resumeAfterInterruption) {
                Label("电话/Siri 中断后恢复", systemImage: "phone.arrow.up.right")
            }
            Toggle(isOn: $settings.resumeAfterHeadphoneUnplug) {
                Label("拔出耳机后恢复外放", systemImage: "headphones")
            }
            Toggle(isOn: $settings.keepScreenAwake) {
                Label("播放时保持屏幕常亮", systemImage: "sun.max")
            }
            Toggle(isOn: $settings.allowCellularDownloads) {
                Label("离线下载允许蜂窝网络", systemImage: "antenna.radiowaves.left.and.right")
            }
            LabeledContent("后台下载", value: "background URLSession · 系统调度")
        } header: {
            Text("后台设置")
        } footer: {
            Text("iOS 不允许 WKWebView 无限期在后台运行；这里的后台能力指音频播放、系统画中画和由系统接管的后台下载。强制退出 App 后，未完成的下载会停止。")
        }
    }

    // MARK: - 视频

    private var videoSection: some View {
        Section {
            Toggle(isOn: $settings.autoScan) {
                Label("自动扫描新出现的视频", systemImage: "viewfinder")
            }

            Picker(selection: $settings.scanInterval) {
                ForEach(VHScanInterval.allCases) { interval in
                    Text(interval.label).tag(interval)
                }
            } label: {
                Label("扫描间隔", systemImage: "timer")
            }
            .disabled(!settings.autoScan)

            Stepper(value: $settings.maxVideoItems, in: 100...500, step: 50) {
                LabeledContent("视频列表上限", value: "\(settings.maxVideoItems) 条")
            }

            Toggle(isOn: $settings.preferHLS) {
                Label("优先展示 HLS", systemImage: "dot.radiowaves.left.and.right")
            }
            Toggle(isOn: $settings.filterAdFrames) {
                Label("过滤广告 iframe", systemImage: "shield.lefthalf.filled")
            }
            Toggle(isOn: $settings.loadVideoThumbnails) {
                Label("加载视频预览图", systemImage: "photo")
            }
            Toggle(isOn: $settings.includeCrossSiteFrames) {
                Label("包含跨站 iframe", systemImage: "rectangle.on.rectangle")
            }
        } header: {
            Text("视频设置")
        } footer: {
            Text("关闭自动扫描后，仍会扫描一次当前页面。扫描间隔和跨站 iframe 设置在下次加载页面时生效；跨站开关会立即重建嗅探脚本。优先 HLS 只影响列表排序，不改变可播放性。")
        }
    }

    // MARK: - 播放器

    private var playerSection: some View {
        Section {
            Picker(selection: $settings.playerRate) {
                ForEach(VHPlaybackRate.allCases) { rate in
                    Text(rate.label).tag(rate)
                }
            } label: {
                Label("默认播放倍速", systemImage: "speedometer")
            }

            Picker(selection: $settings.fillMode) {
                ForEach(VHFillMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            } label: {
                Label("默认画面模式", systemImage: "rectangle.arrowtriangle.2.outward")
            }

            Toggle(isOn: $settings.autoHideControls) {
                Label("自动隐藏控制条", systemImage: "eye.slash")
            }

            if settings.autoHideControls {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label("隐藏延迟", systemImage: "clock")
                        Spacer()
                        Text(String(format: "%.1f 秒", settings.autoHideDelay))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $settings.autoHideDelay, in: 2...8, step: 0.5)
                }
            }

            Picker(selection: $settings.seekStep) {
                ForEach(VHSeekStep.allCases) { step in
                    Text(step.label).tag(step)
                }
            } label: {
                Label("横滑快进步长", systemImage: "hand.draw")
            }

            Toggle(isOn: $settings.autoPlayNext) {
                Label("播放结束自动下一个", systemImage: "forward.end")
            }
            Toggle(isOn: $settings.loopPlayback) {
                Label("单个视频循环播放", systemImage: "repeat")
            }
        } header: {
            Text("播放器设置")
        } footer: {
            Text("默认倍速和画面模式在新打开视频时生效；自动隐藏、快进步长和连播会立即影响当前播放器。长按画面仍可呼出控制条。")
        }
    }

    // MARK: - 外观

    private var appearanceSection: some View {
        Section {
            Picker(selection: $settings.theme) {
                ForEach(VHTheme.allCases) { theme in
                    Text(theme.label).tag(theme)
                }
            } label: {
                Label("外观主题", systemImage: "circle.lefthalf.filled")
            }
            .pickerStyle(.segmented)

            Picker(selection: $settings.accent) {
                ForEach(VHAccent.allCases) { accent in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(accent.color)
                            .frame(width: 12, height: 12)
                        Text(accent.label)
                    }
                    .tag(accent)
                }
            } label: {
                Label("强调色", systemImage: "paintpalette")
            }

            Picker(selection: $settings.listDensity) {
                ForEach(VHListDensity.allCases) { density in
                    Text(density.label).tag(density)
                }
            } label: {
                Label("列表密度", systemImage: "list.bullet")
            }
            .pickerStyle(.segmented)

            Picker(selection: $settings.thumbnailSize) {
                ForEach(VHThumbnailSize.allCases) { size in
                    Text(size.label).tag(size)
                }
            } label: {
                Label("视频缩略图尺寸", systemImage: "photo.on.rectangle")
            }
            .pickerStyle(.segmented)

            Toggle(isOn: $settings.showCategoryBadges) {
                Label("显示分类徽标", systemImage: "tag")
            }
            Toggle(isOn: $settings.showHost) {
                Label("显示来源域名", systemImage: "globe")
            }
            Toggle(isOn: $settings.showIframeBadges) {
                Label("显示 iframe 标记", systemImage: "rectangle.on.rectangle")
            }
        } header: {
            Text("外观设置")
        } footer: {
            Text("主题和强调色作用于整个 App；列表密度、缩略图尺寸和徽标只改变识别结果与媒体库的展示，不影响识别结果本身。")
        }
    }

    // MARK: - 图片

    private var imageSection: some View {
        Section {
            Toggle(isOn: $settings.scanImages) {
                Label("扫描当前网页图片", systemImage: "photo.stack")
            }
            Toggle(isOn: $settings.scanSiteImages) {
                Label("整站扫描时采集图片", systemImage: "square.stack.3d.down.right")
            }
            .disabled(!settings.scanImages)

            Stepper(value: $settings.maxImageItems, in: 100...600, step: 100) {
                LabeledContent("图片列表上限", value: "\(settings.maxImageItems) 张")
            }

            Picker(selection: $settings.imageQuality) {
                ForEach(VHImageQuality.allCases) { quality in
                    Text("\(quality.label) · \(quality.detail)").tag(quality)
                }
            } label: {
                Label("图片解码质量", systemImage: "photo.badge.arrow.down")
            }

            Picker(selection: $settings.imageConcurrency) {
                ForEach([2, 3, 4, 6], id: \.self) { value in
                    Text("\(value) 路").tag(value)
                }
            } label: {
                Label("图片并发加载", systemImage: "arrow.triangle.2.circlepath")
            }

            Stepper(value: $settings.thumbnailCacheMB, in: 18...72, step: 6) {
                LabeledContent("缩略图缓存", value: "\(settings.thumbnailCacheMB) MB")
            }
            Stepper(value: $settings.originalCacheMB, in: 36...144, step: 12) {
                LabeledContent("原图缓存", value: "\(settings.originalCacheMB) MB")
            }
            Stepper(value: $settings.videoFrameCacheMB, in: 8...72, step: 8) {
                LabeledContent("视频首帧缓存", value: "\(settings.videoFrameCacheMB) MB")
            }
        } header: {
            Text("图片设置")
        } footer: {
            Text("图片使用 ImageIO 下采样解码；并发越高越吃内存。所谓“高清/超清”是解码上限，不是逐字节服务器原图。缓存上限是总成本预算，不是单张图片大小。")
        }
    }

    // MARK: - AI

    private var aiSection: some View {
        Section {
            Toggle(isOn: $settings.smartClassification) {
                Label("本地智能分类", systemImage: "sparkles")
            }
            Toggle(isOn: $settings.cleanTitles) {
                Label("智能标题清洗", systemImage: "text.badge.checkmark")
            }
            LabeledContent("识别引擎", value: "本地规则引擎")
            LabeledContent("联网上传", value: "关闭")
            LabeledContent("API Key", value: "不需要")
        } header: {
            Text("AI 设置")
        } footer: {
            Text("当前 AI 能力全部在设备本地执行：按链接、文件名和页面标题做分类，并清理常见站名后缀。不会把网页地址、标题或图片上传到服务器，因此无需模型 API Key。后续版本如接入云端模型，会单独增加开关、服务商和密钥管理。")
        }
    }

    // MARK: - 播放信息

    private var playbackSection: some View {
        Section {
            NavigationLink {
                PlaybackInfoView()
            } label: {
                HStack(spacing: 12) {
                    settingIcon("waveform.path.ecg", color: settings.accent.color)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("播放信息")
                        Text(playbackSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }

            LabeledContent("技术字段", value: "分辨率 · 帧率 · 码率 · 音频格式 · 采样率")
        } header: {
            Text("播放信息")
        } footer: {
            Text("从当前或最近播放的视频读取 AVAsset 轨道参数。HLS 自适应流的码率、帧率可能是估算值或未知，页面会如实标注，不伪造数据。")
        }
    }

    private var playbackSummary: String {
        if let current = playback.currentItem {
            return "正在播放 · \(current.displayName)"
        }
        if let recent = playback.recentItems.first {
            return "最近播放 · \(recent.displayName)"
        }
        return "还没有播放记录"
    }

    // MARK: - 重置

    private var resetSection: some View {
        Section {
            Button(role: .destructive) {
                showResetConfirm = true
            } label: {
                Label("恢复默认设置", systemImage: "arrow.counterclockwise")
            }
        } footer: {
            Text("仅重置本页偏好。插件、离线下载和相册中的图片不会被删除。")
        }
    }

    private func settingIcon(_ name: String, color: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: 28, height: 28)
            .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

// MARK: - 播放信息列表

struct PlaybackInfoView: View {
    @ObservedObject private var session = PlaybackSession.shared

    var body: some View {
        List {
            Section("正在播放") {
                if let item = session.currentItem {
                    NavigationLink {
                        MediaInfoDetailView(item: item)
                    } label: {
                        mediaSummary(item, badge: "当前")
                    }
                } else {
                    Text("当前没有正在播放的视频")
                        .foregroundStyle(.secondary)
                }
            }

            Section("最近播放") {
                if session.recentItems.isEmpty {
                    Text("播放一个视频后，这里会保留最近 8 条记录")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(session.recentItems) { item in
                        NavigationLink {
                            MediaInfoDetailView(item: item)
                        } label: {
                            mediaSummary(item, badge: item.kind.label)
                        }
                    }
                }
            }

            Section("会读取哪些字段") {
                LabeledContent("视频", value: "分辨率、帧率、码率、编码")
                LabeledContent("音频", value: "格式、采样率、声道、码率")
                LabeledContent("媒体", value: "时长、文件大小、容器、地址")
            }
        }
        .navigationTitle("播放信息")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func mediaSummary(_ item: MediaItem, badge: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: item.kind.symbolName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(item.kind == .hls ? Color.orange : Color.blue, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(item.displayName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text("\(item.host) · \(badge)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - 技术信息详情

struct MediaInfoDetailView: View {
    let item: MediaItem
    @State private var info = MediaTechnicalInfo()
    @State private var loading = true
    @State private var loadError: String?

    var body: some View {
        List {
            Section("媒体") {
                LabeledContent("标题", value: item.displayName)
                LabeledContent("格式", value: "\(item.kind.label) · \(fileExtension)")
                LabeledContent("来源", value: item.host)
                LabeledContent("播放地址", value: item.isInPageOnly ? "网页内部流" : "可直链")
            }

            Section("视频") {
                LabeledContent("分辨率", value: info.resolution)
                LabeledContent("帧率", value: info.frameRate)
                LabeledContent("视频码率", value: info.videoBitrate)
                LabeledContent("视频编码", value: info.videoCodec)
            }

            Section("音频") {
                LabeledContent("音频格式", value: info.audioCodec)
                LabeledContent("采样率", value: info.sampleRate)
                LabeledContent("声道", value: info.channels)
                LabeledContent("音频码率", value: info.audioBitrate)
            }

            Section("其他") {
                LabeledContent("时长", value: info.duration)
                LabeledContent("文件大小", value: info.fileSize)
                LabeledContent("容器 / 协议", value: info.container)
                LabeledContent("读取状态", value: info.status)
            }

            Section("地址") {
                Text(item.url.absoluteString)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
                Button {
                    UIPasteboard.general.string = item.url.absoluteString
                } label: {
                    Label("复制直链", systemImage: "doc.on.doc")
                }
            }

            if let error = loadError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.footnote)
                } footer: {
                    Text("部分 HLS/DASH 流需要登录 Cookie、DRM 或由播放器动态协商，轨道参数可能无法离线读取。")
                }
            }
        }
        .navigationTitle("播放信息")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if loading {
                ProgressView("正在读取轨道信息…")
                    .padding(18)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
        .task(id: item.key) {
            await loadInfo()
        }
    }

    private func loadInfo() async {
        loading = true
        loadError = nil
        let result = await MediaInfoReader.read(item)
        info = result.info
        loadError = result.error
        loading = false
    }

    private var fileExtension: String {
        let ext = item.url.pathExtension.uppercased()
        return ext.isEmpty ? "无扩展名" : ext
    }
}

// MARK: - 技术信息读取

struct MediaTechnicalInfo {
    var resolution = "未知"
    var frameRate = "未知"
    var videoBitrate = "未知"
    var videoCodec = "未知"
    var audioCodec = "未知"
    var sampleRate = "未知"
    var channels = "未知"
    var audioBitrate = "未知"
    var duration = "未知"
    var fileSize = "未知"
    var container = "未知"
    var status = "等待读取"
}

enum MediaInfoReader {
    struct Result {
        let info: MediaTechnicalInfo
        let error: String?
    }

    static func read(_ item: MediaItem) async -> Result {
        var info = MediaTechnicalInfo()
        info.container = "\(item.kind.label) · \(item.url.scheme ?? "unknown")"
        info.status = "正在读取"

        let asset = makeAsset(for: item)
        do {
            var value = MediaTechnicalInfo()
            value.container = "\(item.kind.label) · \(item.url.scheme ?? "unknown")"

            if let duration = try? await asset.load(.duration) {
                let seconds = duration.seconds
                if seconds.isFinite, seconds > 0 {
                    value.duration = Self.timeText(seconds)
                }
            }

            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            if let track = videoTracks.first {
                let size = track.naturalSize
                let transformed = CGRect(origin: .zero, size: size).applying(track.preferredTransform)
                let width = abs(transformed.width)
                let height = abs(transformed.height)
                if width > 0, height > 0 {
                    value.resolution = "\(Int(width.rounded())) × \(Int(height.rounded()))"
                }

                let fps = track.nominalFrameRate
                if fps.isFinite, fps > 0 {
                    value.frameRate = String(format: "%.2f fps", fps)
                }

                let rate = track.estimatedDataRate
                if rate.isFinite, rate > 0 {
                    value.videoBitrate = Self.bitrateText(rate)
                } else if item.kind == .hls {
                    value.videoBitrate = "自适应码率（未报告）"
                }

                if let descriptions = try? await track.load(.formatDescriptions),
                   let description = descriptions.first {
                    value.videoCodec = Self.codecName(CMFormatDescriptionGetMediaSubType(description))
                }
            }

            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            if let track = audioTracks.first {
                if let descriptions = try? await track.load(.formatDescriptions),
                   let description = descriptions.first {
                    let mediaSubType = CMFormatDescriptionGetMediaSubType(description)
                    value.audioCodec = Self.codecName(mediaSubType)
                    if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee {
                        if asbd.mSampleRate > 0 {
                            value.sampleRate = String(format: "%.1f kHz", asbd.mSampleRate / 1000)
                        }
                        if asbd.mChannelsPerFrame > 0 {
                            value.channels = "\(asbd.mChannelsPerFrame) 声道"
                        }
                    }
                }

                let rate = track.estimatedDataRate
                if rate.isFinite, rate > 0 {
                    value.audioBitrate = Self.bitrateText(rate)
                } else if item.kind == .hls {
                    value.audioBitrate = "随主码率自适应"
                }
            }

            if item.url.isFileURL,
               let attributes = try? FileManager.default.attributesOfItem(atPath: item.url.path),
               let size = attributes[.size] as? NSNumber {
                value.fileSize = ByteCountFormatter.string(fromByteCount: size.int64Value, countStyle: .file)
            }

            value.status = "读取成功"
            return Result(info: value, error: nil)
        } catch {
            info.status = "无法读取"
            return Result(info: info, error: error.localizedDescription)
        }
    }

    private static func makeAsset(for item: MediaItem) -> AVURLAsset {
        var headers: [String: String] = [
            "User-Agent": BrowserController.mobileUserAgentString,
            "Accept": "*/*"
        ]
        if let referer = item.frameURL, let refererURL = URL(string: referer) {
            headers["Referer"] = referer
            if let scheme = refererURL.scheme, let host = refererURL.host {
                headers["Origin"] = "\(scheme)://\(host)"
            }
        }
        if let cookies = HTTPCookieStorage.shared.cookies(for: item.url), !cookies.isEmpty,
           let cookie = HTTPCookie.requestHeaderFields(with: cookies)["Cookie"] {
            headers["Cookie"] = cookie
        }
        let options: [String: Any]? = headers.isEmpty ? nil : ["AVURLAssetHTTPHeaderFieldsKey": headers]
        return AVURLAsset(url: item.url, options: options)
    }

    private static func bitrateText(_ bitsPerSecond: Float) -> String {
        if bitsPerSecond >= 1_000_000 {
            return String(format: "%.2f Mbps", bitsPerSecond / 1_000_000)
        }
        return String(format: "%.0f kbps", bitsPerSecond / 1000)
    }

    private static func codecName(_ code: FourCharCode) -> String {
        switch code {
        case 0x61766331, 0x61766333: // avc1 / avc3
            return "H.264 / AVC"
        case 0x68766331, 0x68657631: // hvc1 / hev1
            return "H.265 / HEVC"
        case 0x61763031: // av01
            return "AV1"
        case 0x76703039: // vp09
            return "VP9"
        case 0x6D703476: // mp4v
            return "MPEG-4 Visual"
        case 0x6D703461: // mp4a
            return "AAC"
        case 0x61632D33: // ac-3
            return "AC-3"
        case 0x65632D33: // ec-3
            return "E-AC-3"
        case 0x616C6163: // alac
            return "ALAC"
        case 0x4F707573: // Opus
            return "Opus"
        case 0x6C70636D: // lpcm
            return "LPCM"
        default:
            return fourCCString(code)
        }
    }

    private static func fourCCString(_ code: FourCharCode) -> String {
        let bytes: [UInt8] = [
            UInt8((code >> 24) & 0xFF),
            UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF),
            UInt8(code & 0xFF)
        ]
        let text = String(bytes: bytes, encoding: .ascii) ?? ""
        return text.isEmpty ? "未知" : text
    }

    private static func timeText(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "未知" }
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }
}
