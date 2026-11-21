//
//  SettingsStore.swift
//  VideoHunter
//
//  2.5 设置中心的数据层：统一持久化所有偏好，并给现有模块提供读取入口。
//  设计原则：每个开关都必须接到真实代码路径，不做只存在于设置页的假选项。
//

import Foundation
import SwiftUI
import Combine

extension Notification.Name {
    /// 跨站 iframe 开关变化，BrowserController 收到后立即重建嗅探脚本。
    static let vhCrossSiteChanged = Notification.Name("vhCrossSiteChanged")
}

// MARK: - 枚举

enum VHTheme: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

enum VHAccent: String, CaseIterable, Identifiable {
    case blue
    case indigo
    case teal
    case orange
    case pink
    case green

    var id: String { rawValue }

    var label: String {
        switch self {
        case .blue: return "海湾蓝"
        case .indigo: return "靛紫"
        case .teal: return "青绿"
        case .orange: return "暖橙"
        case .pink: return "莓果"
        case .green: return "松针"
        }
    }

    var color: Color {
        switch self {
        case .blue: return Color(red: 0.16, green: 0.47, blue: 0.94)
        case .indigo: return Color(red: 0.38, green: 0.31, blue: 0.90)
        case .teal: return Color(red: 0.05, green: 0.61, blue: 0.58)
        case .orange: return Color(red: 0.94, green: 0.47, blue: 0.20)
        case .pink: return Color(red: 0.86, green: 0.24, blue: 0.46)
        case .green: return Color(red: 0.20, green: 0.59, blue: 0.33)
        }
    }
}

enum VHListDensity: String, CaseIterable, Identifiable {
    case compact
    case standard
    case relaxed

    var id: String { rawValue }

    var label: String {
        switch self {
        case .compact: return "紧凑"
        case .standard: return "标准"
        case .relaxed: return "宽松"
        }
    }

    var verticalPadding: CGFloat {
        switch self {
        case .compact: return 5
        case .standard: return 8
        case .relaxed: return 12
        }
    }

    var titleFont: Font {
        switch self {
        case .compact: return .footnote.weight(.semibold)
        case .standard: return .subheadline.weight(.semibold)
        case .relaxed: return .body.weight(.semibold)
        }
    }
}

enum VHThumbnailSize: String, CaseIterable, Identifiable {
    case small
    case medium
    case large

    var id: String { rawValue }

    var label: String {
        switch self {
        case .small: return "小"
        case .medium: return "中"
        case .large: return "大"
        }
    }

    var width: CGFloat {
        switch self {
        case .small: return 56
        case .medium: return 72
        case .large: return 92
        }
    }

    var height: CGFloat {
        switch self {
        case .small: return 38
        case .medium: return 48
        case .large: return 62
        }
    }

    var thumbnailMaxWidth: CGFloat {
        switch self {
        case .small: return 220
        case .medium: return 300
        case .large: return 420
        }
    }
}

enum VHImageQuality: String, CaseIterable, Identifiable {
    case standard
    case high
    case ultra

    var id: String { rawValue }

    var label: String {
        switch self {
        case .standard: return "标准"
        case .high: return "高清"
        case .ultra: return "超清"
        }
    }

    var detail: String {
        switch self {
        case .standard: return "最长边 2048 px"
        case .high: return "最长边 3072 px"
        case .ultra: return "最长边 4096 px"
        }
    }

    var maxPixelSize: CGFloat {
        switch self {
        case .standard: return 2048
        case .high: return 3072
        case .ultra: return 4096
        }
    }
}

enum VHPlaybackRate: Double, CaseIterable, Identifiable {
    case half = 0.5
    case threeQuarter = 0.75
    case normal = 1.0
    case oneQuarter = 1.25
    case oneHalf = 1.5
    case double = 2.0

    var id: Double { rawValue }

    var label: String {
        if rawValue == 1.0 { return "1.0x（正常）" }
        return "\(String(format: "%.2g", rawValue))x"
    }
}

enum VHFillMode: String, CaseIterable, Identifiable {
    case fit
    case fill

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fit: return "适应画面"
        case .fill: return "填充裁切"
        }
    }
}

