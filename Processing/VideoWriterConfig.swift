//
//  VideoWriterConfig.swift
//  WatermarkBatch（水印工坊 BatchMark）
//
//  块B · 视频编码参数（码率 / 编码器 / profile-level / GOP / HDR 色彩）
//
//  ── 硬要求④ 全部落在这里 ────────────────────────────────────────────────
//  1. `AVVideoAverageBitRateKey` 不写常量：
//     targetBitrate = max(源视频轨码率 × 系数, platformRecommendation(分辨率, 帧率, 编码器))；
//     系数：画质优先 1.3，优先速度 1.0（v1.1）；下限取平台推荐值。
//  2. 编码器严格同源：avc1 → AVVideoCodecType.h264；hvc1/hev1 → .hevc。
//  3. profile 不低于源：H.264 High 源 → AVVideoProfileLevelH264HighAutoLevel；
//     HEVC 8bit → HEVC_Main_AutoLevel，10bit → HEVC_Main10_AutoLevel。
//  4. level 从源 CMFormatDescription 解析（H.264 读 SPS，HEVC 读 VPS 的 profile_tier_level），
//     输出后回读校验；低于源则带显式 level 重试一次（重试编排在 VideoProcessor）。
//  5. GOP 与原文件相近：预扫源关键帧间隔推算，夹取 [0.5s, 10s]，绝不放大到 10 秒以上。
//  6. `shouldOptimizeForNetworkUse = false`（在 VideoProcessor 设置）。严禁 AVAssetExportSession 预设。
//
//  ── 平台推荐码率的来源与口径（必须写清，避免被当成拍脑袋常数）─────────────
//  Apple HIG《Video and Audio》与 VideoToolbox 实测经验值：
//    H.264 1080p30 ≈ 10 Mbps → 0.16 bit/pixel；HEVC 1080p30 ≈ 6.2 Mbps → 0.10 bit/pixel。
//  推荐值 = bpp × 宽 × 高 × 帧率，并按编码器下限/上限夹取：
//    H.264 [2 Mbps, 240 Mbps]，HEVC [1.2 Mbps, 160 Mbps]。
//  4K30：H.264 ≈ 40 Mbps、HEVC ≈ 25 Mbps（与 Apple 官方建议量级一致）。
//  注意：这是「推荐下限」而非目标值——目标值始终先取「源码率 × 系数」。
//

import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

// MARK: - 编码器

enum VideoCodec: String, Sendable, Equatable {
    case h264
    case hevc

    /// AVFoundation 编码器标识。
    var avCodec: AVVideoCodecType {
        switch self {
        case .h264: return .h264
        case .hevc: return .hevc
        }
    }

    /// 容器内 fourCC（同源判定依据）。
    var fourCC: String {
        switch self {
        case .h264: return "avc1"
        case .hevc: return "hvc1"
        }
    }

    var displayName: String {
        switch self {
        case .h264: return "H.264"
        case .hevc: return "HEVC"
        }
    }
}

// MARK: - 源侧 profile 探测

/// 从源视频轨 formatDescription 解析出的编码画像。
struct VideoSourceProfile: Sendable, Equatable {
    let codec: VideoCodec
    let bitDepth: Int
    /// H.264: level_idc（如 41 = 4.1）；HEVC: level_idc（如 153 = 5.1）。解析失败为 nil。
    let level: Int?
    /// H.264 是否为 High 及以上 profile（profile_idc ≥ 100）。
    let isHighProfile: Bool
    let colorPrimaries: String?
    let transferFunction: String?
    let yCbCrMatrix: String?

    /// 是否高位深（HEVC 10bit / 12bit）。
    var isHighBitDepth: Bool { bitDepth >= 10 }

    /// 是否 HDR（PQ/HLG 传递函数，或 BT.2020 原色）。
    var isHDR: Bool {
        if let transferFunction {
            if transferFunction.contains("2084") || transferFunction.uppercased().contains("PQ") { return true }
            if transferFunction.uppercased().contains("HLG") || transferFunction.contains("2100") { return true }
        }
        if let colorPrimaries, colorPrimaries.contains("2020") { return true }
        return false
    }
}

// MARK: - 编码计划

