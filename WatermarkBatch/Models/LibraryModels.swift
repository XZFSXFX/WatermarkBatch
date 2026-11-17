//
//  LibraryModels.swift
//  WatermarkBatch（水印工坊 BatchMark）
//
//  块A · 相册/任务数据模型层
//  契约来源：《03-技术研发方案》§4【接口契约】—— 本文件所有公开类型签名与契约一字不改。
//

import CoreGraphics
import Foundation

// MARK: - 相册权限

/// 相册访问级别（PRD F-25：完全访问 / 仅添加 / 拒绝）。
/// 注意：仅添加（addOnly）模式下无法读取既有相册——批量导入需完全访问；
/// addOnly 仅覆盖「仅写入」路径（如从分享面板进入）。
enum PhotoAccessLevel: Sendable, Equatable {
    case full, addOnly, denied
}

// MARK: - 素材模型

/// App 内部的素材统一模型：从 PHAsset 探测/包装而来，混合类型（照片/Live Photo/GIF/视频/RAW）。
/// Sendable 值类型——跨并发域传递安全（批处理 TaskGroup 需要）。
struct LibraryAsset: Identifiable, Hashable, Sendable {
    /// App 内部 ID（模板/任务引用它）。
    /// 由 assetIdentifier 确定性派生（SHA256 v5 布局）：同一 PHAsset 在多次取数中 ID 稳定，
    /// 避免 UI 刷新导致选中态/任务引用漂移。派生逻辑见 PhotoLibraryService。
    let id: UUID
    let assetIdentifier: String        // PHAsset.localIdentifier
    let kind: MediaKind
    let pixelSize: CGSize
    let duration: TimeInterval?        // 视频/Live Photo 有效
    let creationDate: Date?
    let originalFilename: String?
    /// iCloud 可用性初始标记。系统无公开 API 可在取数时同步查询；
    /// 列表云朵角标由 UI 调用 `PhotoLibraryService.isOriginalInICloud(_:)` 惰性探测刷新。
    /// 无论该值如何，导出链路一律下载原图（进度可见、失败不降级），绝不静默用缩略图处理。
    let isInICloud: Bool
}

// MARK: - 日期分组

/// 按拍摄日倒序分组（PRD F-01）：id 为当天 0 点（Calendar.startOfDay）。
struct AssetDayGroup: Identifiable, Sendable {
    let id: Date                                 // 当天 0 点
    let assets: [LibraryAsset]
}

// MARK: - 任务状态与导出记录

/// 单素材处理任务状态。
enum TaskStatus: String, Codable, Sendable, Equatable {
    case pending, running, succeeded, failed, cancelled
}

/// 导出记录（PRD F-29）：每素材一条，持久化由 ExportRecordStore（块B）负责。
struct ExportRecord: Codable, Identifiable, Sendable {
    let id: UUID
    let assetIdentifier: String
    let kind: MediaKind
    let status: TaskStatus
    let startedAt: Date
    let finishedAt: Date?
    let errorDescription: String?
    /// v1.2：实际输出容器 UTI（如 `public.png` = 用户勾选了「PNG 无损」）。
    /// 可选 + 默认 nil，旧记录解码不受影响；用于导出记录页展示与排障。
    var outputUTI: String? = nil
    /// v1.2：输出侧说明（PNG 容器变化 + PNG 未携带的元数据分组，见 BatchQueue.pngNote）。
    /// 可选 + 默认 nil：旧记录解码不受影响。
    var outputNote: String? = nil
}