enum VHSeekStep: Int, CaseIterable, Identifiable {
    case ten = 10
    case fifteen = 15
    case thirty = 30
    case sixty = 60

    var id: Int { rawValue }
    var label: String { "\(rawValue) 秒" }
}

enum VHScanInterval: Int, CaseIterable, Identifiable {
    case two = 2
    case three = 3
    case five = 5
    case eight = 8

    var id: Int { rawValue }
    var label: String { "\(rawValue) 秒" }
}

// MARK: - 设置存储

final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    // 插件
    @Published var pluginsEnabled: Bool = true {
        didSet {
            defaults.set(pluginsEnabled, forKey: K.pluginsEnabled)
            NotificationCenter.default.post(name: .vhPluginsChanged, object: nil)
        }
    }

    // 后台
    @Published var backgroundPlayback: Bool = true {
        didSet { defaults.set(backgroundPlayback, forKey: K.backgroundPlayback) }
    }
    @Published var autoPictureInPicture: Bool = true {
        didSet { defaults.set(autoPictureInPicture, forKey: K.autoPictureInPicture) }
    }
    @Published var resumeAfterInterruption: Bool = true {
        didSet { defaults.set(resumeAfterInterruption, forKey: K.resumeAfterInterruption) }
    }
    @Published var resumeAfterHeadphoneUnplug: Bool = true {
        didSet { defaults.set(resumeAfterHeadphoneUnplug, forKey: K.resumeAfterHeadphoneUnplug) }
    }
    @Published var allowCellularDownloads: Bool = true {
        didSet { defaults.set(allowCellularDownloads, forKey: K.allowCellularDownloads) }
    }
    @Published var keepScreenAwake: Bool = true {
        didSet { defaults.set(keepScreenAwake, forKey: K.keepScreenAwake) }
    }

    // 视频
    @Published var autoScan: Bool = true {
        didSet { defaults.set(autoScan, forKey: K.autoScan) }
    }
    @Published var scanInterval: VHScanInterval = .three {
        didSet { defaults.set(scanInterval.rawValue, forKey: K.scanInterval) }
    }
    @Published var maxVideoItems: Int = 200 {
        didSet { defaults.set(maxVideoItems, forKey: K.maxVideoItems) }
    }
    @Published var includeCrossSiteFrames: Bool = false {
        didSet {
            defaults.set(includeCrossSiteFrames, forKey: K.includeCrossSiteFrames)
            NotificationCenter.default.post(name: .vhCrossSiteChanged, object: nil)
        }
    }
    @Published var filterAdFrames: Bool = true {
        didSet { defaults.set(filterAdFrames, forKey: K.filterAdFrames) }
    }
    @Published var preferHLS: Bool = true {
        didSet { defaults.set(preferHLS, forKey: K.preferHLS) }
    }
    @Published var loadVideoThumbnails: Bool = true {
        didSet { defaults.set(loadVideoThumbnails, forKey: K.loadVideoThumbnails) }
    }
    @Published var autoPlayNext: Bool = true {
        didSet { defaults.set(autoPlayNext, forKey: K.autoPlayNext) }
    }

    // 外观
    @Published var theme: VHTheme = .system {
        didSet { defaults.set(theme.rawValue, forKey: K.theme) }
    }
    @Published var accent: VHAccent = .blue {
        didSet { defaults.set(accent.rawValue, forKey: K.accent) }
    }
    @Published var listDensity: VHListDensity = .standard {
        didSet { defaults.set(listDensity.rawValue, forKey: K.listDensity) }
    }
    @Published var thumbnailSize: VHThumbnailSize = .medium {
        didSet { defaults.set(thumbnailSize.rawValue, forKey: K.thumbnailSize) }
    }
    @Published var showCategoryBadges: Bool = true {
        didSet { defaults.set(showCategoryBadges, forKey: K.showCategoryBadges) }
    }
    @Published var showHost: Bool = true {
        didSet { defaults.set(showHost, forKey: K.showHost) }
    }
    @Published var showIframeBadges: Bool = true {
        didSet { defaults.set(showIframeBadges, forKey: K.showIframeBadges) }
    }

    // 图片
    @Published var scanImages: Bool = true {
        didSet { defaults.set(scanImages, forKey: K.scanImages) }
    }
    @Published var scanSiteImages: Bool = true {
        didSet { defaults.set(scanSiteImages, forKey: K.scanSiteImages) }
    }
    @Published var maxImageItems: Int = 300 {
        didSet { defaults.set(maxImageItems, forKey: K.maxImageItems) }
    }
    @Published var imageQuality: VHImageQuality = .high {
        didSet { defaults.set(imageQuality.rawValue, forKey: K.imageQuality) }
    }
    @Published var imageConcurrency: Int = 4 {
        didSet {
            defaults.set(imageConcurrency, forKey: K.imageConcurrency)
            let value = max(1, min(6, imageConcurrency))
            Task { await RemoteImageLoader.updateConcurrency(value) }
        }
    }
    @Published var thumbnailCacheMB: Int = 36 {
        didSet {
            defaults.set(thumbnailCacheMB, forKey: K.thumbnailCacheMB)
            RemoteImageLoader.applyCacheLimits(thumbnailMB: thumbnailCacheMB, originalMB: originalCacheMB)
        }
    }
    @Published var originalCacheMB: Int = 72 {
        didSet {
            defaults.set(originalCacheMB, forKey: K.originalCacheMB)
            RemoteImageLoader.applyCacheLimits(thumbnailMB: thumbnailCacheMB, originalMB: originalCacheMB)
        }
    }
    @Published var videoFrameCacheMB: Int = 24 {
        didSet {
            defaults.set(videoFrameCacheMB, forKey: K.videoFrameCacheMB)
            VideoFrameStore.applyCacheLimit(videoFrameCacheMB)
        }
    }

    // AI（本地离线增强）
    @Published var smartClassification: Bool = true {
        didSet { defaults.set(smartClassification, forKey: K.smartClassification) }
    }
    @Published var cleanTitles: Bool = true {
        didSet { defaults.set(cleanTitles, forKey: K.cleanTitles) }
    }

    // 播放器
    @Published var playerRate: VHPlaybackRate = .normal {
        didSet { defaults.set(playerRate.rawValue, forKey: K.playerRate) }
    }
    @Published var fillMode: VHFillMode = .fit {
        didSet { defaults.set(fillMode.rawValue, forKey: K.fillMode) }
    }
    @Published var autoHideControls: Bool = true {
        didSet { defaults.set(autoHideControls, forKey: K.autoHideControls) }
    }
    @Published var autoHideDelay: Double = 3.5 {
        didSet { defaults.set(autoHideDelay, forKey: K.autoHideDelay) }
    }
    @Published var seekStep: VHSeekStep = .fifteen {
        didSet { defaults.set(seekStep.rawValue, forKey: K.seekStep) }
    }
    @Published var loopPlayback: Bool = false {
        didSet { defaults.set(loopPlayback, forKey: K.loopPlayback) }
    }

    private init() {
        pluginsEnabled = AppSettings.readBool(K.pluginsEnabled, true)
        backgroundPlayback = AppSettings.readBool(K.backgroundPlayback, true)
        autoPictureInPicture = AppSettings.readBool(K.autoPictureInPicture, true)
        resumeAfterInterruption = AppSettings.readBool(K.resumeAfterInterruption, true)
        resumeAfterHeadphoneUnplug = AppSettings.readBool(K.resumeAfterHeadphoneUnplug, true)
        allowCellularDownloads = AppSettings.readBool(K.allowCellularDownloads, true)
        keepScreenAwake = AppSettings.readBool(K.keepScreenAwake, true)

        autoScan = AppSettings.readBool(K.autoScan, true)
        scanInterval = VHScanInterval(rawValue: AppSettings.readInt(K.scanInterval, 3)) ?? .three
        maxVideoItems = AppSettings.readInt(K.maxVideoItems, 200)
        includeCrossSiteFrames = AppSettings.readBool(K.includeCrossSiteFrames, false)
        filterAdFrames = AppSettings.readBool(K.filterAdFrames, true)
        preferHLS = AppSettings.readBool(K.preferHLS, true)
        loadVideoThumbnails = AppSettings.readBool(K.loadVideoThumbnails, true)
        autoPlayNext = AppSettings.readBool(K.autoPlayNext, true)

        theme = VHTheme(rawValue: UserDefaults.standard.string(forKey: K.theme) ?? "") ?? .system
        accent = VHAccent(rawValue: UserDefaults.standard.string(forKey: K.accent) ?? "") ?? .blue
        listDensity = VHListDensity(rawValue: UserDefaults.standard.string(forKey: K.listDensity) ?? "") ?? .standard
        thumbnailSize = VHThumbnailSize(rawValue: UserDefaults.standard.string(forKey: K.thumbnailSize) ?? "") ?? .medium
        showCategoryBadges = AppSettings.readBool(K.showCategoryBadges, true)
        showHost = AppSettings.readBool(K.showHost, true)
        showIframeBadges = AppSettings.readBool(K.showIframeBadges, true)

        scanImages = AppSettings.readBool(K.scanImages, true)
        scanSiteImages = AppSettings.readBool(K.scanSiteImages, true)
        maxImageItems = AppSettings.readInt(K.maxImageItems, 300)
        imageQuality = VHImageQuality(rawValue: UserDefaults.standard.string(forKey: K.imageQuality) ?? "") ?? .high
        imageConcurrency = AppSettings.readInt(K.imageConcurrency, 4)
        thumbnailCacheMB = AppSettings.readInt(K.thumbnailCacheMB, 36)
        originalCacheMB = AppSettings.readInt(K.originalCacheMB, 72)
        videoFrameCacheMB = AppSettings.readInt(K.videoFrameCacheMB, 24)

        smartClassification = AppSettings.readBool(K.smartClassification, true)
        cleanTitles = AppSettings.readBool(K.cleanTitles, true)

        playerRate = VHPlaybackRate(rawValue: UserDefaults.standard.double(forKey: K.playerRate)) ?? .normal
        fillMode = VHFillMode(rawValue: UserDefaults.standard.string(forKey: K.fillMode) ?? "") ?? .fit
        autoHideControls = AppSettings.readBool(K.autoHideControls, true)
        autoHideDelay = UserDefaults.standard.object(forKey: K.autoHideDelay) == nil
            ? 3.5
            : UserDefaults.standard.double(forKey: K.autoHideDelay)
        seekStep = VHSeekStep(rawValue: AppSettings.readInt(K.seekStep, 15)) ?? .fifteen
        loopPlayback = AppSettings.readBool(K.loopPlayback, false)
    }

    /// 恢复本页所有偏好为出厂值，保留插件脚本本身和下载记录。
    func resetToDefaults() {
        pluginsEnabled = true
        backgroundPlayback = true
        autoPictureInPicture = true
        resumeAfterInterruption = true
        resumeAfterHeadphoneUnplug = true
        allowCellularDownloads = true
        keepScreenAwake = true

        autoScan = true
        scanInterval = .three
        maxVideoItems = 200
        includeCrossSiteFrames = false
        filterAdFrames = true
        preferHLS = true
        loadVideoThumbnails = true
        autoPlayNext = true

        theme = .system
        accent = .blue
        listDensity = .standard
        thumbnailSize = .medium
        showCategoryBadges = true
        showHost = true
        showIframeBadges = true

        scanImages = true
        scanSiteImages = true
        maxImageItems = 300
        imageQuality = .high
        imageConcurrency = 4
        thumbnailCacheMB = 36
        originalCacheMB = 72
        videoFrameCacheMB = 24

        smartClassification = true
        cleanTitles = true

        playerRate = .normal
        fillMode = .fit
        autoHideControls = true
        autoHideDelay = 3.5
        seekStep = .fifteen
        loopPlayback = false
    }

    // MARK: - 读取辅助

    private static func readBool(_ key: String, _ fallback: Bool) -> Bool {
        let store = UserDefaults.standard
        guard store.object(forKey: key) != nil else { return fallback }
        return store.bool(forKey: key)
    }

    private static func readInt(_ key: String, _ fallback: Int) -> Int {
        let store = UserDefaults.standard
        guard store.object(forKey: key) != nil else { return fallback }
        return store.integer(forKey: key)
    }

    private enum K {
        static let pluginsEnabled = "vh.settings.pluginsEnabled"

        static let backgroundPlayback = "vh.settings.backgroundPlayback"
        static let autoPictureInPicture = "vh.settings.autoPictureInPicture"
        static let resumeAfterInterruption = "vh.settings.resumeAfterInterruption"
        static let resumeAfterHeadphoneUnplug = "vh.settings.resumeAfterHeadphoneUnplug"
        static let allowCellularDownloads = "vh.settings.allowCellularDownloads"
        static let keepScreenAwake = "vh.settings.keepScreenAwake"

        static let autoScan = "vh.settings.autoScan"
        static let scanInterval = "vh.settings.scanInterval"
        static let maxVideoItems = "vh.settings.maxVideoItems"
        static let includeCrossSiteFrames = "vh.settings.includeCrossSiteFrames"
        static let filterAdFrames = "vh.settings.filterAdFrames"
        static let preferHLS = "vh.settings.preferHLS"
        static let loadVideoThumbnails = "vh.settings.loadVideoThumbnails"
        static let autoPlayNext = "vh.settings.autoPlayNext"

        static let theme = "vh.settings.theme"
        static let accent = "vh.settings.accent"
        static let listDensity = "vh.settings.listDensity"
        static let thumbnailSize = "vh.settings.thumbnailSize"
        static let showCategoryBadges = "vh.settings.showCategoryBadges"
        static let showHost = "vh.settings.showHost"
        static let showIframeBadges = "vh.settings.showIframeBadges"

        static let scanImages = "vh.settings.scanImages"
        static let scanSiteImages = "vh.settings.scanSiteImages"
        static let maxImageItems = "vh.settings.maxImageItems"
        static let imageQuality = "vh.settings.imageQuality"
        static let imageConcurrency = "vh.settings.imageConcurrency"
        static let thumbnailCacheMB = "vh.settings.thumbnailCacheMB"
        static let originalCacheMB = "vh.settings.originalCacheMB"
        static let videoFrameCacheMB = "vh.settings.videoFrameCacheMB"

        static let smartClassification = "vh.settings.smartClassification"
        static let cleanTitles = "vh.settings.cleanTitles"

        static let playerRate = "vh.settings.playerRate"
        static let fillMode = "vh.settings.fillMode"
        static let autoHideControls = "vh.settings.autoHideControls"
        static let autoHideDelay = "vh.settings.autoHideDelay"
        static let seekStep = "vh.settings.seekStep"
        static let loopPlayback = "vh.settings.loopPlayback"
    }
}

