//
//  WatermarkModels.swift
//  WatermarkBatch（水印工坊 BatchMark）
//
//  块A · 水印数据模型层
//  契约来源：《03-技术研发方案》§4【接口契约】—— 本文件所有公开类型签名与契约一字不改；
//  附加内容仅限文档注释与 extension 形式的便捷默认值（供块C UI 新建水印时使用）。
//

import CoreGraphics
import Foundation

// MARK: - 素材类型

/// 素材类型：照片 / Live Photo / 动图（GIF、动画 WebP）/ 视频 / RAW。
enum MediaKind: String, Codable, Sendable, CaseIterable {
    case photo, livePhoto, animated, video, raw
}

// MARK: - 文字水印配置

/// 文字水印全部可调参数（8 参数：内容/字体/字号/颜色/描边/阴影/不透明度/字间距）。
/// 所有长度值的单位均为 pt；pt→px 的换算基准由 `WatermarkCompositor` 统一定义，
/// 预览与导出共用同一公式，保证所见即所得。
struct WatermarkTextConfig: Codable, Sendable, Equatable {
    var text: String
    var fontName: String            // 系统 PostScript 名，如 "PingFangSC-Semibold"
    var fontSizePt: CGFloat
    var colorHex: String            // "#RRGGBB" 或 "#RRGGBBAA"
    var strokeEnabled: Bool
    var strokeColorHex: String
    var strokeWidthPt: CGFloat
    var shadowEnabled: Bool
    var shadowColorHex: String
    var shadowOffsetPt: CGSize      // pt 单位偏移（UIKit 习惯：Y 正值向下）
    var shadowBlurRadiusPt: CGFloat
    var opacity: CGFloat           // 0...1
    var letterSpacingPt: CGFloat   // 正值放大，负值缩小
}

// MARK: - 图片水印

/// 透明 PNG Logo 水印：pngData 原样保留 alpha 通道，pixelSize 为原始像素尺寸。
/// 渲染层解码时不做任何缩放、色彩转换或重新编码；最终大小由 placement 决定。
struct ImageWatermark: Codable, Sendable, Equatable {
    var pngData: Data               // 透明 Logo，保留 alpha
    var pixelSize: CGSize           // 原始像素尺寸
}

// MARK: - 水印内容

/// 水印内容：文字或图片（互斥）。Swift 5.5+ 对带关联值的枚举自动合成 Codable。
enum WatermarkContent: Codable, Sendable, Equatable {
    case text(WatermarkTextConfig)
    case image(ImageWatermark)
}

// MARK: - 位置与几何

/// 水印位置与几何。
/// 归一化坐标一律相对【输出像素】（契约要点①），原点取左上角、Y 向下（UIKit 习惯），
/// UI 拖拽层负责 pt↔px 换算。
struct WatermarkPlacement: Codable, Sendable, Equatable {
    var centerXNormalized: CGFloat // 相对输出像素，0...1
    var centerYNormalized: CGFloat
    var scaleNormalized: CGFloat    // 水印层长边 / 输出短边
    var rotationDegrees: CGFloat    // -360...360，正角度 = 画面上顺时针（与 UIKit 一致）
}

// MARK: - 平铺

/// 平铺（满屏重复水印）配置，v2.0 功能，默认关闭。
struct TilingConfig: Codable, Sendable, Equatable {
    var isEnabled: Bool             // 默认 false（平铺模式默认关闭）
    var spacingNormalized: CGFloat  // 相邻水印间距 / 水印长边，默认 0.5
    var rotationDegrees: CGFloat    // 平铺整体倾角，默认 -30
}

// MARK: - 水印总配置

/// 单条水印的完整配置：内容 + 位置 + 平铺 + 安全区吸附 + 视频时间段。
struct WatermarkConfig: Codable, Sendable, Equatable {
    var content: WatermarkContent
    var placement: WatermarkPlacement
    var tiling: TilingConfig
    var safeMarginNormalized: CGFloat // 安全区吸附阈值，默认 0.03
    var timeRange: ClosedRange<Double>? // 视频显示时间段秒；nil = 全程
}

// MARK: - 模板

/// 可保存/复用的水印模板（PRD F-09），持久化由 `WatermarkTemplateStore` 负责。
struct WatermarkTemplate: Codable, Identifiable, Sendable, Equatable {
    var id: UUID
    var name: String
    var config: WatermarkConfig
    var createdAt: Date
}

// MARK: - 便捷默认值（块C UI 新建水印时使用；不参与契约）

extension WatermarkTextConfig {
    /// 默认文字水印：PingFangSC-Semibold 24pt 白色，无描边/阴影，不透明度 1，字间距 0。
    static func standard(text: String) -> WatermarkTextConfig {
        WatermarkTextConfig(
            text: text,
            fontName: "PingFangSC-Semibold",
            fontSizePt: 24,
            colorHex: "#FFFFFF",
            strokeEnabled: false,
            strokeColorHex: "#000000",
            strokeWidthPt: 2,
            shadowEnabled: false,
            shadowColorHex: "#00000066",
            shadowOffsetPt: CGSize(width: 0, height: 2),
            shadowBlurRadiusPt: 4,
            opacity: 1,
            letterSpacingPt: 0
        )
    }
}

extension WatermarkPlacement {
    /// 默认位置：水平居中、垂直 90%（左上角归一化坐标系），长边占短边 25%，不旋转。
    static var standard: WatermarkPlacement {
        WatermarkPlacement(
            centerXNormalized: 0.5,
            centerYNormalized: 0.9,
            scaleNormalized: 0.25,
            rotationDegrees: 0
        )
    }
}

extension TilingConfig {
    /// 默认平铺配置：关闭（产品默认红线），间距 0.5，倾角 -30（契约注释给定值）。
    static var standard: TilingConfig {
        TilingConfig(
            isEnabled: false,
            spacingNormalized: 0.5,
            rotationDegrees: -30
        )
    }
}

extension WatermarkConfig {
    /// 默认总配置：安全区吸附阈值 0.03，时间段 nil（全程显示）。
    static func standard(content: WatermarkContent) -> WatermarkConfig {
        WatermarkConfig(
            content: content,
            placement: .standard,
            tiling: .standard,
            safeMarginNormalized: 0.03,
            timeRange: nil
        )
    }
}
