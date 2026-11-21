//
//  DownloadManager.swift
//  VideoHunter
//
//  2.3 新增：MP4 直链离线下载 + 本地媒体库。
//  HLS 由多个分片组成，暂不在这里伪装成“下载成功”；需要先转成单文件 MP4。
//

import Foundation
import Combine
import UIKit

struct DownloadRecord: Identifiable, Codable, Hashable {
    let id: UUID
    let sourceURL: String
    let title: String
    let localFileName: String
    let kindRaw: String
    let referer: String?
    let fileSize: Int64
    let createdAt: Date

    var kind: MediaKind { MediaKind(rawValue: kindRaw) ?? .mp4 }

    var localURL: URL {
        DownloadManager.shared.mediaDirectory.appendingPathComponent(localFileName)
    }

    var mediaItem: MediaItem {
        MediaItem(
            url: localURL,
            kind: kind,
            source: "local",
            pageTitle: title,
            frameURL: nil,
            thumbnailURL: nil,
            isIframe: false
        )
    }

    var sizeText: String {
        ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }

    var host: String {
        URL(string: sourceURL)?.host ?? "本地文件"
    }
}

private struct DownloadJob {
    let key: String
    let sourceURL: String
    let title: String
    let fileName: String
    let kindRaw: String
    let referer: String?
}

final class DownloadManager: NSObject, ObservableObject {

    static let shared = DownloadManager()

    @Published private(set) var records: [DownloadRecord] = []
    @Published private(set) var progress: [String: Double] = [:]
    @Published private(set) var errors: [String: String] = [:]
    @Published private(set) var activeKeys: Set<String> = []

    let mediaDirectory: URL

    private let recordsURL: URL
    private let lock = NSLock()
    private var jobs: [Int: DownloadJob] = [:]
    private var session: URLSession!

    override init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        mediaDirectory = base.appendingPathComponent("VideoHunterMedia", isDirectory: true)
        recordsURL = mediaDirectory.appendingPathComponent("downloads.json")
        super.init()

