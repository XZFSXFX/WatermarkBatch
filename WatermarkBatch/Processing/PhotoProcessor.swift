//
//  PhotoProcessor.swift
//  WatermarkBatch（水印工坊 BatchMark）
//
//  块B · 照片处理器（HEIC/HEIF/JPEG/PNG/TIFF/BMP/WebP + RAW/DNG→HEIC）
//  契约：`struct PhotoProcessor: AssetProcessor`（§4，签名一字不改）
//
//  硬约束落点：
//  ① 不缩放：解码用 `CGImageSourceCreateImageAtIndex`（绝不 CreateThumbnailAtIndex），
//     画布 = 方向烘焙后的显示像素，输出像素尺寸与源完全一致。
//  ② 原编码器原样写回：目标 UTI 取 `CGImageSourceGetType`（比 asset 探测更权威），
//     系统缺该编码器时抛 unsupportedFormat，绝不静默转 JPEG。
//  ③ EXIF/方向/GPS/镜头/色彩空间/位深：整本属性字典透传（EXIFPreserver），方向烘焙后置 1。
//  ④ JPEG/HEIC 质量 1.0（EXIFPreserver.quality 唯一定义），PNG 无损保 alpha。
//  ⑥ 用户勾选「输出 PNG 无损」（settings.outputLosslessPNG，默认 false）时，HEIC/HEIF 源
//     改为 public.png 输出：无损、保 alpha、位深不降（10bit→16bpc）；其余格式与 RAW、
//     Live Photo 静帧不受影响（见 resolvedOutputUTI 注释）。PNG 带不全的元数据分组由
//     BatchQueue.pngNote 依据产物实测列出（批次日志 + 导出记录），不静默丢弃、也不中止任务。
//  ⑤ RAW/DNG：未 `rawConsent` 直接抛错（不静默转换），同意了才转 HEIC。
//

import CoreGraphics
import Foundation
import ImageIO

struct PhotoProcessor: AssetProcessor {

    // MARK: 契约

    let kind: MediaKind

    // MARK: 参数

    private let settings: ProcessingSettings

    init(kind: MediaKind = .photo, settings: ProcessingSettings = .qualityFirst) {
        self.kind = kind
        self.settings = settings
    }

    // MARK: 主流程

    func process(asset: LibraryAsset,
                 config: WatermarkConfig,
                 library: PhotoLibraryService,
                 compositor: WatermarkCompositor,
                 progress: @Sendable @escaping (Double) -> Void) async throws -> ProcessedOutput {

        let displayName = asset.originalFilename ?? asset.assetIdentifier

        // ── 阶段 1：读取 ────────────────────────────────────────────────
        ProcessingTrace.mark(.reading)
        progress(0)

        // formatInfo 内部与原图下载共用 NSCache，正常不会产生第二次下载（§六.1-③）。
        let info = try await library.formatInfo(for: asset)

        let data = try await library.originalImageData(for: asset) { fraction in
            progress(0.02 + fraction * 0.38)
        }
        try Task.checkCancellation()

        guard let source = CGImageSourceCreateWithData(
            data as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ) else {
            throw WatermarkError.unsupportedFormat("原图数据无法解析（\(displayName)）")
        }

        let sourceUTI = (CGImageSourceGetType(source) as String?) ?? info.uti
        let isRaw = (kind == .raw) || EXIFPreserver.isRaw(uti: sourceUTI)

        // RAW 门禁：未显式同意一律拒绝（PRD F-22 / §八.4），绝不静默转换。
        if isRaw && !settings.rawConsent {
            throw WatermarkError.rawConversionRequiresConsent(displayName)
        }

        let sourceProperties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]

