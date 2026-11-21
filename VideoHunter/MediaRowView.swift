//
//  MediaRowView.swift
//  VideoHunter
//
//  视频列表里的一行，本页列表和整站结果共用：预览图 + 名称 + 分类。
//

import SwiftUI

struct MediaRowView: View {
    let item: MediaItem
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        HStack(spacing: 12) {
            MediaThumbnail(item: item)

            VStack(alignment: .leading, spacing: 5) {
                Text(item.displayName)
                    .font(settings.listDensity.titleFont)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                HStack(spacing: 5) {
                    if settings.showCategoryBadges {
                        Text(item.category.label)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Self.categoryColor(item.category).opacity(0.14), in: Capsule())
                            .foregroundStyle(Self.categoryColor(item.category))
                    }

                    Text(item.kind.label)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)

                    if settings.showHost {
                        Text(item.host)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    if item.isIframe, settings.showIframeBadges {
                        Text("iframe")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.orange.opacity(0.13), in: Capsule())
                            .foregroundStyle(.orange)
                    }
                }
            }

            Spacer(minLength: 4)

            Image(systemName: item.playability == .native ? "play.circle.fill" : "arrow.up.right.circle")
                .font(.system(size: 22))
                .foregroundStyle(item.playability == .native ? Color.accentColor : Color.secondary)
        }
        .padding(.vertical, settings.listDensity.verticalPadding)
        .contentShape(Rectangle())
    }

    static func tint(_ kind: MediaKind) -> Color {
        switch kind {
        case .hls: return .green
        case .mp4: return .blue
        case .dash: return .orange
        case .webm: return .purple
        case .other: return .gray
        }
    }

    static func categoryColor(_ category: MediaCategory) -> Color {
        switch category {
        case .movie: return .indigo
        case .tv: return .blue
        case .anime: return .purple
        case .variety: return .orange
        case .short: return .pink
        case .music: return .teal
        case .other: return .gray
        }
    }
}
