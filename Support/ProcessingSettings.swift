//
//  ProcessingSettings.swift
//  WatermarkBatch（水印工坊 BatchMark）
//
//  块B · 处理参数单一事实源（quality / 并发 / 调色板 / 码率系数全部收敛在本文件）
//
//  依据《03-技术研发方案》头部【v1.1 默认参数锁定（最高裁决）】：
//  - 默认「画质优先」：照片并发 2、视频并发 1（同一时刻最多一个视频编码）；
//  - 唯一降级开关「优先速度」（默认关）：并发 3-4（按 physicalMemory 自适应）、
//    视频码率系数 1.0（默认 1.3）、JPEG 质量 0.95（默认 1.0）；
//  - JPEG/HEIC 质量默认 1.0，PNG 无损保 alpha，一律不缩放。
//
//  设计约束：
//  ① 契约（§4）里的处理器 `process(...)` 没有 settings 参数，故本档位以「处理器实例的
//     配置」形式注入（ProcessorFactory 构造时携带），BatchQueue 另持一份用于并发调度，
//     二者必须由同一 UI 开关驱动——块C 切换「优先速度」时两处必须同时传入同一 settings。
//  ② 任何 quality/scale 常量只允许出现在本文件；处理器内禁止再写魔法数字。
//

import Foundation

// MARK: - 画质档位

/// 处理档位：画质优先（默认）/ 优先速度（唯一降级开关，切换前 UI 必须弹窗明示）。
enum ProcessingTier: String, Sendable, Codable, CaseIterable {
    case qualityFirst
    case preferSpeed
}

// MARK: - 参数集

/// 一次批处理会话的全部质量/并发参数。
struct ProcessingSettings: Sendable, Equatable {

    // MARK: 字段

    /// 画质档位。
    var tier: ProcessingTier = .qualityFirst

    /// RAW/DNG 显式同意标记（PRD F-22 / §八.4）。
    /// false 时 PhotoProcessor 遇到 RAW 一律抛 `rawConversionRequiresConsent`，绝不静默转换。
    var rawConsent: Bool = false

    /// 动图调色板色数上限。GIF 索引色上限 256（格式硬约束，不允许调大）。
    var animatedPaletteLimit: Int = 256

    /// 动图量化是否允许抖动。恒 false：抖动会造成帧间闪烁（硬要求③），保留字段以便
    /// 未来做「静态 GIF」例外时显式开启，禁止在批量路径改动。
    var animatedDitheringAllowed: Bool = false

    /// RAW/DNG 的输出容器（iOS 无法把 RAW 原格式写回相册，§八.4）。
    var rawOutputUTI: String = "public.heic"

    /// 单任务失败重试次数（处理器内部不重试，重试由用户从失败清单发起，见 BatchQueue）。
    var maxAutomaticRetries: Int = 0

    // MARK: 预设

    /// 默认档：画质优先（v1.1 最高裁决）。
    static let qualityFirst = ProcessingSettings()

    /// 「优先速度」档：唯一允许的降级（码率系数 1.0、JPEG 0.95、并发 3-4）。
    static var preferSpeed: ProcessingSettings {
        var s = ProcessingSettings()
        s.tier = .preferSpeed
        return s
    }

    /// 携带 RAW 同意标记的副本（BatchQueue 在批次启动前校验，UI 弹窗确认后传入）。
    func withRawConsent(_ consent: Bool) -> ProcessingSettings {
        var copy = self
        copy.rawConsent = consent
        return copy
    }

    // MARK: 派生参数

    /// 有损编码质量：JPEG 在「优先速度」档降为 0.95，其余有损格式恒 1.0。
    ///
    /// 为什么 HEIC 不一起降到 0.95：v1.1 裁决只授权了「JPEG 质量 0.95」，
    /// HEIC 10bit 位深保真是本产品红线，不允许顺手降档。
    var lossyQuality: Double {
        tier == .preferSpeed ? 0.95 : 1.0
    }

    /// JPEG 专用质量（自查用：默认必须为 1.0）。
    var jpegQuality: Double { lossyQuality }

    /// 视频目标码率系数（v1.1：默认 1.3，「优先速度」1.0）。
    var videoBitrateFactor: Double {
        tier == .preferSpeed ? 1.0 : 1.3
    }

    /// 是否允许把画布缩小到屏幕尺寸——恒 false，写死在此防止任何人加开关。
    /// 动图/照片/视频全链路零缩放：输出像素 = 源像素（方向烘焙后的显示像素）。
    var allowsDownscaling: Bool { false }

    // MARK: 并发（v1.1）

    /// 照片并发上限。
    /// - 画质优先（默认）：2
    /// - 优先速度：`BatchQueue.recommendedConcurrency(physicalMemoryBytes:)` → ≤4GB 取 3，>4GB 取 4
    func photoConcurrency(physicalMemoryBytes: UInt64) -> Int {
        switch tier {
        case .qualityFirst:
            return Self.qualityFirstPhotoConcurrency
        case .preferSpeed:
            return Self.speedPhotoConcurrency(physicalMemoryBytes: physicalMemoryBytes)
        }
    }

    /// 视频并发上限：恒 1（同一时刻最多一个视频在编码，避免 GPU/IO 争抢与内存翻倍）。
    var videoConcurrency: Int { Self.defaultVideoConcurrency }

    /// 默认档照片并发。
    static let qualityFirstPhotoConcurrency = 2
    /// 视频并发（任何档位）。命名带 default 前缀，避免与实例属性 `videoConcurrency` 重名。
    static let defaultVideoConcurrency = 1

    /// 「优先速度」档并发（契约 §4 recommendedConcurrency 同口径）：
    /// physicalMemory ≤ 4GB → 3，> 4GB → 4。
    static func speedPhotoConcurrency(physicalMemoryBytes: UInt64) -> Int {
        let fourGB: UInt64 = 4 * 1024 * 1024 * 1024
        return physicalMemoryBytes <= fourGB ? 3 : 4
    }

    /// 内存压力下允许的最低照片并发（降并发、不降画质）。
    static let minimumPhotoConcurrencyUnderMemoryPressure = 1

    /// 可用内存低于此阈值时把照片并发压到 1（v1.1：峰值目标 <200MB，超限降并发）。
    /// 取 150MB：单张 4000×3000 的解码 + CI 合成峰值约 120-160MB，留出安全余量。
    static let memoryPressureThresholdBytes: UInt64 = 150 * 1024 * 1024
}
