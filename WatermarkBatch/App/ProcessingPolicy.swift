//
//  ProcessingPolicy.swift
//  WatermarkBatch（水印工坊 BatchMark）
//
//  块C · 处理策略（UI 展示层）
//
//  单一事实源在块B：`Support/ProcessingSettings.swift`（码率系数 / JPEG 质量 / 并发上限）。
//  本类型只是它的「UI 持久化外壳」：设置页改档位 → 写 UserDefaults → 启动批次时
//  转成 ProcessingSettings 传给 BatchQueue 与四个处理器。所有展示值（1.3 / 1.0 / 0.95 /
//  并发 2/1 或 3-4）全部从 settings 的派生属性读取，UI 不另写常量。
//
//  「输出 PNG 无损」是块C 侧的增强开关（规避 HEIC 二次编码轻微损失）：
//  以 extension 形式挂在 ProcessingSettings 上（UserDefaults 持久化），已由块B
//  `Processing/PhotoProcessor.swift` 消费——仅 heic/heif 静态照片改 public.png（10bit 拓宽 16bpc），
//  RAW / GIF / WebP / Live Photo 静帧不变。默认关，代价见 README §四 边界 3。
//

import Foundation

// MARK: - 处理策略（UI 外壳）

struct ProcessingPolicy: Sendable, Equatable {

    /// 档位（块B ProcessingTier：qualityFirst 默认 / preferSpeed 唯一降级开关）。
    var tier: ProcessingTier = .qualityFirst

    /// 输出 PNG 无损（与档位正交；写入 ProcessingSettings.outputLosslessPNG）。
    var outputLosslessPNG: Bool = false

    // MARK: → 块B 参数集（唯一出口，禁止 UI 另拼第二份）

    /// 转成块B 参数集。rawConsent 由 BatchController 启动时经 withRawConsent 注入。
    var settings: ProcessingSettings {
        ProcessingSettings(tier: tier)
    }

    // MARK: 派生展示值（全部读自 settings，UI 禁止写字面量）

    /// 视频目标码率系数：max(源码率 × 系数, 平台推荐值)。
    var videoBitrateCoefficient: Double { settings.videoBitrateFactor }

    /// JPEG 有损压缩质量（HEIC 恒 1.0，见 ProcessingSettings.lossyQuality 注释）。
    var jpegCompressionQuality: Double { settings.jpegQuality }

    /// 照片类并发上限（quality 恒 2；speed 按物理内存 3-4）。
    var photoConcurrency: Int {
        settings.photoConcurrency(physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory)
    }

    /// 视频并发上限：恒 1（同一时刻最多一个视频在编码）。
    var videoConcurrency: Int { settings.videoConcurrency }

    // MARK: 展示文案

    var modeTitle: String { tier.title }
    var modeSubtitle: String { tier.subtitle }

    /// 切到「优先速度」时的二次确认正文：逐项说明具体变化（数字来自 settings 派生值）。
    var speedDowngradeExplanation: String {
        let quality = ProcessingPolicy(tier: .qualityFirst, outputLosslessPNG: outputLosslessPNG)
        let speed = ProcessingPolicy(tier: .preferSpeed, outputLosslessPNG: outputLosslessPNG)
        return """
        开启后本批处理将改为「优先速度」，会牺牲部分画质，具体变化：

        • 视频码率系数：\(Self.format(quality.videoBitrateCoefficient)) → \(Self.format(speed.videoBitrateCoefficient))（视频文件更小，块效应风险上升）
        • JPEG 质量：\(Self.format(quality.jpegCompressionQuality)) → \(Self.format(speed.jpegCompressionQuality))（HEIC 恒 1.0 不降）
        • 并发：照片 \(quality.photoConcurrency) → \(speed.photoConcurrency) 个（按内存自适应），视频恒 \(speed.videoConcurrency) 个

        分辨率、帧率、时长、HDR 色彩、EXIF、音频直通均不变；原片不会被修改。
        """
    }

    // MARK: 持久化

