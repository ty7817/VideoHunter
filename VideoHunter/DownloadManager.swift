//
//  DownloadManager.swift
//  VideoHunter
//
//  2.3 新增：MP4 直链离线下载 + 本地媒体库。
//  2.4：改用 background URLSession，App 进入后台后下载继续；
//  任务元数据持久化到 downloads-jobs.json，App 被系统回收后也能恢复进度/落盘。
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

private struct DownloadJob: Codable {
    let key: String
    let sourceURL: String
    let title: String
    let fileName: String
    let kindRaw: String
    let referer: String?
}

final class DownloadManager: NSObject, ObservableObject {

    static let shared = DownloadManager()
    static let backgroundSessionIdentifier = "com.example.videohunter.downloads"

    @Published private(set) var records: [DownloadRecord] = []
    @Published private(set) var progress: [String: Double] = [:]
    @Published private(set) var errors: [String: String] = [:]
    @Published private(set) var activeKeys: Set<String> = []

    let mediaDirectory: URL

    private let recordsURL: URL
    private let jobsURL: URL
    private let lock = NSLock()
    private var jobs: [String: DownloadJob] = [:]
    private var session: URLSession!
    private var backgroundCompletionHandler: (() -> Void)?

    override init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        mediaDirectory = base.appendingPathComponent("VideoHunterMedia", isDirectory: true)
        recordsURL = mediaDirectory.appendingPathComponent("downloads.json")
        jobsURL = mediaDirectory.appendingPathComponent("downloads-jobs.json")
        super.init()

        try? FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)

        // background session：App 退到后台甚至被系统回收后，系统会继续下载并在事件到达时唤醒 App。
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.backgroundSessionIdentifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.httpCookieStorage = HTTPCookieStorage.shared
        configuration.httpShouldSetCookies = true
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 86_400
        configuration.waitsForConnectivity = true
        configuration.allowsCellularAccess = true
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)

        loadJobs()
        loadRecords()
        removeJobsForCompletedRecords()

        activeKeys = Set(jobs.keys)
        refreshActiveTasks()
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
        request.allowsCellularAccess = AppSettings.shared.allowCellularDownloads
        request.setValue(BrowserController.mobileUserAgentString, forHTTPHeaderField: "User-Agent")
        request.setValue("video/mp4,video/*;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        if let referer, !referer.isEmpty {
            request.setValue(referer, forHTTPHeaderField: "Referer")
            if let refererURL = URL(string: referer),
               let scheme = refererURL.scheme,
               let host = refererURL.host {
                request.setValue("\(scheme)://\(host)", forHTTPHeaderField: "Origin")
            }
        }
        // background session 下显式带 Cookie，避免部分站点依赖 Cookie 鉴权时 403。
        if let cookies = HTTPCookieStorage.shared.cookies(for: item.url), !cookies.isEmpty {
            let fields = HTTPCookie.requestHeaderFields(with: cookies)
            if let cookie = fields["Cookie"] {
                request.setValue(cookie, forHTTPHeaderField: "Cookie")
            }
        }

        let fileName = Self.uniqueFileName(for: item.url)
        let job = DownloadJob(
            key: key,
            sourceURL: key,
            title: title ?? item.fileName,
            fileName: fileName,
            kindRaw: item.kind.rawValue,
            referer: referer
        )

        let task = session.downloadTask(with: request)
        task.taskDescription = key

        lock.lock()
        jobs[key] = job
        let snapshot = Array(jobs.values)
        lock.unlock()
        saveJobs(snapshot)

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

    func setBackgroundSessionCompletionHandler(_ handler: @escaping () -> Void) {
        backgroundCompletionHandler = handler
    }

    // MARK: - 任务元数据

    private func job(for task: URLSessionTask) -> DownloadJob? {
        guard let key = task.taskDescription else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return jobs[key]
    }

    /// 系统在 App 被回收后重派任务时，内存里的 jobs 可能已经丢失；
    /// 这里用 taskDescription + 原始请求重建一条最小任务，保证文件仍能落盘。
    private func resolveJob(for task: URLSessionTask) -> DownloadJob? {
        if let job = job(for: task) { return job }
        guard let key = task.taskDescription, let url = task.originalRequest?.url else { return nil }

        let job = DownloadJob(
            key: key,
            sourceURL: key,
            title: url.lastPathComponent.isEmpty ? "离线视频" : url.lastPathComponent,
            fileName: Self.uniqueFileName(for: url),
            kindRaw: MediaKind.mp4.rawValue,
            referer: nil
        )

        lock.lock()
        jobs[key] = job
        let snapshot = Array(jobs.values)
        lock.unlock()
        saveJobs(snapshot)
        return job
    }

    private func finishJob(_ key: String) {
        lock.lock()
        jobs.removeValue(forKey: key)
        let snapshot = Array(jobs.values)
        lock.unlock()
        saveJobs(snapshot)
    }

    private func saveJobs(_ snapshot: [DownloadJob]) {
        do {
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: jobsURL, options: .atomic)
        } catch {
            // 元数据写入失败不应影响系统后台任务本身。
        }
    }

    private func loadJobs() {
        guard let data = try? Data(contentsOf: jobsURL),
              let decoded = try? JSONDecoder().decode([DownloadJob].self, from: data) else {
            return
        }
        var loaded: [String: DownloadJob] = [:]
        for job in decoded {
            loaded[job.key] = job
        }
        jobs = loaded
    }

    private func removeJobsForCompletedRecords() {
        let completed = Set(records.map { $0.sourceURL })
        let remaining = jobs.values.filter { !completed.contains($0.sourceURL) }
        if remaining.count != jobs.count {
            jobs = Dictionary(uniqueKeysWithValues: remaining.map { ($0.key, $0) })
            saveJobs(Array(jobs.values))
        }
    }

    private func refreshActiveTasks() {
        session.getAllTasks { [weak self] tasks in
            guard let self else { return }
            let keys = Set(tasks.compactMap { $0.taskDescription })
            DispatchQueue.main.async {
                self.activeKeys = keys
            }
        }
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
        guard let job = resolveJob(for: downloadTask) else { return }
        let value = totalBytesExpectedToWrite > 0
            ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            : 0
        DispatchQueue.main.async {
            self.progress[job.key] = min(0.99, max(0, value))
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let job = resolveJob(for: downloadTask) else { return }
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
        guard let key = task.taskDescription else { return }
        _ = resolveJob(for: task)
        finishJob(key)

        if let error {
            let nsError = error as NSError
            DispatchQueue.main.async {
                if nsError.code == NSURLErrorCancelled {
                    self.errors[key] = "下载已取消"
                } else {
                    self.errors[key] = "下载失败：\(nsError.localizedDescription)"
                }
                self.activeKeys.remove(key)
            }
        } else {
            DispatchQueue.main.async {
                if self.progress[key] != nil {
                    self.progress[key] = 1
                }
                self.activeKeys.remove(key)
            }
        }

        // 如果是后台会话，系统会在所有事件处理完之后回调 urlSessionDidFinishEvents。
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async {
            let handler = self.backgroundCompletionHandler
            self.backgroundCompletionHandler = nil
            handler?()
        }
    }
}
