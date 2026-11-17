//
//  AssetFormatInfo.swift
//  WatermarkBatch（水印工坊 BatchMark）
//
//  块A · 原始格式探测结构
//  契约来源：《03-技术研发方案》§4【接口契约】—— 签名与契约一字不改。
//  用途：EXIF 保留与处理器分流依据（块B 据此决定原编码器写回 / RAW→HEIC 门禁 /
//  视频 Writer 配置），探测实现位于 PhotoLibraryService.formatInfo(for:)。
//

import Foundation

/// 单个素材的原始格式信息。
struct AssetFormatInfo: Sendable, Equatable {
    /// 原始 UTI（统一类型标识符），如 "public.heic"、"public.jpeg"、"public.png"、"public.camera-raw-image"。
    /// 导出时按原 UTI 选择编码器——禁止把 HEIC 偷换成 JPEG、PNG 偷换成位图（无损支柱）。
    let uti: String
    /// 位深（每分量比特数）：EXIF/位深保留的验收字段（PRD F-18）。
    let bitDepth: Int
    /// 色彩空间名（如 "sRGB IEC61966-2.1"、"Display P3"；视频取色彩原语如 BT.2020/HLG）。
    let colorSpaceName: String?
    /// 视频轨编码器 fourCC（hvc1/avc1 等）；图片类为 nil。
    /// 视频 Writer 与源同编码器 + profile/level ≥ 源（§六.2）的依据。
    let codec: String?
}
