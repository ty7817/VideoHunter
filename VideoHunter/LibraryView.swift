//
//  LibraryView.swift
//  VideoHunter
//
//  2.3 新增：离线下载库。只展示已经完整落盘的本地 MP4，点击即可离线播放。
//

import SwiftUI

struct LibraryView: View {
    @ObservedObject var downloads: DownloadManager
    @Environment(\.dismiss) private var dismiss
    @State private var playing: DownloadRecord?

    init(downloads: DownloadManager = .shared) {
        self.downloads = downloads
    }

    var body: some View {
        NavigationStack {
            Group {
                if downloads.records.isEmpty {
                    VStack(spacing: 14) {
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 44, weight: .light))
                            .foregroundStyle(.secondary)
                        Text("还没有离线视频")
                            .font(.headline)
                        Text("在视频列表里左滑 MP4，选择“下载”，完成后会出现在这里。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(downloads.records) { record in
                            Button {
                                playing = record
                            } label: {
                                HStack(spacing: 12) {
                                    MediaThumbnail(item: record.mediaItem, width: 78, height: 52)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(record.title)
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundStyle(.primary)
                                            .lineLimit(2)
                                        Text("\(record.host) · \(record.sizeText)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                        Text(record.createdAt.formatted(date: .abbreviated, time: .shortened))
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                    }
                                    Spacer(minLength: 4)
                                    Image(systemName: "play.circle.fill")
                                        .font(.title2)
                                        .foregroundStyle(.tint)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    downloads.remove(record)
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("离线媒体库")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
                if !downloads.records.isEmpty {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Menu {
                            Button(role: .destructive) {
                                downloads.clearAll()
                            } label: {
                                Label("清空下载库", systemImage: "trash")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
            }
            .fullScreenCover(item: $playing) { record in
                PlayerScreen(
                    item: record.mediaItem,
                    referer: record.referer,
                    playlist: downloads.records.map(\.mediaItem)
                )
            }
        }
    }
}
