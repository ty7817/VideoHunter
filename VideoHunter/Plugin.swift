//
//  Plugin.swift
//  VideoHunter
//
//  用户脚本插件：按网址正则匹配，在网页里注入自定义 JS。
//  插件保存在 UserDefaults，随 App 启动加载。
//

import Foundation
import WebKit
import Combine
import SwiftUI

extension Notification.Name {
    static let vhPluginsChanged = Notification.Name("vhPluginsChanged")
}

struct UserPlugin: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var matchPattern: String
    var runAtDocumentStart: Bool
    var code: String
    var enabled: Bool
    var createdAt: Date

    init(
        id: UUID = UUID(),
        name: String = "新插件",
        matchPattern: String = "https?://.*",
        runAtDocumentStart: Bool = true,
        code: String = "",
        enabled: Bool = true,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.matchPattern = matchPattern
        self.runAtDocumentStart = runAtDocumentStart
        self.code = code
        self.enabled = enabled
        self.createdAt = createdAt
    }

    var patternIsValid: Bool {
        (try? NSRegularExpression(pattern: matchPattern)) != nil
    }

    var stageLabel: String {
        runAtDocumentStart ? "页面开始" : "DOM 就绪"
    }

    func makeUserScript() -> WKUserScript? {
        guard enabled, patternIsValid, !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return WKUserScript(
            source: Self.wrappedSource(name: name, pattern: matchPattern, code: code),
            injectionTime: runAtDocumentStart ? .atDocumentStart : .atDocumentEnd,
            forMainFrameOnly: false
        )
    }

    static func wrappedSource(name: String, pattern: String, code: String) -> String {
        let patternLiteral = jsString(pattern)
        let nameLiteral = jsString(name)
        return """
        (function () {
          try {
            var __vhPluginPattern = new RegExp(\(patternLiteral));
            if (!__vhPluginPattern.test(String(location.href))) { return; }
          } catch (e) { return; }
          try {
        \(code)
          } catch (e) {
            console.warn('[VideoHunter] plugin ' + \(nameLiteral) + ' error: ' + e);
          }
        })();
        """
    }

    private static func jsString(_ text: String) -> String {
        var result = "\""
        for character in text {
            switch character {
            case "\\": result += "\\\\"
            case "\"": result += "\\\""
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            default: result.append(character)
            }
        }
        return result + "\""
    }
}

final class PluginStore: ObservableObject {

    static let shared = PluginStore()

    @Published private(set) var plugins: [UserPlugin] = []

    private let storageKey = "vh.user.plugins.v1"

    init() {
        load()
    }

    var enabledPlugins: [UserPlugin] {
        plugins.filter { $0.enabled && $0.patternIsValid && !$0.code.isEmpty }
    }

    func userScripts() -> [WKUserScript] {
        enabledPlugins.compactMap { $0.makeUserScript() }
    }

    func add(_ plugin: UserPlugin) {
        plugins.append(plugin)
        persist()
    }

    func update(_ plugin: UserPlugin) {
        guard let index = plugins.firstIndex(where: { $0.id == plugin.id }) else { return }
        plugins[index] = plugin
        persist()
    }

    func delete(_ id: UUID) {
        plugins.removeAll { $0.id == id }
        persist()
    }

    func delete(at offsets: IndexSet) {
        plugins.remove(atOffsets: offsets)
        persist()
    }

    func move(from source: IndexSet, to destination: Int) {
        plugins.move(fromOffsets: source, toOffset: destination)
        persist()
    }

    func toggle(_ id: UUID) {
        guard let index = plugins.firstIndex(where: { $0.id == id }) else { return }
        plugins[index].enabled.toggle()
        persist()
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(plugins)
            UserDefaults.standard.set(data, forKey: storageKey)
        } catch {
            // 保存失败时保持内存里的列表，下次修改再试。
        }
        NotificationCenter.default.post(name: .vhPluginsChanged, object: nil)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let list = try? JSONDecoder().decode([UserPlugin].self, from: data) else {
            return
        }
        plugins = list
    }

    static func sampleCode() -> String {
        """
        // 在这里写你的 JS，页面加载时会执行。
        // 可用 window.__vhRescan() 让 App 再扫一遍页面里的媒体。
        console.log('[VideoHunter] plugin running on', location.href);

        setTimeout(function () {
          try { window.__vhRescan && window.__vhRescan(); } catch (e) {}
        }, 1500);
        """
    }
}