        // 关键：CreateImageAtIndex + ShouldCacheImmediately，一次解码、立即展开，绝不缩略图。
        guard let decoded = CGImageSourceCreateImageAtIndex(
            source, 0,
            [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        ) else {
            throw WatermarkError.unsupportedFormat("图像解码失败（\(displayName)）")
        }

        // ── 阶段 2：渲染 ────────────────────────────────────────────────
        ProcessingTrace.mark(.rendering)
        progress(0.5)

        let defaultUTI = isRaw ? settings.rawOutputUTI : sourceUTI
        // 容器决策（需求第十二节 HEIC 条目）：用户勾选「输出 PNG 无损」且源为 HEIC/HEIF 时，
        // 输出 public.png —— 无损、保 alpha、位深不降（10bit 源仍走 16bpc 中间画布）。
        // 默认 false 时行为与 v1.1 一致（原 UTI 写回）。
        let targetUTI = Self.resolvedOutputUTI(defaultUTI: defaultUTI,
                                               sourceUTI: sourceUTI,
                                               settings: settings)
        let encoded = try Self.encodeStill(
            decoded: decoded,
            sourceProperties: sourceProperties,
            sourceUTI: sourceUTI,
            targetUTI: targetUTI,
            bitDepthHint: info.bitDepth,
            config: config,
            compositor: compositor,
            settings: settings
        )

        // ── 阶段 4：写入（产物在内存，无需落盘）────────────────────────
        ProcessingTrace.mark(.writing)
        progress(1)

        return .stillImage(data: encoded, uti: targetUTI)
    }

    // MARK: - 输出容器决策

    /// PNG 容器 UTI。
    static let pngUTI = "public.png"

    /// 源是否为 HEIC/HEIF 家族（仅这两类才允许被用户勾选改成 PNG）。
    static func isHEIFFamily(_ uti: String) -> Bool {
        let lower = uti.lowercased()
        return lower.contains("heic") || lower.contains("heif")
    }

    /// 实际输出容器。
    ///
    /// 为什么只放行 HEIC/HEIF：
    /// - JPEG/TIFF/BMP/WebP 源本身就是有损或与 PNG 语义差异大（WebP 动图另有处理器），
    ///   用户勾选「规避 HEIC 二次编码损失」时这些源没有对应收益；
    /// - RAW/DNG 走 `rawOutputUTI`（HEIC），其 sourceUTI 是 DNG，天然落在放行条件外，
    ///   不会被意外改成 PNG；
    /// - Live Photo 静帧不走本函数（LivePhotoProcessor 直接给定 stillUTI）——
    ///   `.pairedVideo` 只接受 HEIC/JPEG 静帧，改成 PNG 会导致系统无法重建 Live Photo。
    static func resolvedOutputUTI(defaultUTI: String,
                                  sourceUTI: String,
                                  settings: ProcessingSettings) -> String {
        guard settings.outputLosslessPNG, isHEIFFamily(sourceUTI) else { return defaultUTI }
        return pngUTI
    }

    // MARK: - 静止图合成+编码（照片管线唯一实现，Live Photo 静帧复用）

