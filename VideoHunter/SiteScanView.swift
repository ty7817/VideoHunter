//
//  SiteScanView.swift
//  VideoHunter
//
//  整站扫描的设置页、进度页和结果页。
//

import SwiftUI
import UIKit

struct SiteScanSheet: View {
    @ObservedObject var crawler: SiteCrawler
    let startURL: URL?
    let pageTitle: String

    @Environment(\.dismiss) private var dismiss

    @State private var groupMode: GroupMode = .page
    @State private var playing: MediaItem?
    @State private var externalItem: MediaItem?
    @State private var showExternalDialog = false
    @State private var didCopyAll = false
    @State private var resultTab: ResultTab = .media
    @State private var previewImage: ImageItem?
    @State private var searchText = ""
    @State private var selectedKind: MediaKind?
    @State private var visibleLimit = 80

    var body: some View {
        NavigationStack {
            Group {
                if crawler.isRunning {
                    runningView
                } else if crawler.pages.isEmpty {
                    setupView
                } else {
                    resultView
                }
            }
            .navigationTitle("整站扫描")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if crawler.isRunning {
                        Button("取消扫描") { crawler.cancel() }
                    } else {
                        Button("关闭") { dismiss() }
                    }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Menu {
                        Button("全部格式") { selectedKind = nil }
                        ForEach(MediaKind.allCases, id: \.self) { kind in
                            Button(kind.label) { selectedKind = kind }
                        }
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                    }

                    Button {
                        let urls = resultTab == .images
                            ? filteredImages.map { $0.url.absoluteString }
                            : filteredMedia.map { $0.url.absoluteString }
                        UIPasteboard.general.string = urls.joined(separator: "\n")
                        didCopyAll = true
                    } label: {
                        Image(systemName: didCopyAll ? "checkmark" : "doc.on.doc")
                    }
                    .disabled(resultTab == .images ? filteredImages.isEmpty : filteredMedia.isEmpty)
                }
            }
        }
        .interactiveDismissDisabled(crawler.isRunning)
        .fullScreenCover(item: $playing) { item in
            PlayerScreen(
                item: item,
                referer: item.frameURL ?? startURL?.absoluteString,
                playlist: allItems.filter { $0.playability == .native }
            )
        }
        .fullScreenCover(item: $previewImage) { image in
            ImageDetailView(item: image, fallbackReferer: image.frameURL.isEmpty ? startURL?.absoluteString : image.frameURL)
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

    private enum GroupMode: String, CaseIterable, Identifiable {
        case page
        case category

        var id: String { rawValue }
    }

    private enum ResultTab: String, CaseIterable, Identifiable {
        case media
        case images

        var id: String { rawValue }
    }

    private struct CategoryGroup: Identifiable {
        let category: MediaCategory
        let items: [MediaItem]

        var id: String { category.rawValue }
    }

    private struct PageSlice: Identifiable {
        let page: CrawledPage
        let items: [MediaItem]
        var id: UUID { page.id }
    }

    private struct ImageGroup: Identifiable {
        let category: ImageCategory
        let items: [ImageItem]
        var id: String { category.rawValue }
    }

    private var allItems: [MediaItem] {
        crawler.pages.flatMap { $0.items }
    }

    private var allImages: [ImageItem] {
        crawler.pages.flatMap { $0.images }
    }

    private var filteredMedia: [MediaItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return allItems.filter { item in
            if let selectedKind, item.kind != selectedKind { return false }
            guard !query.isEmpty else { return true }
            let haystack = [item.fileName, item.url.absoluteString, item.pageTitle, item.host].joined(separator: " ")
            return haystack.localizedCaseInsensitiveContains(query)
        }
    }

    private var visibleMedia: [MediaItem] {
        Array(filteredMedia.prefix(visibleLimit))
    }

    private var filteredPages: [PageSlice] {
        let keys = Set(visibleMedia.map(\.key))
        return crawler.pages.compactMap { page in
            let items = page.items.filter { keys.contains($0.key) }
            return items.isEmpty ? nil : PageSlice(page: page, items: items)
        }
    }

    private var categoryGroups: [CategoryGroup] {
        MediaCategory.allCases.compactMap { category in
            let list = visibleMedia.filter { $0.category == category }
            return list.isEmpty ? nil : CategoryGroup(category: category, items: list)
        }
    }

    private var filteredImages: [ImageItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return allImages.filter { image in
            guard !query.isEmpty else { return true }
            let haystack = [image.alt, image.url.absoluteString, image.pageTitle, image.host].joined(separator: " ")
            return haystack.localizedCaseInsensitiveContains(query)
        }
    }

    private var imageGroups: [ImageGroup] {
        ImageCategory.allCases.compactMap { category in
            let list = filteredImages.filter { $0.category == category }
            return list.isEmpty ? nil : ImageGroup(category: category, items: list)
        }
    }

    private func itemRow(_ item: MediaItem) -> some View {
        Button {
            handleTap(item)
        } label: {
            MediaRowView(item: item)
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing) {
            Button {
                UIPasteboard.general.string = item.url.absoluteString
            } label: {
                Label("复制", systemImage: "doc.on.doc")
            }
            .tint(.orange)

            if item.kind == .mp4 {
                Button {
                    DownloadManager.shared.start(item: item, referer: item.frameURL ?? startURL?.absoluteString, title: item.fileName)
                } label: {
                    Label("下载", systemImage: "arrow.down.circle")
                }
                .tint(.green)
            }

            Button {
                UIApplication.shared.open(item.url)
            } label: {
                Label("Safari", systemImage: "safari")
            }
            .tint(.blue)
        }
    }

    // MARK: - 设置

    private var setupView: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("起始页面")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(startURL?.absoluteString ?? "还没有打开网页")
                        .font(.footnote)
                        .lineLimit(3)
                    if !pageTitle.isEmpty {
                        Text(pageTitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(.vertical, 2)

                Stepper(value: $crawler.maxPages, in: 10...200, step: 10) {
                    Text("最多扫描 \(crawler.maxPages) 个页面")
                }

                Picker("跟随层级", selection: $crawler.maxDepth) {
                    ForEach(1...5, id: \.self) { level in
                        Text("\(level) 层").tag(level)
                    }
                }
                .pickerStyle(.menu)

                Toggle("只扫描同一网站", isOn: $crawler.onlySameSite)
                if crawler.onlySameSite {
                    Toggle("包含子域名", isOn: $crawler.includeSubdomains)
                }
                Toggle("包含跨站 iframe", isOn: Binding(
                    get: { crawler.allowCrossSiteFrames },
                    set: { crawler.setAllowCrossSiteFrames($0) }
                ))
            } header: {
                Text("扫描范围")
            } footer: {
                Text("从起始页开始，逐页打开站内链接，自动收集每一页里的视频和图片。跨站 iframe 默认过滤，避免把广告和统计页算进来；需要抓 YouTube/Bilibili 等嵌入内容时可打开。会先尝试读取站点的 sitemap.xml。")
            }

            Section {
                Picker("并发路数", selection: $crawler.concurrency) {
                    ForEach(1...4, id: \.self) { count in
                        Text("\(count) 路").tag(count)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("扫描速度")
            } footer: {
                Text("同时打开几个页面抓取。默认 3 路，速度大约是单路的 2～3 倍；调得越高越吃内存和流量。扫描期间固定生效。")
            }

            Section {
                Button {
                    if let url = startURL {
                        crawler.start(from: url)
                    }
                } label: {
                    HStack {
                        Spacer()
                        Label("开始扫描整站", systemImage: "globe")
                            .font(.headline)
                        Spacer()
                    }
                }
                .disabled(startURL == nil)
            } footer: {
                Text("扫描期间请不要锁屏或把 App 放到后台，系统会暂停网页加载。")
            }

            if !crawler.statusText.isEmpty {
                Section {
                    Text(crawler.statusText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - 进度

    private var runningView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ProgressView(
                    value: Double(min(crawler.visitedCount, crawler.maxPages)),
                    total: Double(max(crawler.maxPages, 1))
                )

                HStack {
                    Text("已扫描 \(crawler.visitedCount) / \(crawler.maxPages) 页")
                        .font(.footnote.weight(.medium))
                    Spacer()
                    Text("\(crawler.foundCount) 个视频 · \(crawler.foundImageCount) 张图片 · \(crawler.elapsedSeconds) 秒")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 6) {
                    Label("\(crawler.activeWorkers) 路并发", systemImage: "bolt.horizontal.circle")
                    Text("·")
                    Text("\(crawler.pagesPerMinute) 页/分钟")
                    if crawler.sitemapCount > 0 {
                        Text("·")
                        Text("sitemap \(crawler.sitemapCount) 页")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                Text(crawler.statusText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                Text(crawler.currentURL)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                Button(role: .destructive) {
                    crawler.cancel()
                } label: {
                    Label("取消扫描", systemImage: "xmark.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                if crawler.pages.isEmpty {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("正在并发扫描页面…")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 24)
                }
            }
            .padding(16)

            if !crawler.pages.isEmpty {
                pageCards
            }
        }
    }

    private var pageCards: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(crawler.pages) { page in
                VStack(alignment: .leading, spacing: 8) {
                    Text(page.displayTitle)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                    Text(page.url.absoluteString)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    ForEach(page.items) { item in
                        Button {
                            handleTap(item)
                        } label: {
                            MediaRowView(item: item)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(uiColor: .secondarySystemBackground))
                )
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 28)
    }

    // MARK: - 结果

    private var resultView: some View {
        List {
            Section {
                Text(crawler.statusText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                HStack(spacing: 0) {
                    stat(title: "页面", value: "\(crawler.visitedCount)")
                    stat(title: "视频", value: "\(crawler.foundCount)")
                    stat(title: "图片", value: "\(crawler.foundImageCount)")
                    stat(title: "耗时", value: "\(crawler.elapsedSeconds)s")
                }
                .padding(.vertical, 4)
            }

            Section {
                Picker("结果类型", selection: $resultTab) {
                    Text("视频").tag(ResultTab.media)
                    Text("图片").tag(ResultTab.images)
                }
                .pickerStyle(.segmented)
                .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))

                if resultTab == .media {
                    Picker("分组方式", selection: $groupMode) {
                        Text("按页面").tag(GroupMode.page)
                        Text("按分类").tag(GroupMode.category)
                    }
                    .pickerStyle(.segmented)
                    .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 6, trailing: 12))
                }
            }

            if resultTab == .media {
                if filteredMedia.isEmpty {
                    Section {
                        Text("没有匹配的视频。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else if groupMode == .page {
                    ForEach(filteredPages) { slice in
                        Section {
                            ForEach(slice.items) { item in
                                itemRow(item)
                            }
                        } header: {
                            Text(slice.page.displayTitle)
                        } footer: {
                            Text(slice.page.url.absoluteString)
                        }
                    }
                } else {
                    ForEach(categoryGroups) { group in
                        Section {
                            ForEach(group.items) { item in
                                itemRow(item)
                            }
                        } header: {
                            HStack(spacing: 6) {
                                Image(systemName: group.category.symbolName)
                                Text("\(group.category.label) · \(group.items.count)")
                            }
                        }
                    }
                }

                if filteredMedia.count > visibleMedia.count {
                    Section {
                        Button {
                            visibleLimit += 80
                        } label: {
                            Label("加载更多（还有 \(filteredMedia.count - visibleMedia.count) 个）", systemImage: "chevron.down")
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
            } else {
                if filteredImages.isEmpty {
                    Section {
                        Text("没有匹配的图片。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(imageGroups) { group in
                        Section {
                            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                                ForEach(group.items) { image in
                                    Button {
                                        previewImage = image
                                    } label: {
                                        ImageTile(item: image)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.vertical, 4)
                        } header: {
                            HStack(spacing: 6) {
                                Image(systemName: group.category.symbolName)
                                Text("\(group.category.label) · \(group.items.count)")
                            }
                        }
                    }
                }
            }

            Section {
                Button {
                    if let url = startURL {
                        crawler.start(from: url)
                    }
                } label: {
                    Label("按当前设置再扫一次", systemImage: "arrow.clockwise")
                }
                .disabled(startURL == nil)
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索标题、域名或链接")
    }

    private func stat(title: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.title3.weight(.semibold))
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
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
