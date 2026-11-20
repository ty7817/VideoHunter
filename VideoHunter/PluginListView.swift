//
//  PluginListView.swift
//  VideoHunter
//
//  插件管理界面：启用、排序、删除、新建和编辑用户脚本。
//

import SwiftUI
import UIKit

struct PluginListView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = PluginStore.shared

    @State private var editing: UserPlugin?
    @State private var isNew = false
    @State private var showIntro = true

    var body: some View {
        NavigationView {
            List {
                if showIntro {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("插件是什么", systemImage: "puzzlepiece.extension.fill")
                                .font(.subheadline.weight(.semibold))
                            Text("插件就是一段 JS 脚本。填入网址正则，命中后脚本会在网页里执行，可以解锁播放限制、补上懒加载视频，或调用 __vhRescan() 让 App 重新嗅探。")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            HStack(spacing: 8) {
                                Button("知道了") {
                                    withAnimation { showIntro = false }
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)

                                Button("看示例") {
                                    addTemplate()
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                            .padding(.top, 2)
                        }
                        .padding(.vertical, 4)
                    }
                }

                Section {
                    if store.plugins.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "puzzlepiece")
                                .font(.title2)
                                .foregroundStyle(.secondary)
                            Text("还没有插件")
                                .font(.footnote.weight(.medium))
                            Text("点右上角 + 新建，或直接用下面的模板。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 18)
                    }

                    ForEach(store.plugins) { plugin in
                        PluginRowView(plugin: plugin)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                isNew = false
                                editing = plugin
                            }
                            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                Button {
                                    store.toggle(plugin.id)
                                } label: {
                                    Label(plugin.enabled ? "停用" : "启用", systemImage: plugin.enabled ? "pause.circle" : "play.circle")
                                }
                                .tint(plugin.enabled ? .orange : .green)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    store.delete(plugin.id)
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                            .contextMenu {
                                Button {
                                    store.toggle(plugin.id)
                                } label: {
                                    Label(plugin.enabled ? "停用" : "启用", systemImage: plugin.enabled ? "pause.circle" : "play.circle")
                                }
                                Button {
                                    isNew = false
                                    editing = plugin
                                } label: {
                                    Label("编辑", systemImage: "pencil")
                                }
                                Button {
                                    duplicate(plugin)
                                } label: {
                                    Label("复制一份", systemImage: "doc.on.doc")
                                }
                                Button(role: .destructive) {
                                    store.delete(plugin.id)
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                    }
                    .onDelete { offsets in
                        store.delete(at: offsets)
                    }
                    .onMove { source, destination in
                        store.move(from: source, to: destination)
                    }
                } header: {
                    Text("已安装 \(store.plugins.count) 个 · 启用 \(store.enabledPlugins.count) 个")
                }

                Section("模板") {
                    templateRow(
                        title: "视频页增强",
                        subtitle: "自动静音播放、清掉遮罩，并触发重新嗅探",
                        icon: "play.rectangle.fill",
                        color: .blue,
                        name: "视频页增强",
                        pattern: "https?://.*",
                        start: false,
                        code: PluginStore.sampleCode()
                    )

                    templateRow(
                        title: "懒加载触发",
                        subtitle: "反复滚动页面，把滚动后才出现的视频逼出来",
                        icon: "arrow.down.circle.fill",
                        color: .orange,
                        name: "懒加载触发",
                        pattern: "https?://.*",
                        start: false,
                        code: """
                        (function () {
                          var body = document.body;
                          if (!body) { return; }
                          var round = 0;
                          var timer = setInterval(function () {
                            window.scrollBy(0, window.innerHeight * 0.9);
                            round++;
                            if (window.__vhRescan) { try { window.__vhRescan(); } catch (e) {} }
                            if (round >= 12 || window.scrollY + window.innerHeight >= body.scrollHeight - 4) {
                              clearInterval(timer);
                              window.scrollTo(0, 0);
                            }
                          }, 600);
                        })();
                        """
                    )

                    templateRow(
                        title: "记录直链请求",
                        subtitle: "打印页面里所有 m3u8 / mp4 请求，方便排查",
                        icon: "text.magnifyingglass",
                        color: .purple,
                        name: "记录直链请求",
                        pattern: "https?://.*",
                        start: true,
                        code: """
                        (function () {
                          function hit(url) {
                            if (!url) { return; }
                            var text = String(url);
                            if (text.indexOf('.m3u8') < 0 && text.indexOf('.mp4') < 0) { return; }
                            console.log('[VideoHunter] media request: ' + text);
                          }
                          var open = XMLHttpRequest.prototype.open;
                          XMLHttpRequest.prototype.open = function (method, url) {
                            try { hit(url); } catch (e) {}
                            return open.apply(this, arguments);
                          };
                          if (window.fetch) {
                            var rawFetch = window.fetch;
                            window.fetch = function (input) {
                              try { hit(typeof input === 'string' ? input : (input && input.url)); } catch (e) {}
                              return rawFetch.apply(this, arguments);
                            };
                          }
                        })();
                        """
                    )
                }

                Section {
                    Text("插件只在本机运行，不会上传。脚本由你自己填写，请只安装可信来源的代码。改动插件后当前页面会自动刷新。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("插件管理")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    EditButton()
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        isNew = true
                        editing = UserPlugin()
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(item: $editing) { plugin in
                PluginEditorView(plugin: plugin, isNew: isNew)
            }
        }
    }

    private func templateRow(
        title: String,
        subtitle: String,
        icon: String,
        color: Color,
        name: String,
        pattern: String,
        start: Bool,
        code: String
    ) -> some View {
        Button {
            let plugin = UserPlugin(
                name: name,
                matchPattern: pattern,
                runAtDocumentStart: start,
                code: code
            )
            store.add(plugin)
            isNew = false
            editing = plugin
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(color)
                    .frame(width: 30, height: 30)
                    .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer()

                Image(systemName: "plus.circle")
                    .foregroundStyle(.tint)
            }
            .padding(.vertical, 2)
        }
    }

    private func duplicate(_ plugin: UserPlugin) {
        var copy = plugin
        copy.id = UUID()
        copy.name = plugin.name + " 副本"
        copy.createdAt = Date()
        store.add(copy)
    }

    private func addTemplate() {
        let plugin = UserPlugin(
            name: "视频页增强",
            matchPattern: "https?://.*",
            runAtDocumentStart: false,
            code: PluginStore.sampleCode()
        )
        store.add(plugin)
        isNew = false
        editing = plugin
    }
}

// MARK: - 列表行

struct PluginRowView: View {
    let plugin: UserPlugin

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(plugin.enabled ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.12))
                Image(systemName: plugin.enabled ? "puzzlepiece.extension.fill" : "puzzlepiece.extension")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(plugin.enabled ? Color.accentColor : Color.secondary)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(plugin.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    if !plugin.enabled {
                        Text("已停用")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.15), in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                }

                Text(plugin.matchPattern)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                HStack(spacing: 8) {
                    Label(plugin.stageLabel, systemImage: plugin.runAtDocumentStart ? "bolt.fill" : "doc.text")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                    Label("\(plugin.code.count) 字符", systemImage: "curlybraces")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                    if !plugin.patternIsValid {
                        Label("正则无效", systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.red)
                    }
                }
            }

            Spacer(minLength: 4)

            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 3)
    }
}