    static var current: ProcessingPolicy {
        get {
            let tierRaw = UserDefaults.standard.string(forKey: tierKey) ?? ProcessingTier.qualityFirst.rawValue
            let tier = ProcessingTier(rawValue: tierRaw) ?? .qualityFirst
            let png = UserDefaults.standard.bool(forKey: pngKey)
            return ProcessingPolicy(tier: tier, outputLosslessPNG: png)
        }
        set {
            UserDefaults.standard.set(newValue.tier.rawValue, forKey: tierKey)
            UserDefaults.standard.set(newValue.outputLosslessPNG, forKey: pngKey)
        }
    }

    private static let tierKey = "batchmark.processingTier.v1"
    private static let pngKey = "batchmark.outputLosslessPNG.v1"

    /// 「跳过已加水印」的判定维度（与 AppModel.watermarkKey / tasksExcludingWatermarked 同口径）：
    /// 文件名相同 + 像素尺寸相同 + 存在创建时间更晚的副本 → 判定为已加水印。
    static let skipDetectionDimensions = "文件名＋像素尺寸＋创建时间"

    /// 数值展示：1.3 / 1.0 / 0.95 原样。
    static func format(_ value: Double) -> String {
        if value == value.rounded() { return String(format: "%.1f", value) }
        return String(format: "%.2f", value)
    }
}

// MARK: - 档位文案（块B ProcessingTier 的 UI 展示扩展）

extension ProcessingTier {
    var title: String {
        switch self {
        case .qualityFirst: return "优先画质"
        case .preferSpeed: return "优先速度"
        }
    }

    var subtitle: String {
        switch self {
        case .qualityFirst:
            return "默认。码率 1.3×、JPEG 1.0、并发 2 照片 / 1 视频。宁慢勿损。"
        case .preferSpeed:
            return "更快，但会降低画质：码率 1.0×、JPEG 0.95、并发 3-4。"
        }
    }
}

// MARK: - 「输出 PNG 无损」开关（块C 挂在 ProcessingSettings 上的持久化字段）

extension ProcessingSettings {

    /// true 时块B `PhotoProcessor` 把 **heic/heif 静态照片**的输出容器改为 PNG（无损、保 alpha、
    /// 位深不降）；RAW / GIF/WebP / Live Photo 静帧不受影响。用于规避 HEIC 二次编码的轻微损失；
    /// 代价：12MP 约 25-35MB/张（增大 6-10 倍）、部分 EXIF/GPS 可能无法承载、批次更慢。默认 false。
    /// 存 UserDefaults：ProcessingSettings 是值类型且归块B 所有，块C 不改其存储结构。
    var outputLosslessPNG: Bool {
        get { UserDefaults.standard.bool(forKey: "batchmark.outputLosslessPNG.v1") }
        set { UserDefaults.standard.set(newValue, forKey: "batchmark.outputLosslessPNG.v1") }
    }
}

// MARK: - 预估耗时

/// 批量预估结果（确认弹窗逐项展示）。
struct BatchEstimate: Sendable, Equatable {
    var photoCount = 0
    var liveCount = 0
    var gifCount = 0
    var videoCount = 0
    var rawCount = 0
    /// 端到端墙钟预估（秒）。
    var wallClockSeconds: Double = 0

    var totalCount: Int { photoCount + liveCount + gifCount + videoCount + rawCount }

    /// 类型分布文案，如「照片 12 · Live 3 · 动图 1 · 视频 2 · RAW 1」。
    var distributionText: String {
        var parts: [String] = []
        if photoCount > 0 { parts.append("照片 \(photoCount)") }
        if liveCount > 0 { parts.append("Live \(liveCount)") }
        if gifCount > 0 { parts.append("动图 \(gifCount)") }
        if videoCount > 0 { parts.append("视频 \(videoCount)") }
        if rawCount > 0 { parts.append("RAW \(rawCount)") }
        return parts.isEmpty ? "无素材" : parts.joined(separator: " · ")
    }