    /// 解码后的单帧 → 方向烘焙 → （10bit 拓宽）→ compositedFrame → 原格式编码。
    ///
    /// 供 `PhotoProcessor.process` 与 `LivePhotoProcessor` 共用：
    /// Live Photo 静帧与本管线一字不差（只是多注入 MakerApple key 17），
    /// 避免两条实现漂移出「Live 静帧画质/元数据与普通照片不一致」的缺陷。
    ///
    /// - Parameters:
    ///   - bitDepthHint: `AssetFormatInfo.bitDepth`（10bit 保真判断用）。
    ///   - makerAppleAssetIdentifier: 非 nil 时写入 MakerApple key 17（Live Photo 配对）。
    static func encodeStill(decoded: CGImage,
                            sourceProperties: [String: Any]?,
                            sourceUTI: String,
                            targetUTI: String,
                            bitDepthHint: Int,
                            config: WatermarkConfig,
                            compositor: WatermarkCompositor,
                            settings: ProcessingSettings,
                            makerAppleAssetIdentifier: String? = nil) throws -> Data {

        let orientation = EXIFPreserver.orientation(from: sourceProperties)
        let oriented = EXIFPreserver.bakeOrientation(decoded, orientation: orientation)
        let displaySize = CGSize(width: oriented.width, height: oriented.height)

        let base = widenIfNeeded(oriented,
                                 sourceBitDepth: bitDepthHint,
                                 targetUTI: targetUTI)

        // 与预览同一入口（契约要点②）：照片恒传 seconds = nil。
        let rendered = try compositor.compositedFrame(
            base: base,
            config: config,
            outputPixelSize: displaySize,
            seconds: nil
        )

        ProcessingTrace.mark(.encoding)

        var properties: [String: Any]
        if let makerAppleAssetIdentifier {
            properties = LivePhotoPairer.stillProperties(
                source: sourceProperties,
                pixelSize: displaySize,
                assetIdentifier: makerAppleAssetIdentifier
            )
        } else {
            properties = EXIFPreserver.outputProperties(
                source: sourceProperties,
                outputPixelSize: displaySize
            )
        }

        do {
            return try EXIFPreserver.encode(rendered,
                                            uti: targetUTI,
                                            properties: properties,
                                            settings: settings)
        } catch {
            // PNG 分支：尽力写，不中止任务。
            // 完整属性字典被 ImageIO 拒绝时退到最小属性集（尺寸/方向/位深）继续编码，
            // 丢掉的分组由产物实测审计（EXIFPreserver.pngMissingMetadataGroups）列出，
            // 经 BatchQueue.pngNote 写进批次日志与导出记录——用户看得见，不是静默丢弃。
            // 反例（不做）：因为「源含 EXIF」就抛错。iPhone HEIC 必然带 EXIF，
            // 那样等于让 PNG 开关 100% 失败，是静默废功能。
            if targetUTI.lowercased().contains("png") {
                let minimal = EXIFPreserver.outputProperties(source: nil,
                                                             outputPixelSize: displaySize)
                return try EXIFPreserver.encode(rendered,
                                                uti: targetUTI,
                                                properties: minimal,
                                                settings: settings)
            }
            // 仅「格式转换」场景（RAW/DNG → HEIC）允许退化：
            // 源字典里的 DNG 私有 TIFF 标签会被 HEIC 编码器拒绝，此时只保留尺寸/方向等基础键，
            // 不减质量、不缩放。原格式写回（source == target）时一律直接上抛，绝不静默降级。
            guard targetUTI.lowercased() != sourceUTI.lowercased() else { throw error }
            let minimal = EXIFPreserver.outputProperties(source: nil, outputPixelSize: displaySize,
                                                         makerAppleOverrides: makerAppleAssetIdentifier.map {
                                                             [LivePhotoPairer.assetIdentifierKey: $0]
                                                         })
            return try EXIFPreserver.encode(rendered,
                                            uti: targetUTI,
                                            properties: minimal,
                                            settings: settings)
        }
    }

    // MARK: - 位深保真

    /// 高位深（≥10bit）素材在写回 HEIC/PNG 前提升到 16bpc 中间画布。
    ///
    /// 为什么需要：`WatermarkCompositor.composite` 按 `base.bitsPerComponent >= 16` 决定
    /// CIFormat（RGBA16 / RGBA8）。若把 8bpc 的 CGImage 直接交给它，输出必然是 RGBA8，
    /// HEIC 10bit 的位深会在这里塌陷。
    ///
    /// PNG 分支：PNG 支持 16bit/通道，用户勾选「输出 PNG 无损」时同样必须拓宽，
    /// 否则 10bit 源会被 8bpc 画布压成 8bit（无损容器却丢了位深，属严重违规）。
    ///
    /// 代价：一次同尺寸、同色彩空间、无插值的位深拓宽（无缩放、无色彩转换）。
    /// 局限：若系统解码阶段已把 10bit 压成 8bit，本函数无法恢复——需在 Mac 端用真实
    /// 10bit HEIC 验证 `kCGImagePropertyDepth`（已列入验收清单）。
    static func widenIfNeeded(_ image: CGImage,
                              sourceBitDepth: Int,
                              targetUTI: String) -> CGImage {
        let uti = targetUTI.lowercased()
        let targetSupportsHighDepth = uti.contains("heic") || uti.contains("heif") || uti.contains("png")
        guard targetSupportsHighDepth,
              sourceBitDepth >= 10,
              image.bitsPerComponent < 16 else { return image }

        let width = image.width, height = image.height
        let colorSpace = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let alphaInfo: CGImageAlphaInfo = image.alphaInfo == .none ? .noneSkipLast : image.alphaInfo
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 16,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: alphaInfo.rawValue
        ) else { return image }

        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }
}