        try? FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)

        let configuration = URLSessionConfiguration.default
        configuration.httpCookieStorage = HTTPCookieStorage.shared
        configuration.httpShouldSetCookies = true
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 3600
        configuration.waitsForConnectivity = true
        configuration.allowsCellularAccess = true
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)

        loadRecords()
    }

    // MARK: - 对外操作

    func isDownloading(_ item: MediaItem) -> Bool {
        activeKeys.contains(item.key)
    }

    func hasRecord(for item: MediaItem) -> Bool {
        records.contains { $0.sourceURL == item.key }
    }

    func progress(for item: MediaItem) -> Double? {
        progress[item.key]
    }

    func error(for item: MediaItem) -> String? {
        errors[item.key]
    }

    func start(item: MediaItem, referer: String?, title: String? = nil) {
        let key = item.key
        guard item.kind == .mp4 else {
            errors[key] = "离线下载目前只支持单文件 MP4。HLS/DASH/WebM 需要先转成 MP4。"
            return
        }
        guard let scheme = item.url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            errors[key] = "这个地址不是可下载的 HTTP(S) 文件。"
            return
        }
        guard !activeKeys.contains(key), !hasRecord(for: item) else { return }

        var request = URLRequest(url: item.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        request.setValue(BrowserController.mobileUserAgentString, forHTTPHeaderField: "User-Agent")
        request.setValue("video/mp4,video/*;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        if let referer, !referer.isEmpty {
            request.setValue(referer, forHTTPHeaderField: "Referer")
        }

        let fileName = Self.uniqueFileName(for: item.url)
        let task = session.downloadTask(with: request)
        let job = DownloadJob(
            key: key,
            sourceURL: key,
            title: title ?? item.fileName,
            fileName: fileName,
            kindRaw: item.kind.rawValue,
            referer: referer
        )

        lock.lock()
        jobs[task.taskIdentifier] = job
        lock.unlock()

        task.taskDescription = key
        activeKeys.insert(key)
        progress[key] = 0
        errors[key] = nil
        task.resume()
    }

    func cancel(item: MediaItem) {
        let key = item.key
        session.getAllTasks { tasks in
            tasks.first(where: { $0.taskDescription == key })?.cancel()
        }
    }

    func remove(_ record: DownloadRecord) {
        try? FileManager.default.removeItem(at: record.localURL)
        records.removeAll { $0.id == record.id }
        saveRecords()
    }

    func clearAll() {
        for record in records {
            try? FileManager.default.removeItem(at: record.localURL)
        }
        records.removeAll()
        saveRecords()
    }

    // MARK: - 任务完成后的文件落盘

    private func job(for identifier: Int) -> DownloadJob? {
        lock.lock()
        defer { lock.unlock() }
        return jobs[identifier]
    }

    private func finishJob(_ identifier: Int) {
        lock.lock()
        jobs.removeValue(forKey: identifier)
        lock.unlock()
    }

    private func persist(record: DownloadRecord, key: String) {
        if !records.contains(where: { $0.sourceURL == record.sourceURL }) {
            records.insert(record, at: 0)
            saveRecords()
        }
        progress[key] = 1
        activeKeys.remove(key)
    }

    private func loadRecords() {
        guard let data = try? Data(contentsOf: recordsURL),
              let decoded = try? JSONDecoder().decode([DownloadRecord].self, from: data) else {
            return
        }
        records = decoded
            .filter { FileManager.default.fileExists(atPath: mediaDirectory.appendingPathComponent($0.localFileName).path) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    private func saveRecords() {
        do {
            let data = try JSONEncoder().encode(records)
            try data.write(to: recordsURL, options: .atomic)
        } catch {
            // 元数据写入失败不应影响已经下载完成的文件本身。
        }
    }

    private static func uniqueFileName(for url: URL) -> String {
        let rawName = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
        let stem = (rawName as NSString).deletingPathExtension
        let ext = url.pathExtension.isEmpty ? "mp4" : url.pathExtension
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let cleaned = stem.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "_" }.prefix(48)
        let base = cleaned.isEmpty ? "video" : String(cleaned)
        return "\(UUID().uuidString.prefix(8))-\(base).\(ext.lowercased())"
    }
}

// MARK: - URLSessionDownloadDelegate

extension DownloadManager: URLSessionDownloadDelegate {

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let job = job(for: downloadTask.taskIdentifier) else { return }
        let value = totalBytesExpectedToWrite > 0
            ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            : 0
        DispatchQueue.main.async {
            self.progress[job.key] = min(0.99, max(0, value))
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let job = job(for: downloadTask.taskIdentifier) else { return }
        let destination = mediaDirectory.appendingPathComponent(job.fileName)
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: location, to: destination)
            let attributes = try? FileManager.default.attributesOfItem(atPath: destination.path)
            let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
            let record = DownloadRecord(
                id: UUID(),
                sourceURL: job.sourceURL,
                title: job.title,
                localFileName: job.fileName,
                kindRaw: job.kindRaw,
                referer: job.referer,
                fileSize: size,
                createdAt: Date()
            )
            DispatchQueue.main.async {
                self.persist(record: record, key: job.key)
            }
        } catch {
            DispatchQueue.main.async {
                self.errors[job.key] = "保存文件失败：\(error.localizedDescription)"
                self.activeKeys.remove(job.key)
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let job = job(for: task.taskIdentifier) else { return }
        finishJob(task.taskIdentifier)
        if let error {
            let nsError = error as NSError
            if nsError.code == NSURLErrorCancelled {
                DispatchQueue.main.async {
                    self.errors[job.key] = "下载已取消"
                    self.activeKeys.remove(job.key)
                }
            } else {
                DispatchQueue.main.async {
                    self.errors[job.key] = "下载失败：\(nsError.localizedDescription)"
                    self.activeKeys.remove(job.key)
                }
            }
        } else {
            DispatchQueue.main.async {
                if self.progress[job.key] != nil {
                    self.progress[job.key] = 1
                }
                self.activeKeys.remove(job.key)
            }
        }
    }
}
