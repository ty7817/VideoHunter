//
//  ContentView.swift
//  VideoHunter
//
//  主界面：地址栏 + 内置浏览器 + 识别结果列表。
//

import SwiftUI
import UIKit
import Combine

struct ContentView: View {
    @StateObject private var controller = BrowserController()
    @StateObject private var siteCrawler = SiteCrawler()
    @State private var input = ""
    @FocusState private var addressFocused: Bool
    @State private var activeSheet: ActiveSheet?
    @State private var toastText: String?

    private enum ActiveSheet: String, Identifiable {
        case pageList
        case imageList
        case siteScan
        case plugins

        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            content
        }
        .background(Color(uiColor: .systemBackground))
        .fullScreenCover(item: $controller.directItem) { item in
            PlayerScreen(item: item, referer: controller.pageURLString, onGoHome: { controller.goHome() })
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .pageList:
                MediaListSheet(sniffer: controller.sniffer, pageURL: controller.pageURLString)
            case .imageList:
                ImageListSheet(sniffer: controller.imageSniffer, pageURL: controller.pageURLString)
            case .siteScan:
                SiteScanSheet(
                    crawler: siteCrawler,
                    startURL: controller.pageURL,
                    pageTitle: controller.pageTitle
                )
            case .plugins:
                PluginListView()
            }
        }
        .overlay(alignment: .bottom) {
            toast
        }
        .onReceive(controller.$addressText) { value in
            if !addressFocused {
                input = value
            }
        }
        .onReceive(controller.$lastError) { value in
            if let value = value, !value.isEmpty {
                flash(value)
            }
        }
    }

    // MARK: - 顶部地址栏

    private var topBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Button {
                    controller.goHome()
                    input = ""
                    activeSheet = nil
                    flash("已回到主页")
                } label: {
                    Image(systemName: "house.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 31, height: 31)
                        .background(
                            Circle().fill(Color.accentColor.opacity(0.12))
                        )
                }
                .accessibilityLabel("回到主页")

                Button {
                    controller.goBack()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                }
                .disabled(!controller.canGoBack)

                HStack(spacing: 6) {
                    Image(systemName: "globe")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    TextField("粘贴网页链接，例如 https://…", text: $input)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        .keyboardType(.URL)
                        .submitLabel(.go)
                        .focused($addressFocused)
                        .font(.callout)
                        .onSubmit { openURL() }

                    if !input.isEmpty {
                        Button {
                            input = ""
                            addressFocused = true
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(uiColor: .secondarySystemBackground))
                )

                Button {
                    controller.goForward()
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 16, weight: .semibold))
                }
                .disabled(!controller.canGoForward)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .buttonStyle(.borderless)

            if controller.isLoading {
                ProgressView(value: max(controller.progress, 0.02))
                    .progressViewStyle(.linear)
                    .frame(height: 2)
            } else {
                Divider()
            }

            if controller.hasLoadedPage {
                actionRow
            }
        }
        .background(.bar)
    }

    // MARK: - 网页区域

    private var content: some View {
        Group {
            if controller.hasLoadedPage {
                BrowserView(controller: controller)
            } else {
                placeholder
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var placeholder: some View {
        ScrollView {
            VStack(spacing: 16) {
                Image(systemName: "play.rectangle.fill")
                    .font(.system(size: 56, weight: .light))
                    .foregroundStyle(Color.accentColor)

                Text("粘贴网页链接，自动识别页面里的视频和图片")
                    .font(.headline)
                    .multilineTextAlignment(.center)

                Text("会实时扫描页面里的 video 标签、网络请求和脚本媒体地址，也会读取 img、srcset、og:image 等图片资源。视频和图片各有一个独立的结果页。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)

                HStack(spacing: 8) {
                    tag("m3u8")
                    tag("mp4")
                    tag("网页视频")
                    tag("网页图片")
                }
                .padding(.top, 2)

                HStack(spacing: 10) {
                    Button {
                        input = BrowserController.demoURL
                        openURL()
                    } label: {
                        Label("示例 HLS", systemImage: "play.circle")
                            .font(.footnote)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        activeSheet = .plugins
                    } label: {
                        Label("插件管理", systemImage: "puzzlepiece.extension")
                            .font(.footnote)
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.top, 4)
            }
            .padding(.vertical, 48)
            .padding(.horizontal, 28)
            .frame(maxWidth: .infinity)
        }
    }

    private func tag(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color(uiColor: .tertiarySystemFill)))
            .foregroundStyle(.secondary)
    }

    // MARK: - 底部工具栏

    private var actionRow: some View {
        HStack(spacing: 8) {
            Button {
                activeSheet = .pageList
            } label: {
                chip(
                    icon: "play.rectangle.on.rectangle",
                    text: controller.sniffer.items.isEmpty ? "视频" : "视频 \(controller.sniffer.items.count)"
                )
            }

            Button {
                activeSheet = .imageList
            } label: {
                chip(
                    icon: "photo.on.rectangle",
                    text: controller.imageSniffer.items.isEmpty ? "图片" : "图片 \(controller.imageSniffer.items.count)"
                )
            }

            Button {
                activeSheet = .siteScan
            } label: {
                chip(icon: "globe", text: "整站扫描", highlighted: true)
            }

            Button {
                controller.rescan()
                flash("已重新扫描本页")
            } label: {
                Image(systemName: "viewfinder")
                    .font(.footnote)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color(uiColor: .tertiarySystemFill)))
            }

            Spacer(minLength: 0)

            Menu {
                Button {
                    controller.setDesktopUserAgent(!controller.desktopUserAgent)
                    controller.reload()
                } label: {
                    Label(
                        controller.desktopUserAgent ? "切换为移动版 UA" : "切换为桌面版 UA",
                        systemImage: "safari"
                    )
                }
                Button {
                    activeSheet = .plugins
                } label: {
                    Label("插件管理", systemImage: "puzzlepiece.extension")
                }
                Button {
                    controller.clearWebsiteData()
                    flash("已清除网页缓存，重新加载后生效")
                } label: {
                    Label("清除网页缓存", systemImage: "trash")
                }
                Button {
                    controller.goHome()
                } label: {
                    Label("回到首页", systemImage: "house")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.footnote)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .buttonStyle(.borderless)
    }

    private func chip(icon: String, text: String, highlighted: Bool = false) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
            Text(text)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule().fill(
                highlighted
                    ? Color.accentColor.opacity(0.15)
                    : Color(uiColor: .tertiarySystemFill)
            )
        )
        .foregroundStyle(highlighted ? Color.accentColor : Color.primary)
    }

    // MARK: - 交互

    private func openURL() {
        addressFocused = false
        guard let url = BrowserController.normalizedURL(from: input) else {
            flash("链接格式不正确")
            return
        }
        input = url.absoluteString
        controller.load(url)
    }

    private func flash(_ text: String) {
        toastText = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            if toastText == text {
                toastText = nil
            }
        }
    }

    @ViewBuilder
    private var toast: some View {
        if let toastText = toastText {
            Text(toastText)
                .font(.footnote)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
                .padding(.horizontal, 32)
                .padding(.bottom, 60)
                .transition(.opacity)
        }
    }
}