// MARK: - 编辑器

struct PluginEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = PluginStore.shared

    @State private var plugin: UserPlugin
    private let isNew: Bool

    init(plugin: UserPlugin, isNew: Bool) {
        _plugin = State(initialValue: plugin)
        self.isNew = isNew
    }

    private var trimmedName: String {
        plugin.name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool {
        !trimmedName.isEmpty && plugin.patternIsValid && !plugin.code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationView {
            Form {
                Section("基本信息") {
                    TextField("插件名称", text: $plugin.name)

                    VStack(alignment: .leading, spacing: 4) {
                        TextField("匹配网址正则，例如 https?://.*example\\.com", text: $plugin.matchPattern)
                            .font(.system(.footnote, design: .monospaced))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)

                        if plugin.patternIsValid {
                            Text("正则有效，命中时注入")
                                .font(.caption2)
                                .foregroundStyle(.green)
                        } else {
                            Text("正则无效，插件不会执行")
                                .font(.caption2)
                                .foregroundStyle(.red)
                        }
                    }

                    Toggle("页面开始就注入（documentStart）", isOn: $plugin.runAtDocumentStart)
                    Toggle("启用这个插件", isOn: $plugin.enabled)
                }

                Section {
                    TextEditor(text: $plugin.code)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(minHeight: 260)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                } header: {
                    Text("脚本内容")
                } footer: {
                    Text("脚本会在每个匹配的 frame 里执行。可用 window.__vhRescan() 主动触发重新嗅探，用 console.log 输出调试信息（需连接 Safari 检查器）。")
                }

                Section {
                    Button {
                        plugin.code = PluginStore.sampleCode()
                    } label: {
                        Label("填入示例脚本", systemImage: "sparkles")
                    }
                    Button {
                        plugin.matchPattern = "https?://.*"
                    } label: {
                        Label("匹配所有网站", systemImage: "globe")
                    }
                }

                Section {
                    HStack {
                        Text("字符数")
                        Spacer()
                        Text("\(plugin.code.count)")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(isNew ? "新建插件" : "编辑插件")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(!canSave)
                }
            }
        }
    }

    private func save() {
        var value = plugin
        value.name = trimmedName
        if isNew {
            store.add(value)
        } else {
            store.update(value)
        }
        dismiss()
    }
}
