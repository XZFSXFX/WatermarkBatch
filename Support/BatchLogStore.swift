//
//  BatchLogStore.swift
//  WatermarkBatch（水印工坊 BatchMark）
//
//  块B · 批量日志落盘（Documents/Logs/）+ 单任务结构化记录
//
//  依据 PRD §6.2：数据实体全部本地存储；失败清单可导出为纯文本供用户反馈附日志。
//  日志为「人可读 + 可 grep」的纯文本行格式，不引入数据库（反过度设计）。
//
//  并发：BatchQueue 的多个任务并发写同一条日志，故 writer 内部串行化（NSLock + FileHandle）。
//  体量：一批 500 个任务约 500 行 × 200B ≈ 100KB，无需轮转；仅按天数清理旧日志。
//

import Foundation

// MARK: - 单任务记录

/// 单任务的结构化记录（日志、失败清单、导出记录页共用）。
struct BatchTaskRecord: Sendable, Equatable {
    let taskID: UUID
    let assetIdentifier: String
    let filename: String?
    let kind: MediaKind
    let status: TaskStatus
    /// 四阶段耗时。
    let stageSnapshot: StageSnapshot
    let errorDescription: String?
    let startedAt: Date
    let finishedAt: Date?

    var totalDuration: TimeInterval {
        stageSnapshot.totalDuration
    }
}

// MARK: - 失败项

/// 失败清单条目（UI 勾选重试 + 纯文本导出的最小单位）。
struct BatchFailureItem: Sendable, Equatable {
    let taskID: UUID
    let assetIdentifier: String
    let filename: String?
    let kind: MediaKind
    /// 失败时所在阶段（读取/渲染/编码/写入；无法判定时为 nil）。
    let stage: ProcessStage?
    /// 结构化错误（保留「可重试」语义：iCloud 下载失败可重试）。
    let error: WatermarkError
    /// 用户可读原因（来自 WatermarkError.userReadableDescription）。
    let reason: String
    let occurredAt: Date
}

// MARK: - 日志 Store

/// 批量日志仓库：每批一个 `.log` 文件，落在 App 沙盒 `Documents/Logs/`。
final class BatchLogStore: @unchecked Sendable {

    static let shared = BatchLogStore()

    /// 日志目录（不存在则创建）。
    static var logsDirectory: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("Logs", isDirectory: true)
    }

    private let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? Self.logsDirectory
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    /// 开启一批日志。
    func beginBatch(label: String, totalCount: Int) -> BatchLogWriter {
        let writer = BatchLogWriter(directory: directory, label: label, totalCount: totalCount)
        return writer
    }

    /// 全部日志文件（按修改时间倒序，供「导出日志」列出）。
    func logFiles() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return files
            .filter { $0.pathExtension == "log" }
            .sorted { lhs, rhs in
                let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return l > r
            }
    }

    /// 最新一份日志（一键导出用）。
    func latestLogFile() -> URL? { logFiles().first }

    /// 清理 N 天前的日志（PRD F-29：记录保留最近 30 天）。
    func purgeLogs(olderThan days: Int = 30) {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        for file in logFiles() {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if modified < cutoff {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }
}

// MARK: - 单批日志写入器

/// 一批日志的写入句柄。`line` 可从任意线程调用。
final class BatchLogWriter: @unchecked Sendable {

    let batchID = UUID()
    let fileURL: URL

    private let lock = NSLock()
    private let handle: FileHandle?
    private let startedAt = Date()
    private var records: [BatchTaskRecord] = []
    private var closed = false

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    init(directory: URL, label: String, totalCount: Int) {
        let stamp = Self.fileStampFormatter.string(from: Date())
        let name = "batch-\(stamp)-\(UUID().uuidString.prefix(8)).log"
        let url = directory.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        self.fileURL = url
        self.handle = try? FileHandle(forWritingTo: url)

        line("=== 水印工坊 BatchMark 批处理日志 ===")
        line("批次: \(label) | 任务数: \(totalCount) | 版本参数档: 见 settings 行")
        line("设备: \(Self.deviceDescription)")
        line("内存: 物理 \(ProcessInfo.processInfo.physicalMemory / 1024 / 1024)MB")
    }

    deinit {
        close()
    }

    // MARK: 写入

    /// 原始行（自动加时间戳）。
    func line(_ text: String) {
        write("\(Self.timestampFormatter.string(from: Date())) | \(text)")
    }

    /// 记录单任务结果（同时进结构化数组，供 UI 失败清单直接复用，免二读文件）。
    func record(_ record: BatchTaskRecord) {
        lock.lock()
        records.append(record)
        lock.unlock()

        let status = record.status.rawValue
        let errorPart = record.errorDescription.map { " | 原因: \($0)" } ?? ""
        line("任务 \(record.assetIdentifier) [\(record.kind.rawValue)] \(record.filename ?? "-")"
             + " → \(status) | 耗时 \(String(format: "%.2f", record.totalDuration))s"
             + " | \(record.stageSnapshot.compactDescription)\(errorPart)")
    }

    /// 批次收尾。
    func finish(succeeded: Int, failed: Int, cancelled: Int) {
        line("=== 批次结束：成功 \(succeeded) / 失败 \(failed) / 取消 \(cancelled) ===")
        line("端到端耗时 \(String(format: "%.2f", Date().timeIntervalSince(startedAt)))s")
        close()
    }

    /// 已写入的结构化记录快照。
    func snapshotRecords() -> [BatchTaskRecord] {
        lock.lock(); defer { lock.unlock() }
        return records
    }

    /// 关闭文件句柄（幂等）。
    func close() {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        try? handle?.close()
    }

    // MARK: 私有

    private func write(_ text: String) {
        guard let data = (text + "\n").data(using: .utf8) else { return }
        lock.lock(); defer { lock.unlock() }
        guard !closed, let handle else { return }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            // 日志写失败绝不能影响主流程（磁盘满/权限异常时静默降级为「无日志」）
        }
    }

    private static let fileStampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    private static var deviceDescription: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let machine = withUnsafeBytes(of: &systemInfo.machine) { raw -> String in
            let bytes = raw.prefix(while: { $0 != 0 })
            return String(decoding: bytes, as: UTF8.self)
        }
        return "\(machine) / iOS \(ProcessInfo.processInfo.operatingSystemVersionString)"
    }
}
