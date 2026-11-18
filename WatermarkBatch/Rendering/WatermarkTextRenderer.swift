//
//  WatermarkTextRenderer.swift
//  WatermarkBatch（水印工坊 BatchMark）
//
//  块A · CoreText 文字水印层渲染器
//  职责：字色/描边/阴影/不透明度/字间距（8 参数，PRD F-04）→ 带透明通道的 CGImage。
//  红线：文字为矢量，按目标分辨率直接光栅化，绝不做像素降采样；输出位图保留 alpha
//  （premultiledLast 8bpc），交由 Core Image GPU 合成——禁止 CPU 逐像素处理（§六.1-④）。
//

import CoreGraphics
import CoreText
import Foundation

/// 无状态渲染器（enum 命名空间，线程安全）。
enum WatermarkTextRenderer {

    /// 文字层任一边的最大像素数（iOS 17 全部支持设备 Metal 纹理上限 ≥16384；防御超长文本）。
    static let maxLayerPixels = 16_384

    // MARK: - 入口

    /// 生成文字水印层位图。
    ///
    /// - Parameters:
    ///   - config: 文字 8 参数配置。
    ///   - pixelsPerPoint: pt→px 换算系数（由 `WatermarkCompositor.pixelsPerPoint(for:)` 统一给出，
    ///     预览与导出同一公式 → 所见即所得）。
    /// - Returns: 带透明通道的水印层 CGImage，紧贴字形 ink 外扩 padding（阴影/描边余量）。
    static func render(config: WatermarkTextConfig, pixelsPerPoint: CGFloat) throws -> CGImage {
        guard !config.text.isEmpty else {
            throw WatermarkError.renderFailed("文字内容为空")
        }
        guard pixelsPerPoint > 0, config.fontSizePt > 0 else {
            throw WatermarkError.renderFailed("字号或 pt→px 换算基准非法")
        }

        let font = resolveFont(name: config.fontName, sizePt: config.fontSizePt)
        let fillColor = try cgColor(fromHex: config.colorHex, alpha: config.opacity)
        let strokeColor = config.strokeEnabled
            ? try cgColor(fromHex: config.strokeColorHex, alpha: config.opacity)
            : nil
        let shadowColor = config.shadowEnabled
            ? try cgColor(fromHex: config.shadowColorHex, alpha: config.opacity)
            : nil

        let attributed = makeAttributedLine(
            text: config.text,
            font: font,
            fillColor: fillColor,
            strokeColor: strokeColor,
            strokeWidthPt: config.strokeWidthPt,
            fontSizePt: config.fontSizePt,
            kernPt: config.letterSpacingPt
        )
        let line = CTLineCreateWithAttributedString(attributed)

        // useOpticalBounds：取字形实际着墨范围（紧贴字形），比排版边界更适合水印层。
        let inkBounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        guard inkBounds.width > 0, inkBounds.height > 0 else {
            throw WatermarkError.renderFailed("文字测量结果为空")
        }

        let pad = padding(for: config)
        let widthPx = Int(((inkBounds.width + pad * 2) * pixelsPerPoint).rounded(.up))
        let heightPx = Int(((inkBounds.height + pad * 2) * pixelsPerPoint).rounded(.up))
        guard widthPx > 0, heightPx > 0,
              widthPx <= maxLayerPixels, heightPx <= maxLayerPixels else {
            throw WatermarkError.renderFailed("水印层尺寸越界（\(widthPx)×\(heightPx)）")
        }

        // premultipliedLast：保留 alpha 通道（PNG Logo/文字层合成必需），8bpc 匹配照片主流位深。
        guard let ctx = CGContext(
            data: nil,
            width: widthPx,
            height: heightPx,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw WatermarkError.renderFailed("文字位图上下文创建失败")
        }

        // 整个上下文按 pt 空间缩放：字号/字间距/描边/阴影模糊半径全部随之缩放，
        // 文字始终矢量光栅化到目标分辨率（预览与导出各自的目标分辨率），无中间缩放副本。
        ctx.scaleBy(x: CGFloat(pixelsPerPoint), y: CGFloat(pixelsPerPoint))

        if let shadowColor {
            // 阴影偏移采用 UIKit 习惯（Y 正值向下）；CG 坐标 Y 向上，故取负。
            // setShadow 的偏移/模糊随 CTM 缩放，pt 语义自动保持。
            ctx.setShadow(
                offset: CGSize(
                    width: config.shadowOffsetPt.width,
                    height: -config.shadowOffsetPt.height
                ),
                blur: config.shadowBlurRadiusPt,
                color: shadowColor
            )
        }

        ctx.textPosition = CGPoint(x: pad - inkBounds.minX, y: pad - inkBounds.minY)
        CTLineDraw(line, ctx)

        guard let image = ctx.makeImage() else {
            throw WatermarkError.renderFailed("文字层位图生成失败")
        }
        return image
    }

