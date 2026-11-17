//
//  FailureListExporter.swift
//  WatermarkBatch（水印工坊 BatchMark）
//
//  块B · 失败清单纯文本导出（PRD F-29 / §6.2：失败清单可导出为文本，供用户反馈附日志）
//
//  输出内容：批次头（时间/总数/成败计数）+ 每条「文件名 + 类型 + 阶段 + 原因」+ 阶段耗时。
//  落点：Documents/Exports/失败清单-<时间戳>.txt，URL 可直接交给 UIActivityViewController。
//

import Foundation

enum FailureListExporter {

    /// 导出目录（不存在则创建）。
    static var exportsDirectory: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("Exports", isDirectory: true)
    }

    /// 生成纯文本（不落盘，便于预览）。
    static func text(failures: [BatchFailureItem],
                     batchLabel: String,
                     totalCount: Int,
                     succeededCount: Int,
                     startedAt: Date? = nil,
                     logFileURL: URL? = nil) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

        var lines: [String] = []
        lines.append("水印工坊 BatchMark · 失败清单")
        lines.append("批次：\(batchLabel)")
        if let startedAt {
            lines.append("开始时间：\(formatter.string(from: startedAt))")
        }
        lines.append("总数：\(totalCount)　成功：\(succeededCount)　失败：\(failures.count)")
        lines.append(String(repeating: "-", count: 56))

        if failures.isEmpty {
            lines.append("本批次没有失败项。")
        } else {
            for (index, item) in failures.enumerated() {
                let name = item.filename ?? item.assetIdentifier
                let stage = item.stage?.label ?? "未定位"
                lines.append("\(index + 1). \(name)")
                lines.append("   类型：\(kindLabel(item.kind))　　阶段：\(stage)")
                lines.append("   原因：\(item.reason)")
                lines.append("   时间：\(formatter.string(from: item.occurredAt))")
            }
        }

        lines.append(String(repeating: "-", count: 56))
        if let logFileURL {
            lines.append("完整日志：\(logFileURL.lastPathComponent)（已保存在 App 沙盒 Documents/Logs/）")
        }
        lines.append("提示：失败项可在批量任务页勾选后单独重试，重试不会重复处理已成功的素材。")
        return lines.joined(separator: "\n")
    }

    /// 落盘为 .txt，返回 URL（供分享/导出）。
    @discardableResult
    static func write(failures: [BatchFailureItem],
                      batchLabel: String,
                      totalCount: Int,
                      succeededCount: Int,
                      startedAt: Date? = nil,
                      logFileURL: URL? = nil) throws -> URL {
        let body = text(failures: failures,
                        batchLabel: batchLabel,
                        totalCount: totalCount,
                        succeededCount: succeededCount,
                        startedAt: startedAt,
                        logFileURL: logFileURL)
        let directory = exportsDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stampFormatter = DateFormatter()
        stampFormatter.locale = Locale(identifier: "en_US_POSIX")
        stampFormatter.dateFormat = "yyyyMMdd-HHmmss"
        let url = directory.appendingPathComponent("失败清单-\(stampFormatter.string(from: Date())).txt")
        try body.data(using: .utf8)?.write(to: url, options: .atomic)
        return url
    }

    /// 失败项对应的 assetIdentifier 列表（UI 勾选重试用；顺序去重）。
    static func retryAssetIdentifiers(from failures: [BatchFailureItem]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for item in failures where !seen.contains(item.assetIdentifier) {
            seen.insert(item.assetIdentifier)
            result.append(item.assetIdentifier)
        }
        return result
    }

    private static func kindLabel(_ kind: MediaKind) -> String {
        switch kind {
        case .photo:     return "照片"
        case .livePhoto: return "Live Photo"
        case .animated:  return "动图"
        case .video:     return "视频"
        case .raw:       return "RAW"
        }
    }
}
