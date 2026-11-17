//
//  ExportRecordStore.swift
//  WatermarkBatch（水印工坊 BatchMark）
//
//  块B · 导出记录持久化（PRD F-29 / §6.2）
//
//  存储：`Documents/ExportRecords.json`（单文件 JSON 数组，量级 <1MB，不引入数据库）。
//  保留：最近 30 天（PRD F-29），写入时顺带裁剪。
//  并发：ExportService 与 UI 记录页可能同时访问 → NSLock + 原子写。
//

import Foundation

// MARK: - 统计

struct ExportStatistics: Sendable, Equatable {
    let total: Int
    let succeeded: Int
    let failed: Int

    var failureRate: Double {
        total > 0 ? Double(failed) / Double(total) : 0
    }

    static let empty = ExportStatistics(total: 0, succeeded: 0, failed: 0)
}

// MARK: - Store

final class ExportRecordStore: @unchecked Sendable {

    static let shared = ExportRecordStore()

    /// 保留天数（PRD F-29：最近 30 天）。
    static let retentionDays = 30

    private let fileURL: URL
    private let lock = NSLock()
    private var cachedRecords: [ExportRecord]?

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            self.fileURL = documents.appendingPathComponent("ExportRecords.json")
        }
    }

    // MARK: 写入

    /// 追加一批记录（内部裁剪 30 天前的数据后原子落盘）。
    func append(_ records: [ExportRecord]) {
        guard !records.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        var all = loadLocked()
        all.append(contentsOf: records)
        all = pruneLocked(all)
        cachedRecords = all
        persistLocked(all)
    }

    // MARK: 读取

    /// 全部记录（按开始时间倒序）。
    func allRecords() -> [ExportRecord] {
        lock.lock(); defer { lock.unlock() }
        let all = loadLocked()
        return all.sorted { $0.startedAt > $1.startedAt }
    }

    /// 失败记录（按时间倒序），供「失败清单」页。
    func failedRecords() -> [ExportRecord] {
        allRecords().filter { $0.status == .failed }
    }

    /// 汇总统计（记录页顶部卡片）。
    func statistics() -> ExportStatistics {
        let all = allRecords()
        let succeeded = all.filter { $0.status == .succeeded }.count
        let failed = all.filter { $0.status == .failed }.count
        return ExportStatistics(total: all.count, succeeded: succeeded, failed: failed)
    }

    /// 按素材类型统计（记录页筛选用）。
    func countsByKind() -> [MediaKind: Int] {
        var result: [MediaKind: Int] = [:]
        for record in allRecords() {
            result[record.kind, default: 0] += 1
        }
        return result
    }

    // MARK: 清理

    func removeAll() {
        lock.lock(); defer { lock.unlock() }
        cachedRecords = []
        persistLocked([])
    }

    /// 手动裁剪（App 启动时可调一次）。
    func prune(olderThan days: Int = ExportRecordStore.retentionDays) {
        lock.lock(); defer { lock.unlock() }
        let pruned = pruneLocked(loadLocked(), days: days)
        cachedRecords = pruned
        persistLocked(pruned)
    }

    // MARK: 失败清单文本（记录页「导出失败清单」）

    /// 由历史失败记录生成纯文本（与批次内失败清单同格式口径）。
    func failureListText() -> String {
        let failures = failedRecords()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

        var lines: [String] = ["水印工坊 BatchMark · 历史失败记录",
                               "共 \(failures.count) 条（保留最近 \(Self.retentionDays) 天）",
                               String(repeating: "-", count: 56)]
        if failures.isEmpty {
            lines.append("没有失败记录。")
        } else {
            for (index, record) in failures.enumerated() {
                lines.append("\(index + 1). \(record.assetIdentifier)")
                lines.append("   类型：\(kindLabel(record.kind))　　时间：\(formatter.string(from: record.startedAt))")
                lines.append("   原因：\(record.errorDescription ?? "未知")")
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - 私有

    private func loadLocked() -> [ExportRecord] {
        if let cachedRecords { return cachedRecords }
        guard let data = try? Data(contentsOf: fileURL) else {
            cachedRecords = []
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let records = (try? decoder.decode([ExportRecord].self, from: data)) ?? []
        let pruned = pruneLocked(records)
        cachedRecords = pruned
        return pruned
    }

    private func pruneLocked(_ records: [ExportRecord],
                             days: Int = ExportRecordStore.retentionDays) -> [ExportRecord] {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        return records.filter { $0.startedAt >= cutoff }
    }

    private func persistLocked(_ records: [ExportRecord]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(records) else { return }
        // .completeFileProtection：记录含相册标识，属用户数据，锁屏后不可读。
        try? data.write(to: fileURL, options: [.atomic, .completeFileProtection])
    }

    private func kindLabel(_ kind: MediaKind) -> String {
        switch kind {
        case .photo:     return "照片"
        case .livePhoto: return "Live Photo"
        case .animated:  return "动图"
        case .video:     return "视频"
        case .raw:       return "RAW"
        }
    }
}