    // MARK: - 属性字符串（CoreText 原生 key，非 NS 属性 key）

    /// kCTKern 单位为 pt：正值放大间距（契约语义）。kCTStrokeWidth 为「字号的百分比」且
    /// 负值 = 填充 + 描边一次性完成，故 pt 宽度按 `strokeWidthPt / fontSizePt * 100` 换算为负百分比。
    private static func makeAttributedLine(
        text: String,
        font: CTFont,
        fillColor: CGColor,
        strokeColor: CGColor?,
        strokeWidthPt: CGFloat,
        fontSizePt: CGFloat,
        kernPt: CGFloat
    ) -> CFAttributedString {
        let attributed = CFAttributedStringCreateMutable(kCFAllocatorDefault, 0)!
        CFAttributedStringReplaceString(attributed, CFRange(location: 0, length: 0), text as CFString)
        let whole = CFRange(location: 0, length: CFAttributedStringGetLength(attributed))

        CFAttributedStringSetAttribute(attributed, whole, kCTFontAttributeName, font)
        CFAttributedStringSetAttribute(attributed, whole, kCTForegroundColorAttributeName, fillColor)
        CFAttributedStringSetAttribute(attributed, whole, kCTKernAttributeName,
                                       NSNumber(value: Double(kernPt)))
        if let strokeColor, strokeWidthPt > 0 {
            CFAttributedStringSetAttribute(attributed, whole, kCTStrokeWidthAttributeName,
                                            NSNumber(value: Double(-abs(strokeWidthPt) / fontSizePt * 100)))
            CFAttributedStringSetAttribute(attributed, whole, kCTStrokeColorAttributeName, strokeColor)
        }
        return attributed
    }

    // MARK: - 字体解析

    /// PostScript 名 → CTFont。未命中的名字由 CoreText 自动替换为系统可用字体（不中断批处理）；
    /// 再按序兜底 PingFangSC-Semibold（契约默认字体）与系统字体。
    private static func resolveFont(name: String, sizePt: CGFloat) -> CTFont {
        // CTFontCreateWithName 返回非可选 CTFont：PostScript 名未命中时由 CoreText 自动
        // 替换为可用字体（不中断批处理），因此这里既不需要也无法用条件绑定兜底。
        // 空名退回契约默认字体 PingFangSC-Semibold（iOS 必装，即便缺失也会被自动替换）。
        let resolvedName = name.isEmpty ? "PingFangSC-Semibold" : name
        return CTFontCreateWithName(resolvedName as CFString, sizePt, nil)
    }

    // MARK: - 颜色

    /// "#RRGGBB" / "#RRGGBBAA" → sRGB CGColor；alpha 与 config.opacity 相乘。
    /// 非法色值直接抛错（暴露 UI 层 bug，而不是悄悄换色）。
    static func cgColor(fromHex hex: String, alpha: CGFloat) throws -> CGColor {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8 else {
            throw WatermarkError.renderFailed("颜色值非法：\(hex)")
        }
        var components: [CGFloat] = []
        var idx = s.startIndex
        while idx < s.endIndex {
            let next = s.index(idx, offsetBy: 2)
            guard let v = UInt32(s[idx..<next], radix: 16), v <= 255 else {
                throw WatermarkError.renderFailed("颜色值非法：\(hex)")
            }
            components.append(CGFloat(v) / 255)
            idx = next
        }
        let baseAlpha = components.count == 4 ? components[3] : 1
        return CGColor(
            srgbRed: components[0],
            green: components[1],
            blue: components[2],
            alpha: alpha * baseAlpha
        )
    }

    // MARK: - 余量

    /// ink 外扩 padding：容纳阴影（模糊半径 + 偏移）与描边宽度，避免裁切。
    private static func padding(for config: WatermarkTextConfig) -> CGFloat {
        var pad: CGFloat = 2 // 抗锯齿余量
        if config.shadowEnabled {
            pad = max(
                pad,
                config.shadowBlurRadiusPt
                    + max(abs(config.shadowOffsetPt.width), abs(config.shadowOffsetPt.height))
                    + 1
            )
        }
        if config.strokeEnabled {
            pad = max(pad, abs(config.strokeWidthPt))
        }
        return ceil(pad)
    }
}
