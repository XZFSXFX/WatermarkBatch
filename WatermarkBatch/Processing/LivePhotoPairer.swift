//
//  LivePhotoPairer.swift
//  WatermarkBatch（水印工坊 BatchMark）
//
//  块B · Live Photo 重配对（§六.7 / 风险 Top2）
//
//  重配对三件套：
//  ① 新 still（HEIC/JPEG）写入 `kCGImagePropertyMakerAppleDictionary` 的 key "17"
//     = assetIdentifier（大写 UUID 字符串，与系统一致）；
//  ② 新 MOV 写入轨道元数据 `com.apple.quicktime.content.identifier` = 同一 UUID；
//  ③ 产物以 (.photo, .pairedVideo) 两资源进同一个 PHAssetCreationRequest（ExportService 内）。
//
//  另：Live Photo 的 MOV 还带一条「still-image-time」元数据轨（标记关键帧时刻）。
//  该轨在 AVAssetReader/Writer 管线里不会自动保留，故由 VideoProcessor 的管线以
//  `preserveMetadataTracks = true` 显式拷贝（见 VideoProcessor / AudioPassthrough 的元数据直通）。
//
//  自检：写入完成后用 `PHLivePhoto.request(withResourceFileURL:)` 验证可播放性；
//  失败绝不写库（绝不产出残缺资产），错误上抛为 writeFailed。
//

import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import Photos
import UniformTypeIdentifiers

enum LivePhotoPairer {

    /// MakerApple 字典里的 Live Photo 配对键（系统私有但公开可写，Apple 官方 Live Photo 示例同款）。
    static let assetIdentifierKey = "17"

    /// 快速容器元数据键：`com.apple.quicktime.content.identifier`。
    static let contentIdentifierMetadataKey = "com.apple.quicktime.content.identifier"

    // MARK: - 标识符

    /// 生成新的 assetIdentifier（大写 UUID，与系统 Live Photo 一致）。
    static func makeAssetIdentifier() -> String {
        UUID().uuidString.uppercased()
    }

    // MARK: - still 侧：MakerApple key 17

    /// 构造 still 的输出属性：全量透传 + 尺寸修正 + MakerApple key 17。
    static func stillProperties(source: [String: Any]?,
                                pixelSize: CGSize,
                                assetIdentifier: String) -> [String: Any] {
        EXIFPreserver.outputProperties(
            source: source,
            outputPixelSize: pixelSize,
            makerAppleOverrides: [assetIdentifierKey: assetIdentifier]
        )
    }

    /// 从写好的 still 字节里回读 key 17（自检：确认 ImageIO 没把 MakerApple 丢掉）。
    static func readAssetIdentifier(fromStillData data: Data) -> String? {
        guard let source = CGImageSourceCreateWithData(
            data as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ) else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
        return EXIFPreserver.assetIdentifier(from: properties)
    }

    // MARK: - MOV 侧：content identifier 元数据

    /// `AVAssetWriter.metadata` 用的 content identifier 元数据项。
    static func contentIdentifierMetadataItem(_ assetIdentifier: String) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = .quickTimeMetadataContentIdentifier
        item.value = assetIdentifier as NSString
        item.dataType = kCMMetadataBaseDataType_UTF8 as String
        return item
    }

    /// 源 MOV 里已有的 content identifier（诊断/日志用；不同源时以新 UUID 覆盖）。
    static func readContentIdentifier(from url: URL) async -> String? {
        let asset = AVURLAsset(url: url)
        guard let metadata = try? await asset.load(.metadata) else { return nil }
        for item in metadata where item.identifier == .quickTimeMetadataContentIdentifier {
            if let value = item.stringValue, !value.isEmpty { return value }
            if let data = item.value as? Data, let text = String(data: data, encoding: .utf8) {
                return text
            }
        }
        return nil
    }

    // MARK: - 自检：可播放性

    /// 用系统 API 验证「still + paired MOV」能否组成可播放的 Live Photo。
    ///
    /// 系统按两条线索配对：still 内的 MakerApple key 17 与 MOV 的 content identifier，
    /// 以及「同目录同文件名」约定。本方法把两侧按同 basename 落到同一临时目录
    /// （`pair-xxxx.heic` + `pair-xxxx.mov`），两条线索同时满足，验证结果才有意义。
    static func verifyPlayable(stillData: Data,
                               stillUTI: String,
                               videoURL: URL) async -> Bool {
        let ext = UTType(stillUTI)?.preferredFilenameExtension
            ?? (stillUTI.lowercased().contains("heic") ? "heic" : "jpg")
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WatermarkBatch-paircheck-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return false
        }
        defer { try? FileManager.default.removeItem(at: directory) }

        let stillURL = directory.appendingPathComponent("pair").appendingPathExtension(ext)
        let videoCopyURL = directory.appendingPathComponent("pair").appendingPathExtension("mov")
        do {
            try stillData.write(to: stillURL, options: .atomic)
            try FileManager.default.copyItem(at: videoURL, to: videoCopyURL)
        } catch {
            return false
        }

        return await withCheckedContinuation { continuation in
            // PHLivePhoto.request 的正确签名是 withResourceFileURLs（复数、[URL]），
            // 且必须给 placeholderImage / targetSize / contentMode：
            // request(withResourceFileURLs:placeholderImage:targetSize:contentMode:resultHandler:)
            _ = PHLivePhoto.request(
                withResourceFileURLs: [stillURL, videoCopyURL],
                placeholderImage: nil,
                targetSize: .zero,
                contentMode: .aspectFit
            ) { photo, _ in
                continuation.resume(returning: photo != nil)
            }
        }
    }
}
