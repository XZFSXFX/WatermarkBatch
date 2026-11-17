//
//  LivePhotoProcessor.swift
//  WatermarkBatch（水印工坊 BatchMark）
//
//  块B · Live Photo 处理器（拆解 → 分别加水印 → 重配对）
//  契约：`struct LivePhotoProcessor: AssetProcessor`（§4，签名一字不改）
//
//  流程（§六.7）：
//  ① `PhotoLibraryService.livePhotoPair` 拆出 still 字节 + paired MOV（字节级直拷，不重封装）；
//  ② still 走「照片管线」（与 PhotoProcessor 同一实现：方向烘焙 / 0 缩放 / 原 UTI / 质量 1.0），
//     仅多注入 MakerApple key 17 = 新 assetIdentifier；
//  ③ MOV 走「视频管线」（同编码器 / 码率 max(源×1.3, 推荐) / 音频直通 / 保留 still-image-time 元数据轨），
//     并把 `com.apple.quicktime.content.identifier` 写成同一个 assetIdentifier；
//  ④ 自检：still 的 key 17 回读一致 + MOV 的 content identifier 回读一致
//     + `PHLivePhoto.request` 判定可播放。任一失败即抛错，绝不写库（绝不产出残缺资产、绝不降级为静图）。
//
//  产物 = `.livePhoto(stillData:stillUTI:videoURL:)`，由 ExportService 在同一个
//  PHAssetCreationRequest 内以 (.photo, .pairedVideo) 双资源写入，相册长按即可播放。
//

import CoreGraphics
import Foundation
import ImageIO

struct LivePhotoProcessor: AssetProcessor {

    // MARK: 契约

    let kind: MediaKind = .livePhoto

    // MARK: 参数

    private let settings: ProcessingSettings

    init(settings: ProcessingSettings = .qualityFirst) {
        self.settings = settings
    }

    // MARK: 主流程

    func process(asset: LibraryAsset,
                 config: WatermarkConfig,
                 library: PhotoLibraryService,
                 compositor: WatermarkCompositor,
                 progress: @Sendable @escaping (Double) -> Void) async throws -> ProcessedOutput {

        let displayName = asset.originalFilename ?? asset.assetIdentifier

        // ── 阶段 1：读取（拆解）───────────────────────────────────────
        ProcessingTrace.mark(.reading)
        progress(0)

        let pair = try await library.livePhotoPair(for: asset) { fraction in
            progress(fraction * 0.3)
        }
        // Live Photo 的位深/色彩信息从 still 探测（静帧与动段同源）。
        let formatInfo = try? await library.formatInfo(for: asset)
        try Task.checkCancellation()

        guard let source = CGImageSourceCreateWithData(
            pair.stillData as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ) else {
            PhotoLibraryService.removeTemporaryFile(at: pair.videoURL)
            throw WatermarkError.unsupportedFormat("Live Photo 静帧数据无法解析（\(displayName)）")
        }
        guard let decoded = CGImageSourceCreateImageAtIndex(
            source, 0,
            [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        ) else {
            PhotoLibraryService.removeTemporaryFile(at: pair.videoURL)
            throw WatermarkError.unsupportedFormat("Live Photo 静帧解码失败（\(displayName)）")
        }

        let stillUTI = (CGImageSourceGetType(source) as String?) ?? pair.stillUTI
        let stillProperties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]

        // 新配对的唯一标识（still 与 MOV 必须完全一致）。
        let assetIdentifier = LivePhotoPairer.makeAssetIdentifier()

        // ── 阶段 2/3：静帧合成 + 编码 ─────────────────────────────────
        ProcessingTrace.mark(.rendering)
        progress(0.32)

        let stillData = try PhotoProcessor.encodeStill(
            decoded: decoded,
            sourceProperties: stillProperties,
            sourceUTI: stillUTI,
            targetUTI: stillUTI,          // Live Photo 静帧必须原格式（HEIC→HEIC / JPEG→JPEG）
            bitDepthHint: formatInfo?.bitDepth ?? 8,
            config: config,
            compositor: compositor,
            settings: settings,
            makerAppleAssetIdentifier: assetIdentifier
        )

        // 自检 1：ImageIO 是否真的把 MakerApple key 17 写进了新静帧。
        guard LivePhotoPairer.readAssetIdentifier(fromStillData: stillData) == assetIdentifier else {
            PhotoLibraryService.removeTemporaryFile(at: pair.videoURL)
            throw WatermarkError.writeFailed("Live Photo 静帧写入 MakerApple 配对标识失败（\(displayName)）")
        }
        progress(0.4)

        // ── 阶段 2/3：动段视频合成 + 编码 ─────────────────────────────
        let outputURL = ProcessingTempFile.makeURL(extension: "mov")
        do {
            try await VideoWatermarkPipeline.run(
                sourceURL: pair.videoURL,
                destinationURL: outputURL,
                config: config,
                compositor: compositor,
                options: VideoWatermarkPipeline.Options(
                    fileType: .mov,
                    contentIdentifier: assetIdentifier,
                    preserveMetadataTracks: true,
                    settings: settings
                )
            ) { fraction in
                progress(0.4 + fraction * 0.55)
            }
        } catch {
            PhotoLibraryService.removeTemporaryFile(at: outputURL)
            PhotoLibraryService.removeTemporaryFile(at: pair.videoURL)
            throw error
        }

        // 自检 2：配对 MOV 的 content identifier 必须与静帧 key 17 一致。
        guard let writtenIdentifier = await LivePhotoPairer.readContentIdentifier(from: outputURL),
              writtenIdentifier == assetIdentifier else {
            PhotoLibraryService.removeTemporaryFile(at: outputURL)
            PhotoLibraryService.removeTemporaryFile(at: pair.videoURL)
            throw WatermarkError.writeFailed("配对视频缺少 content identifier 或与静帧不一致（\(displayName)）")
        }

        // 自检 3：系统能否组成可播放 Live Photo。
        let playable = await LivePhotoPairer.verifyPlayable(
            stillData: stillData,
            stillUTI: stillUTI,
            videoURL: outputURL
        )
        guard playable else {
            PhotoLibraryService.removeTemporaryFile(at: outputURL)
            PhotoLibraryService.removeTemporaryFile(at: pair.videoURL)
            throw WatermarkError.writeFailed("Live Photo 重配对自检失败：系统无法识别为可播放 Live Photo（\(displayName)）")
        }

        // ── 阶段 4：收尾 ──────────────────────────────────────────────
        ProcessingTrace.mark(.writing)
        PhotoLibraryService.removeTemporaryFile(at: pair.videoURL)   // 源临时 MOV 用完即删
        progress(1)

        return .livePhoto(stillData: stillData, stillUTI: stillUTI, videoURL: outputURL)
    }
}
