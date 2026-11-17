//
//  WatermarkError.swift
//  WatermarkBatch（水印工坊 BatchMark）
//
//  块A · 统一错误模型 + 用户可读文案映射
//  契约来源：《03-技术研发方案》§4【接口契约】—— 枚举声明与契约一字不改；
//  LocalizedError 以 extension 形式附加（不改动契约声明的遵循列表）。
//

import Foundation

// MARK: - 统一错误

/// 全 App 统一错误：批处理队列、导出、UI 提示共用同一套分支（§六 非功能基线：
/// 未捕获错误全接入本枚举，杜绝裸字符串错误）。
enum WatermarkError: Error, Sendable, Equatable {
    case accessDenied
    case assetUnavailable(assetIdentifier: String)
    case iCloudDownloadFailed(assetIdentifier: String)   // 可重试、不静默降级
    case unsupportedFormat(String)
    case rawConversionRequiresConsent(String)
    case renderFailed(String)
    case encodeFailed(String)
    case writeFailed(String)
    case cancelled
}

// MARK: - 用户可读文案（PRD §7 合规文案口径）

extension WatermarkError {

    /// 用户可读的错误描述（中文，无技术术语）。UI 失败清单/弹窗统一从这里取文案。
    var userReadableDescription: String {
        switch self {
        case .accessDenied:
            return "无法访问相册。请在系统设置中允许「水印工坊」访问照片；仅授予「添加照片」权限时只能保存、无法批量导入。"
        case .assetUnavailable(let id):
            return "素材不可用或已被删除（\(id)）。"
        case .iCloudDownloadFailed:
            return "iCloud 原图下载失败，请检查网络后重试。该素材已跳过，未使用缩略图降级处理。"
        case .unsupportedFormat(let detail):
            return "暂不支持该格式：\(detail)。"
        case .rawConversionRequiresConsent(let detail):
            return "本批次包含 RAW/DNG 文件（\(detail)）。iOS 无法以原 RAW 格式写回加过水印的版本，"
                + "它们将以 HEIC（画质无损级质量）保存为新副本，原 RAW 文件保持不变。请先确认是否继续。"
        case .renderFailed(let detail):
            return "水印渲染失败：\(detail)"
        case .encodeFailed(let detail):
            return "编码失败：\(detail)"
        case .writeFailed(let detail):
            return "写入相册失败：\(detail)"
        case .cancelled:
            return "任务已取消。已完成的素材不受影响。"
        }
    }

    /// 是否值得展示「重试」按钮（iCloud 下载失败可重试且不降级——PRD F-02）。
    var isRetryable: Bool {
        switch self {
        case .iCloudDownloadFailed:
            return true
        default:
            return false
        }
    }
}

// MARK: - LocalizedError（系统层直接打印/上报时也输出可读文案）

extension WatermarkError: LocalizedError {
    var errorDescription: String? { userReadableDescription }
}
