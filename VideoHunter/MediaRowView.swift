//
//  MediaRowView.swift
//  VideoHunter
//
//  视频列表里的一行，本页列表和整站结果共用。
//

import SwiftUI

struct MediaRowView: View {
    let item: MediaItem

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.kind.symbolName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Self.tint(item.kind))
                .frame(width: 34, height: 34)
                .background(
                    Self.tint(item.kind).opacity(0.12),
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
                        .background(Self.tint(item.kind).opacity(0.15), in: Capsule())

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
}
