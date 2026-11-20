import SwiftUI
import UIKit

struct ImageThumbnailView: View {
    let item: ImageItem
    var height: CGFloat = 112

    @State private var image: UIImage?
    @State private var failed = false
    @State private var loading = false

    var body: some View {
        ZStack {
            Rectangle().fill(Color(.secondarySystemFill))
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else if loading {
                ProgressView()
            } else {
                Image(systemName: failed ? "exclamationmark.triangle" : "photo")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .clipped()
        .contentShape(Rectangle())
        .task(id: item.key) {
            loading = true
            failed = false
            let referer = item.frameURL.isEmpty ? nil : item.frameURL
            let loaded = await RemoteImageLoader.thumbnail(for: item.url,
                                                           referer: referer,
                                                           maxWidth: 520)
            if Task.isCancelled { return }
            image = loaded
            failed = loaded == nil
            loading = false
        }
    }
}

struct ImageTile: View {
    let item: ImageItem

    var body: some View {
        VStack(spacing: 0) {
            ImageThumbnailView(item: item)
                .overlay(alignment: .topTrailing) {
                    if item.isLarge {
                        Text("原图")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Color.black.opacity(0.58), in: Capsule())
                            .padding(6)
                    }
                }
            VStack(alignment: .leading, spacing: 4) {
                Text(item.fileName)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(item.category.label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Text(item.resolutionText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(Color(.secondarySystemGroupedBackground))
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct ImageListSheet: View {
    @ObservedObject var sniffer: ImageSniffer
    let pageURL: String?

    @Environment(\.dismiss) private var dismiss
    @State private var preview: ImageItem?
    @State private var toast: String?

    private struct ImageGroup: Identifiable {
        let category: ImageCategory
        let items: [ImageItem]
        var id: String { category.rawValue }
    }

    private var groups: [ImageGroup] {
        ImageCategory.allCases.compactMap { category in
            let matches = sniffer.items.filter { $0.category == category }
            return matches.isEmpty ? nil : ImageGroup(category: category, items: matches)
        }
    }

    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10)
    ]

    var body: some View {
        NavigationStack {
            Group {
                if sniffer.items.isEmpty {
                    emptyState
                } else {
                    imageContent
                }
            }
            .navigationTitle("网页图片")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        copyAll()
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .disabled(sniffer.items.isEmpty)
                }
            }
        }
        .overlay(alignment: .top) {
            if let toast {
                Text(toast)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Color.black.opacity(0.78), in: Capsule())
                    .padding(.top, 54)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .fullScreenCover(item: $preview) { item in
            ImageDetailView(item: item, fallbackReferer: pageURL)
        }
    }

    private var imageContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 8) {
                    Label("\(sniffer.items.count) 张", systemImage: "photo.stack")
                    Text("·")
                    Text("\(groups.count) 个分类")
                    Spacer()
                    if sniffer.items.contains(where: { $0.isLarge }) {
                        Text("含高清原图")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                ForEach(groups) { group in
                    VStack(alignment: .leading, spacing: 9) {
                        HStack(spacing: 7) {
                            Image(systemName: group.category.symbolName)
                                .font(.subheadline.weight(.semibold))
                            Text(group.category.label)
                                .font(.subheadline.weight(.semibold))
                            Text("\(group.items.count)")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color(.secondarySystemFill), in: Capsule())
                            Spacer()
                        }
                        LazyVGrid(columns: columns, spacing: 10) {
                            ForEach(group.items) { item in
                                Button {
                                    preview = item
                                } label: {
                                    ImageTile(item: item)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                Text("图片来自当前网页的 img、srcset、a 直链、CSS 背景与 og:image。点击任意图片可查看原图并缩放。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 44, weight: .regular))
                .foregroundStyle(.secondary)
            Text("还没有发现图片")
                .font(.headline)
            Text("等网页加载完成后，图片会自动识别。若当前页没有图片，关闭本页后点主界面的取景器按钮重新扫描。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }

    private func copyAll() {
        let text = sniffer.items.map { $0.url.absoluteString }.joined(separator: "\n")
        UIPasteboard.general.string = text
        withAnimation { toast = "已复制 \(sniffer.items.count) 个图片链接" }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
            withAnimation { toast = nil }
        }
    }
}

struct ImageDetailView: View {
    let item: ImageItem
    let fallbackReferer: String?

    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var loading = true
    @State private var failed = false
    @State private var toast: String?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let image {
                ZoomableImageView(image: image)
                    .ignoresSafeArea(edges: .bottom)
            } else if loading {
                ProgressView("读取原图…")
                    .tint(.white)
                    .foregroundStyle(.white)
            } else {
                VStack(spacing: 14) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 44))
                    Text("原图加载失败")
                        .font(.headline)
                    Text("站点可能需要登录或防盗链。列表里的预览图来自浏览器缓存，原图会尝试使用页面 Cookie 与 Referer。")
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white.opacity(0.7))
                        .padding(.horizontal, 36)
                    Button("重试") {
                        Task { await loadOriginal(force: true) }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .foregroundStyle(.white)
            }

            VStack {
                topBar
                Spacer()
                bottomBar
            }
        }
        .task { await loadOriginal(force: false) }
        .overlay(alignment: .top) {
            if let toast {
                Text(toast)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.black.opacity(0.8), in: Capsule())
                    .padding(.top, 64)
            }
        }
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Color.black.opacity(0.55), in: Circle())
            }
            Spacer()
            Text(item.category.label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color.black.opacity(0.55), in: Capsule())
            Button {
                UIApplication.shared.open(item.url)
            } label: {
                Image(systemName: "safari")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Color.black.opacity(0.55), in: Circle())
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
    }

    private var bottomBar: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                Text(item.fileName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                Spacer(minLength: 8)
                Text(item.resolutionText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.7))
            }
            if !item.alt.isEmpty {
                Text(item.alt)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(2)
            }
            HStack(spacing: 10) {
                actionButton(title: "保存原图", icon: "square.and.arrow.down") {
                    saveToAlbum()
                }
                actionButton(title: "复制链接", icon: "link") {
                    UIPasteboard.general.string = item.url.absoluteString
                    flash("图片链接已复制")
                }
                actionButton(title: "分享", icon: "square.and.arrow.up") {
                    share()
                }
            }
        }
        .padding(13)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .environment(\.colorScheme, .dark)
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    private func actionButton(title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.caption.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
    }

    private func loadOriginal(force: Bool) async {
        if image != nil && !force { return }
        loading = true
        failed = false
        let referer = item.frameURL.isEmpty ? fallbackReferer : item.frameURL
        let loaded = await RemoteImageLoader.image(for: item.url, referer: referer)
        if Task.isCancelled { return }
        image = loaded
        failed = loaded == nil
        loading = false
    }

    private func saveToAlbum() {
        guard let image else { return }
        UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
        flash("已提交保存到相册")
    }

    private func share() {
        guard let image else { return }
        let activity = UIActivityViewController(activityItems: [image, item.url], applicationActivities: nil)
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let root = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController {
            var presenter = root
            while let presented = presenter.presentedViewController {
                presenter = presented
            }
            presenter.present(activity, animated: true)
        }
    }

    private func flash(_ text: String) {
        withAnimation { toast = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
            withAnimation { toast = nil }
        }
    }
}

struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.delegate = context.coordinator
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 5
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.bouncesZoom = true
        scrollView.backgroundColor = .clear

        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            imageView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
            imageView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor)
        ])
        context.coordinator.imageView = imageView
        context.coordinator.scrollView = scrollView

        let doubleTap = UITapGestureRecognizer(target: context.coordinator,
                                               action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)
        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.scrollView = scrollView
        if context.coordinator.imageView?.image !== image {
            context.coordinator.imageView?.image = image
            scrollView.setZoomScale(1, animated: false)
        }
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var imageView: UIImageView?
        weak var scrollView: UIScrollView?

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            imageView
        }

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scrollView else { return }
            if scrollView.zoomScale > 1.1 {
                scrollView.setZoomScale(1, animated: true)
                return
            }
            let point = gesture.location(in: imageView)
            let zoom: CGFloat = 3
            let size = CGSize(width: scrollView.bounds.width / zoom,
                              height: scrollView.bounds.height / zoom)
            let rect = CGRect(x: point.x - size.width / 2,
                              y: point.y - size.height / 2,
                              width: size.width,
                              height: size.height)
            scrollView.zoom(to: rect, animated: true)
        }
    }
}