/// 单次视频编码的完整参数（值类型，无 AVFoundation 对象，可安全传递）。
struct VideoEncodePlan: Sendable, Equatable {
    let codec: VideoCodec
    let width: Int
    let height: Int
    let frameRate: Double
    let bitrate: Int
    /// 写入 `AVVideoProfileLevelKey` 的值。
    let profileLevel: String
    let maxKeyFrameInterval: Int
    let bitDepth: Int
    let colorPrimaries: String?
    let transferFunction: String?
    let yCbCrMatrix: String?

    /// 是否 10bit 及以上（决定像素格式 420 10bit vs 32BGRA）。
    var isHighBitDepth: Bool { bitDepth >= 10 }

    /// 读帧/写帧使用的像素格式。
    /// - 8bit：32BGRA（Core Image 直通、VideoToolbox 硬编常规路径）
    /// - 10bit：420YpCbCr10BiPlanarVideoRange（保 HLG/PQ 的 10bit 精度，禁 tone map）
    var pixelFormat: OSType {
        isHighBitDepth
            ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            : kCVPixelFormatType_32BGRA
    }

    /// AVAssetWriterInput.outputSettings。
    func outputSettings() -> [String: Any] {
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: bitrate,
            AVVideoExpectedSourceFrameRateKey: Int(frameRate.rounded()),
            AVVideoMaxKeyFrameIntervalKey: maxKeyFrameInterval,
            AVVideoProfileLevelKey: profileLevel,
            // 允许 B 帧/重排序：画质优先；不开启实时编码限制。
            AVVideoAllowFrameReorderingKey: true,
        ]
        // 色彩属性必须三件套齐全才写入（Apple 要求，缺一会导致设置被忽略）。
        if let colorPrimaries, let transferFunction, let yCbCrMatrix {
            compression[AVVideoColorPropertiesKey] = [
                AVVideoColorPrimariesKey: colorPrimaries,
                AVVideoTransferFunctionKey: transferFunction,
                AVVideoYCbCrMatrixKey: yCbCrMatrix,
            ]
        }

        return [
            AVVideoCodecKey: codec.avCodec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: compression,
        ]
    }
}

// MARK: - 参数计算

enum VideoWriterConfig {

    // MARK: 码率

    /// 平台推荐码率（bps）：bpp × 像素数 × 帧率，按编码器上下限夹取。
    static func recommendedBitrate(width: Int,
                                   height: Int,
                                   frameRate: Double,
                                   codec: VideoCodec) -> Double {
        guard width > 0, height > 0, frameRate > 0 else { return 0 }
        let bitsPerPixel: Double = (codec == .hevc) ? 0.10 : 0.16
        let raw = bitsPerPixel * Double(width) * Double(height) * frameRate
        let lower: Double = (codec == .hevc) ? 1_200_000 : 2_000_000
        let upper: Double = (codec == .hevc) ? 160_000_000 : 240_000_000
        return min(max(raw, lower), upper)
    }

    /// 目标码率 = max(源码率 × 系数, 平台推荐)。
    /// - Parameter factor: 1.3（画质优先，v1.1 默认）/ 1.0（优先速度）。
    static func targetBitrate(sourceBitrate: Double,
                              width: Int,
                              height: Int,
                              frameRate: Double,
                              codec: VideoCodec,
                              factor: Double) -> Int {
        let recommendation = recommendedBitrate(width: width, height: height,
                                                frameRate: frameRate, codec: codec)
        let scaled = max(sourceBitrate, 0) * max(factor, 1.0)
        return Int(max(scaled, recommendation).rounded())
    }

    // MARK: profile / level

    /// 组装 `AVVideoProfileLevelKey`。
    ///
    /// - Parameters:
    ///   - explicitLevel: 非 nil 时输出「显式 level」（回读校验失败后的重试路径）。
    static func profileLevel(codec: VideoCodec,
                             bitDepth: Int,
                             isHighProfileH264: Bool,
                             explicitLevel: Int?) -> String {
        switch codec {
        case .h264:
            guard isHighProfileH264 else {
                // 源是 Baseline/Main 时不允许「升到 High」吗？允许（profile 只许不低于源），
                // 但保持源的 profile 更贴近原文件，避免解码兼容性变化。
                return explicitLevel.map { h264ExplicitLevel($0) ?? AVVideoProfileLevelH264MainAutoLevel }
                    ?? AVVideoProfileLevelH264MainAutoLevel
            }
            return explicitLevel.flatMap(h264ExplicitLevel) ?? AVVideoProfileLevelH264HighAutoLevel

        case .hevc:
            if bitDepth >= 10 {
                if let explicitLevel, let literal = hevcExplicitLevel(explicitLevel, main10: true) {
                    return literal
                }
                return kVTProfileLevel_HEVC_Main10_AutoLevel as String
            }
            if let explicitLevel, let literal = hevcExplicitLevel(explicitLevel, main10: false) {
                return literal
            }
            return kVTProfileLevel_HEVC_Main_AutoLevel as String
        }
    }