// MARK: - 识别结果列表

struct MediaListSheet: View {
    @ObservedObject var sniffer: MediaSniffer
    let pageURL: String?

    @Environment(\.dismiss) private var dismiss

    @State private var playing: MediaItem?
    @State private var externalItem: MediaItem?
    @State private var showExternalDialog = false
    @State private var didCopyAll = false

    var body: some View {
        NavigationStack {
            List {
                if sniffer.items.isEmpty {
                    Section {
                        emptyRow
                    }
                } else {
                    Section {
                        Text("共 \(sniffer.items.count) 个链接，已按类型分组，点按即可播放")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    ForEach(groups) { group in
                        Section {
                            ForEach(group.items) { item in
                                row(for: item)
                                    .swipeActions(edge: .trailing) {
                                        Button {
                                            UIPasteboard.general.string = item.url.absoluteString
                                        } label: {
                                            Label("复制", systemImage: "doc.on.doc")
                                        }
                                        .tint(.orange)

                                        Button {
                                            UIApplication.shared.open(item.url)
                                        } label: {
                                            Label("Safari", systemImage: "safari")
                                        }
                                        .tint(.blue)
                                    }
                            }
                        } header: {
                            HStack(spacing: 6) {
                                Image(systemName: group.category.symbolName)
                                Text("\(group.category.label) · \(group.items.count)")
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("识别到的视频")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        UIPasteboard.general.string = sniffer.items
                            .map { $0.url.absoluteString }
                            .joined(separator: "\n")
                        didCopyAll = true
                    } label: {
                        Image(systemName: didCopyAll ? "checkmark" : "doc.on.doc")
                    }
                    .disabled(sniffer.items.isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .fullScreenCover(item: $playing) { item in
            PlayerScreen(item: item, referer: pageURL, playlist: playableQueue)
        }
        .confirmationDialog(
            "这个链接无法在内置播放器里播放",
            isPresented: $showExternalDialog,
            presenting: externalItem
        ) { item in
            Button("在 Safari 中打开") {
                UIApplication.shared.open(item.url)
            }
            Button("复制链接") {
                UIPasteboard.general.string = item.url.absoluteString
            }
            Button("取消", role: .cancel) { }
        } message: { item in
            Text(item.playability.hint)
        }
    }

    private var playableQueue: [MediaItem] {
        groups.flatMap { $0.items }.filter { $0.playability == .native }
    }

    private struct CategoryGroup: Identifiable {
        let category: MediaCategory
        let items: [MediaItem]

        var id: String { category.rawValue }
    }

    private var groups: [CategoryGroup] {
        MediaCategory.allCases.compactMap { category in
            let list = sniffer.items.filter { $0.category == category }
            return list.isEmpty ? nil : CategoryGroup(category: category, items: list)
        }
    }

    private var emptyRow: some View {
        VStack(spacing: 10) {
            Image(systemName: "video.slash")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.secondary)
            Text("还没有识别到视频")
                .font(.subheadline.weight(.medium))
            Text("让网页完整加载一次，或者点一下页面里的播放按钮，再回来重新扫描。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private func row(for item: MediaItem) -> some View {
        Button {
            handleTap(item)
        } label: {
            MediaRowView(item: item)
        }
        .buttonStyle(.plain)
    }

    private func handleTap(_ item: MediaItem) {
        switch item.playability {
        case .native:
            playing = item
        case .external, .inPage:
            externalItem = item
            showExternalDialog = true
        }
    }
}