    /// 「约 1 分 20 秒」；不足 1 分钟显示秒。
    var durationText: String {
        let total = Int(wallClockSeconds.rounded())
        if total < 60 { return "约 \(max(total, 1)) 秒" }
        let minutes = total / 60
        let seconds = total % 60
        return seconds == 0 ? "约 \(minutes) 分钟" : "约 \(minutes) 分 \(seconds) 秒"
    }
}

/// 预估耗时模型。
///
/// 公式（写死在此，UI 与确认框共用；单位为秒）：
/// ```
/// photoWork = Σ 单张照片耗时 × max(1, 像素数 / 12MP)          // 4000×3000 ≈ 12MP 为基准
/// liveWork  = Σ (照片耗时 + 2s 视频段耗时)                      // Live 动段按 2s 保守估
/// gifWork   = Σ 帧数(未知按 60) × 单帧耗时
/// videoWork = Σ 时长(s) × 每秒耗时(按短边相对 1080p 的 √像素比缩放)
/// 墙钟 = photoWork / photoConcurrency + videoWork / videoConcurrency
/// ```
/// 基准数据来自《04-测试保障方案》§4.2 默认保守档预期：30 张 10-12s（≈0.36s/张）、
/// 1080p30 60s 视频 30-40s（≈0.62s/s）、4K30 60s 视频 60-80s（≈1.17s/s，√4 = 2 倍于 1080p）。
/// 误差目标 ±20%（PRD F-27）；实测偏差时改这里，不要改 UI。
enum BatchEstimator {

    static let photoSecondsPer12MP: Double = 0.36
    static let rawSecondsPer12MP: Double = 0.55      // RAW 解码 + HEIC 编码更重
    static let gifSecondsPerFrame: Double = 0.075
    static let assumedGIFFrameCount: Double = 60     // 未解码前无法得知帧数，取中位估计
    static let liveVideoSeconds: Double = 2.0        // Live 动段典型时长
    static let videoSecondsPerSecond1080p30: Double = 0.62
    static let megapixelReference: Double = 12_000_000

    static func estimate(assets: [LibraryAsset], policy: ProcessingPolicy) -> BatchEstimate {
        var result = BatchEstimate()
        var photoWork: Double = 0
        var videoWork: Double = 0

        for asset in assets {
            let megapixels = Double(asset.pixelSize.width * asset.pixelSize.height)
            let pixelFactor = max(1, megapixels / megapixelReference)

            switch asset.kind {
            case .photo:
                result.photoCount += 1
                photoWork += photoSecondsPer12MP * pixelFactor
            case .raw:
                result.rawCount += 1
                photoWork += rawSecondsPer12MP * pixelFactor
            case .livePhoto:
                result.liveCount += 1
                photoWork += photoSecondsPer12MP * pixelFactor
                videoWork += videoSecondsPerSecond(duration: liveVideoSeconds,
                                                   pixelSize: asset.pixelSize)
            case .animated:
                result.gifCount += 1
                photoWork += gifSecondsPerFrame * assumedGIFFrameCount * pixelFactor
            case .video:
                result.videoCount += 1
                videoWork += videoSecondsPerSecond(duration: asset.duration ?? 0,
                                                   pixelSize: asset.pixelSize)
            }
        }

        // 视频档并发恒为 1，照片档按策略并发摊薄；两者相加即端到端墙钟。
        let photoWall = photoWork / Double(max(policy.photoConcurrency, 1))
        let videoWall = videoWork / Double(max(policy.videoConcurrency, 1))
        result.wallClockSeconds = max(photoWall + videoWall, 0.5)
        return result
    }

    /// 视频每秒处理耗时：以 1080p 为基准，按短边像素比的平方根线性放大（4K ≈ 2 倍）。
    private static func videoSecondsPerSecond(duration: TimeInterval, pixelSize: CGSize) -> Double {
        guard duration > 0, pixelSize.width > 0, pixelSize.height > 0 else { return 0 }
        let shortSide = Double(min(pixelSize.width, pixelSize.height))
        let ratio = max(shortSide / 1080.0, 0.5)
        return duration * videoSecondsPerSecond1080p30 * ratio.squareRoot()
    }
}