    /// H.264 level_idc → 显式 profile level 字符串（仅收录 AVFoundation 公开常量覆盖的档位）。
    /// 50/51/52 等更高档位没有公开常量，返回 nil → 退回 AutoLevel（AutoLevel 由编码器按内容选，
    /// 不会低于内容所需；若仍低于源，VideoProcessor 会按失败处理并如实报错，而不是假装达标）。
    private static func h264ExplicitLevel(_ level: Int) -> String? {
        switch level {
        case 30: return AVVideoProfileLevelH264High40   // 3.0 源极少见，取最近的公开档位 4.0
        case 31, 32, 40: return AVVideoProfileLevelH264High40
        case 41: return AVVideoProfileLevelH264High41
        case 42: return AVVideoProfileLevelH264High42
        default: return nil
        }
    }

    /// HEVC level_idc（= level × 30）→ 显式 profile level 字符串。
    /// VideoToolbox 接受 `HEVC_Main10_5_1` 这类字面量；10bit 必须带 Main10 前缀。
    private static func hevcExplicitLevel(_ levelIDC: Int, main10: Bool) -> String? {
        guard levelIDC >= 30 else { return nil }
        let major = levelIDC / 30
        let minor = levelIDC % 30
        guard (1...6).contains(major), [0, 1, 2].contains(minor) else { return nil }
        return main10 ? "HEVC_Main10_\(major)_\(minor)" : "HEVC_Main_\(major)_\(minor)"
    }

    // MARK: 源探测

    /// 从 formatDescription 解析源编码画像（编码器 / 位深 / level / profile / 色彩）。
    static func sourceProfile(from description: CMVideoFormatDescription,
                              codec: VideoCodec) -> VideoSourceProfile {
        let extensions = CMFormatDescriptionGetExtensions(description) as? [String: Any] ?? [:]
        let bitDepthValue = CMVideoFormatDescriptionGetBitsPerComponent(description)
        let bitDepth = bitDepthValue > 0 ? Int(bitDepthValue) : 8

        var level: Int?
        var isHighProfile = false
        switch codec {
        case .h264:
            if let spsLevel = h264Level(from: description) {
                level = spsLevel.level
                isHighProfile = spsLevel.profileIDC >= 100
            }
        case .hevc:
            if let vps = hevcProfileTierLevel(from: description) {
                level = vps.levelIDC
                // general_profile_idc: 1 = Main, 2 = Main10, 3 = Main Still Picture, 4 = RExt
                isHighProfile = vps.profileIDC >= 2
            }
        }

        return VideoSourceProfile(
            codec: codec,
            bitDepth: bitDepth,
            level: level,
            isHighProfile: isHighProfile,
            colorPrimaries: extensions[kCMFormatDescriptionExtension_ColorPrimaries as String] as? String,
            transferFunction: extensions[kCMFormatDescriptionExtension_TransferFunction as String] as? String,
            yCbCrMatrix: extensions[kCMFormatDescriptionExtension_YCbCrMatrix as String] as? String
        )
    }

