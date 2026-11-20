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
    @State private var input = ""
    @FocusState private var addressFocused: Bool
    @State private var showList = false
    @State private var toastText: String?

    var body: some View {
        VStack(spacing: 0) {
            topBar
            content
            bottomBar
        }
        .background(Color(uiColor: .systemBackground))
        .fullScreenCover(item: $controller.directItem) { item in
            PlayerScreen(item: item, referer: controller.pageURLString)
        }
        .sheet(isPresented: $showList) {
            MediaListSheet(sniffer: controller.sniffer, pageURL: controller.pageURLString)
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
            HStack(spacing: 10) {
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

                Text("粘贴网页链接，自动识别页面里的视频")
                    .font(.headline)
                    .multilineTextAlignment(.center)

                Text("会实时扫描页面里的 video 标签、网络请求和脚本中的媒体地址，识别到后可用内置播放器全屏播放，支持画中画。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)

                HStack(spacing: 8) {
                    tag("m3u8")
                    tag("mp4")
                    tag("网页视频")
                }
                .padding(.top, 2)

                Button {
                    input = BrowserController.demoURL
                    openURL()
                } label: {
                    Label("用示例 HLS 流测试", systemImage: "play.circle")
                        .font(.footnote)
                }
                .buttonStyle(.bordered)
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

    private var bottomBar: some View {
        HStack {
            Button {
                controller.rescan()
                flash("已重新扫描页面")
            } label: {
                Label("重新扫描", systemImage: "viewfinder")
                    .font(.footnote)
            }
            .disabled(!controller.hasLoadedPage)

            Spacer()

            Button {
                showList = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "list.bullet.rectangle")
                    Text(controller.sniffer.items.isEmpty ? "视频列表" : "已发现 \(controller.sniffer.items.count) 个")
                }
                .font(.footnote.weight(.medium))
            }
            .disabled(!controller.hasLoadedPage)

            Spacer()

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
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(.bar)
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
                        ForEach(sniffer.items) { item in
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
                        Text("共 \(sniffer.items.count) 个链接 · 点按即可播放")
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
            PlayerScreen(item: item, referer: pageURL)
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
            HStack(spacing: 12) {
                Image(systemName: item.kind.symbolName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tint(for: item))
                    .frame(width: 34, height: 34)
                    .background(
                        tint(for: item).opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                    )

                VStack(alignment: .leading, spacing: 4) {
                    Text(item.fileName)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    HStack(spacing: 6) {
                        Text(item.kind.label)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(tint(for: item).opacity(0.15), in: Capsule())

                        Text(item.host)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 6)

                Image(systemName: item.playability == .native ? "play.circle.fill" : "arrow.up.right.circle")
                    .font(.system(size: 22))
                    .foregroundStyle(item.playability == .native ? Color.accentColor : Color.secondary)
            }
            .padding(.vertical, 4)
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

    private func tint(for item: MediaItem) -> Color {
        switch item.kind {
        case .hls: return .green
        case .mp4: return .blue
        case .dash: return .orange
        case .webm: return .purple
        case .other: return .gray
        }
    }
}
