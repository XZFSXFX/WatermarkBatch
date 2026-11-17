//
//  AudioPassthrough.swift
//  WatermarkBatch（水印工坊 BatchMark）
//
//  块B · 音频/元数据直通（§六.3 音频 passthrough 红线）
//
//  做法：
//  - Reader：`AVAssetReaderTrackOutput(track:outputSettings: nil)` → 输出**压缩** CMSampleBuffer；
//  - Writer：`AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: 源格式)`；
//  - `append(sampleBuffer)` 原样写入：不重编码、不改采样率、不改声道数、不改 PTS。
//
//  为什么不能给 audio input 设 outputSettings：一旦设置，AVAssetWriter 会重编码音频
//  （AAC→AAC 二次压缩，或 PCM 重采样），直接违反「音频流比特级 passthrough」。
//
//  元数据轨直通（Live Photo 的 still-image-time 必需）：元数据轨不能用 track output 直接读，
//  必须走 `AVAssetReaderOutputMetadataAdaptor` + `AVAssetWriterInputMetadataAdaptor`。
//  这条轨丢了，Live Photo 仍可能播放但「关键帧时刻」标记丢失，系统行为不稳定，故必须拷。
//

import AVFoundation
import CoreMedia
import Foundation

enum AudioPassthrough {

    // MARK: - 音频写入端

    /// 构造直通音频输入。
    ///
    /// - Throws: 源轨缺少 formatDescription（无法直通）或容器不兼容时抛 unsupportedFormat，
    ///   绝不静默丢音轨——「视频没有声音」属于 P0 缺陷。
    static func makeWriterInput(for track: AVAssetTrack) async throws -> AVAssetWriterInput {
        let descriptions = try await track.load(.formatDescriptions)
        guard let description = descriptions.first else {
            throw WatermarkError.unsupportedFormat("音频轨缺少格式描述，无法直通")
        }
        let input = AVAssetWriterInput(mediaType: .audio,
                                       outputSettings: nil,
                                       sourceFormatHint: description)
        input.expectsMediaDataInRealTime = false
        return input
    }

    /// 读取端：outputSettings = nil 时输出压缩样本（passthrough 的前提）。
    static func makeReaderOutput(for track: AVAssetTrack) -> AVAssetReaderTrackOutput {
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        return output
    }

    // MARK: - 元数据轨直通（Live Photo still-image-time）

    /// 构造元数据写入端。
    /// - Parameter formatDescription: 源元数据轨的格式描述（保 mdta 键表，sample 才能被解析）。
    static func makeMetadataWriterInput(formatDescription: CMFormatDescription?) -> AVAssetWriterInput {
        let input = AVAssetWriterInput(mediaType: .metadata,
                                       outputSettings: nil,
                                       sourceFormatHint: formatDescription)
        input.expectsMediaDataInRealTime = false
        return input
    }

    static func makeMetadataReaderAdaptor(for track: AVAssetTrack) -> AVAssetReaderOutputMetadataAdaptor {
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        return AVAssetReaderOutputMetadataAdaptor(assetReaderTrackOutput: output)
    }

    /// 源元数据轨的格式描述（可能为 nil，此时 writer 仍可建但键表需由 sample 自带）。
    static func metadataFormatDescription(of track: AVAssetTrack) async -> CMFormatDescription? {
        let descriptions = try? await track.load(.formatDescriptions)
        return descriptions?.first
    }
}