    /// 读取 H.264 SPS：profile_idc = sps[1]，level_idc = sps[3]。
    /// `CMVideoFormatDescriptionGetH264ParameterSetAtIndex` 返回的参数集含 1 字节 NAL header。
    static func h264Level(from description: CMVideoFormatDescription) -> (profileIDC: Int, level: Int)? {
        var pointer: UnsafePointer<UInt8>?
        var size = 0
        let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            description,
            parameterSetIndex: 0,
            parameterSetPointerOut: &pointer,
            parameterSetSizeOut: &size,
            parameterSetCountOut: nil,
            nalUnitHeaderLengthOut: nil
        )
        guard status == noErr, let pointer, size >= 4 else { return nil }
        return (Int(pointer[1]), Int(pointer[3]))
    }

    /// 读取 HEVC VPS 的 profile_tier_level：
    /// VPS NAL = 2 字节 NAL header + 4 字节 vps 字段，其后是 profile_tier_level：
    /// [0] profile_space(2)|tier(1)|profile_idc(5)，[11] general_level_idc。
    /// 故 profile_idc = vps[6] >> 3，level_idc = vps[6 + 11]。
    static func hevcProfileTierLevel(from description: CMVideoFormatDescription) -> (profileIDC: Int, levelIDC: Int)? {
        var pointer: UnsafePointer<UInt8>?
        var size = 0
        let status = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
            description,
            parameterSetIndex: 0,
            parameterSetPointerOut: &pointer,
            parameterSetSizeOut: &size,
            parameterSetCountOut: nil,
            nalUnitHeaderLengthOut: nil
        )
        guard status == noErr, let pointer, size >= 18 else { return nil }
        let profileIDC = Int((pointer[6] >> 3) & 0x1F)
        let levelIDC = Int(pointer[17])
        guard levelIDC > 0 else { return nil }
        return (profileIDC, levelIDC)
    }

    // MARK: GOP

    /// 预扫源的关键帧间隔（帧数），夹取 [0.5s, 10s]。
    ///
    /// 为什么预扫：AVAssetTrack 不直接暴露 GOP 长度；用 AVAssetReader 以「压缩样本直通」
    /// （outputSettings: nil，不解码）读前 ~20s，统计相邻同步样本间隔即可，代价很小。
    /// 兜底：读不到时取 2s（Apple 常用默认），绝不取 10s 以上（硬要求④）。
    static func estimateGOPFrameCount(asset: AVAsset,
                                      track: AVAssetTrack,
                                      frameRate: Double) async -> Int {
        let fps = max(frameRate, 1)
        let fallback = max(1, Int((2.0 * fps).rounded()))

        guard let reader = try? AVAssetReader(asset: asset) else { return fallback }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return fallback }
        reader.add(output)
        guard reader.startReading() else { return fallback }
        defer { reader.cancelReading() }

        var frameCursor = 0
        var lastSyncFrame = -1
        var gopLengths: [Int] = []
        let scanLimitFrames = Int(fps * 20)

        while let sample = output.copyNextSampleBuffer() {
            let sampleCount = CMSampleBufferGetNumSamples(sample)
            guard sampleCount > 0 else { continue }

            let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[String: Any]]
            let notSync = attachments?.first?[kCMSampleAttachmentKey_NotSync as String] as? Bool ?? false
            if !notSync {
                if lastSyncFrame >= 0 {
                    gopLengths.append(frameCursor - lastSyncFrame)
                }
                lastSyncFrame = frameCursor
            }
            frameCursor += sampleCount

            if gopLengths.count >= 3 || frameCursor > scanLimitFrames { break }
        }

        guard !gopLengths.isEmpty else { return fallback }
        let sorted = gopLengths.sorted()
        let median = sorted[sorted.count / 2]
        let seconds = Double(median) / fps
        let clamped = min(max(seconds, 0.5), 10.0)
        return max(1, Int((clamped * fps).rounded()))
    }

    // MARK: 组装计划

    /// 由源画像与目标尺寸组装编码计划。
    static func makePlan(source: VideoSourceProfile,
                         width: Int,
                         height: Int,
                         frameRate: Double,
                         sourceBitrate: Double,
                         gopFrameCount: Int,
                         factor: Double,
                         explicitLevel: Int?) -> VideoEncodePlan {
        VideoEncodePlan(
            codec: source.codec,
            width: width,
            height: height,
            frameRate: frameRate,
            bitrate: targetBitrate(sourceBitrate: sourceBitrate,
                                   width: width,
                                   height: height,
                                   frameRate: frameRate,
                                   codec: source.codec,
                                   factor: factor),
            profileLevel: profileLevel(codec: source.codec,
                                       bitDepth: source.bitDepth,
                                       isHighProfileH264: source.isHighProfile,
                                       explicitLevel: explicitLevel),
            maxKeyFrameInterval: max(1, gopFrameCount),
            bitDepth: source.bitDepth,
            colorPrimaries: source.colorPrimaries,
            transferFunction: source.transferFunction,
            yCbCrMatrix: source.yCbCrMatrix
        )
    }

    // MARK: 编码器同源判定

    /// fourCC → 编码器；未知编码器返回 nil（调用方抛 unsupportedFormat，绝不换编码器）。
    static func codec(fromFourCC fourCC: String) -> VideoCodec? {
        switch fourCC.lowercased() {
        case "avc1", "avc3": return .h264
        case "hvc1", "hev1": return .hevc
        default: return nil
        }
    }
}