// MARK: - 标题清洗

enum MediaTitleFormatter {
    /// 去掉常见站名后缀和视频扩展名；只影响列表/播放器显示，不改下载文件名。
    static func clean(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return raw }

        let suffixes = [
            " - 哔哩哔哩", "_哔哩哔哩", " - bilibili", "_bilibili",
            " - 抖音", "_抖音", " - 快手", "_快手",
            " - YouTube", "_YouTube", " - 腾讯视频", "_腾讯视频",
            " - 爱奇艺", "_爱奇艺", " - 优酷", "_优酷"
        ]
        for suffix in suffixes where text.lowercased().hasSuffix(suffix.lowercased()) {
            text.removeLast(suffix.count)
            break
        }

        let extensions = ["mp4", "m3u8", "webm", "mov", "m4v", "flv", "mkv"]
        if let dot = text.lastIndex(of: "."),
           extensions.contains(String(text[text.index(after: dot)...]).lowercased()) {
            text.removeSubrange(dot...)
        }

        text = text.replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? raw : text
    }
}

extension MediaItem {
    /// 列表和播放器显示用标题，跟随「智能标题清洗」设置。
    var displayName: String {
        AppSettings.shared.cleanTitles ? MediaTitleFormatter.clean(fileName) : fileName
    }
}

// MARK: - 最近播放（播放信息数据源）

final class PlaybackSession: ObservableObject {
    static let shared = PlaybackSession()

    @Published private(set) var currentItem: MediaItem?
    @Published private(set) var recentItems: [MediaItem] = []

    private init() {}

    func record(_ item: MediaItem) {
        currentItem = item
        recentItems.removeAll { $0.id == item.id || $0.url == item.url }
        recentItems.insert(item, at: 0)
        if recentItems.count > 8 {
            recentItems.removeLast(recentItems.count - 8)
        }
    }

    func clearCurrent() {
        currentItem = nil
    }
}
