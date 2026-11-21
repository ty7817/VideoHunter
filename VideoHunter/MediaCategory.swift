//
//  MediaCategory.swift
//  VideoHunter
//
//  按链接路径、文件名和页面标题给视频自动归类。
//

import Foundation

enum MediaCategory: String, CaseIterable, Identifiable {
    case movie
    case tv
    case anime
    case variety
    case short
    case music
    case other

    var id: String { rawValue }

    var label: String {
        switch self {
        case .movie: return "电影"
        case .tv: return "剧集"
        case .anime: return "动漫"
        case .variety: return "综艺"
        case .short: return "短视频"
        case .music: return "音乐"
        case .other: return "其他"
        }
    }

    var symbolName: String {
        switch self {
        case .movie: return "film"
        case .tv: return "tv"
        case .anime: return "sparkles"
        case .variety: return "mic"
        case .short: return "bolt"
        case .music: return "music.note"
        case .other: return "square.grid.2x2"
        }
    }
}

enum MediaClassifier {

    private static let rules: [(MediaCategory, [String])] = [
        (.anime, ["动漫", "动画", "番剧", "anime", "cartoon", "国漫", "日漫", "新番"]),
        (.movie, ["电影", "movie", "film", "cinema", "院线", "蓝光", "bluray", "hdmovie"]),
        (.tv, ["电视剧", "连续剧", "剧集", "episode", "series", "season", "tvshow", "美剧", "韩剧", "国产剧"]),
        (.variety, ["综艺", "variety", "脱口秀", "真人秀", "访谈", "talkshow"]),
        (.short, ["短视频", "shorts", "reels", "tiktok", "douyin", "抖音", "快手", "vlog"]),
        (.music, ["音乐", "music", "歌曲", "song", "concert", "演唱会", "mv"])
    ]

    static func category(url: URL, fileName: String, pageTitle: String) -> MediaCategory {
        guard AppSettings.shared.smartClassification else { return .other }
        var pathText = url.path.lowercased()
        if let query = url.query {
            pathText += "?" + query.lowercased()
        }
        pathText += " " + fileName.lowercased()
        let titleText = pageTitle.lowercased()
        let text = pathText + " " + titleText

        var scores: [MediaCategory: Int] = [:]

        // 路径 / 文件名里的关键词权重高；页面标题常常带站名（如“某某电影网”），权重低。
        for (category, words) in rules {
            for word in words {
                if pathText.contains(word) {
                    scores[category, default: 0] += 3
                } else if titleText.contains(word) {
                    scores[category, default: 0] += 1
                }
            }
        }

        // 第 1 集 / 第十二期 这类标题几乎都是剧集或综艺。
        if text.range(of: #"第[0-9一二三四五六七八九十百千]+[集话期]"#, options: .regularExpression) != nil {
            scores[.tv, default: 0] += 4
        }
        if text.range(of: #"s\d{1,2}[._\- ]?e\d{1,2}"#, options: .regularExpression) != nil {
            scores[.tv, default: 0] += 4
        }
        if text.range(of: #"第[0-9一二三四五六七八九十百千]+季"#, options: .regularExpression) != nil {
            scores[.tv, default: 0] += 3
        }

        var best = MediaCategory.other
        var bestScore = 0
        for category in MediaCategory.allCases where category != .other {
            let score = scores[category] ?? 0
            if score > bestScore {
                bestScore = score
                best = category
            }
        }
        return bestScore > 0 ? best : .other
    }

    static func category(for item: MediaItem) -> MediaCategory {
        category(url: item.url, fileName: item.fileName, pageTitle: item.pageTitle)
    }
}

extension MediaItem {
    var category: MediaCategory {
        MediaClassifier.category(for: self)
    }
}
