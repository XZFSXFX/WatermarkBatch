//
//  WatermarkCompositor.swift
//  WatermarkBatch（水印工坊 BatchMark）
//
//  块A · 渲染合成核心（§4 接口契约签名一字不改）
//
//  红线（§六 性能硬指标）：
//  ① 全局唯一 CIContext(Metal)，批量共享渲染上下文，创建开销只付一次；
//  ② 合成全部走 Core Image + Metal GPU，严禁 CPU 逐像素；
//  ③ 画布永远 = 底图原始像素尺寸，严禁缩到屏幕尺寸；预览由调用方决定是否传入降采样底图
//     （预览传缩放后的 outputPixelSize 与同一归一化坐标 → 几何与导出完全一致，所见即所得）；
//  ④ 水印层按 (content, outputPixelSize) 缓存复用，拖动/逐帧导出仅重跑 GPU 合成（毫秒级）。
//
//  预览与导出统一走 compositedFrame —— 同管线由代码结构保证（契约要点②）。
//

import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import Metal

final class WatermarkCompositor: @unchecked Sendable {
    static let shared = WatermarkCompositor()   // 全局唯一 CIContext(Metal)，批量共享渲染上下文
    private init() {}

    // MARK: - pt→px 基准（单一事实源，UI/预览/导出共用）

    /// pt→px 换算基准：水印的 pt 参数（字号/描边/阴影等）按「照片以 390pt 宽画布显示」的
    /// 相对比例换算为输出像素——`pixelsPerPoint = outputPixelSize.width / 390`。
    /// 预览链路传入降采样后的 outputPixelSize，与导出链路同一公式：
    /// 同一 config 在预览与导出中的相对大小/位置完全一致（几何所见即所得）。
    /// 块C UI 若需在屏上换算 pt，必须引用本常量/本公式，禁止自造第二基准。
    static let canvasReferenceWidthPoints: CGFloat = 390

    static func pixelsPerPoint(for outputPixelSize: CGSize) -> CGFloat {
        guard outputPixelSize.width > 0 else { return 1 }
        return outputPixelSize.width / canvasReferenceWidthPoints
    }

    // MARK: - 共享渲染上下文

    /// Metal 共享上下文。CIContext 线程安全（Apple 文档），批处理 3-4 并发共用。
    private let ciContext: CIContext = {
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device)
        }
        // iOS 17 支持的全部设备均有 Metal；此兜底仅防极端环境崩溃（软渲染仍非用户级逐像素代码）。
        return CIContext()
    }()

    // MARK: - 水印层缓存（锁保护的小容量缓存；不引入 Hashable，遵守契约 conformance）

    /// 缓存条目：以 `WatermarkContent`（Equatable）+ outputPixelSize 联合判定命中，
    /// 不给契约类型添加 Hashable（契约遵循列表一字不改）。
    private struct LayerCacheEntry {
        let content: WatermarkContent
        let outputPixelSize: CGSize
        let image: CGImage
        let lastUsed: Date
    }

    private var layerCache: [LayerCacheEntry] = []
    private let cacheLock = NSLock()
    /// 小容量：批量场景同一批次分辨率高度集中（通常 1-2 个 key），8 个槽位足够覆盖
    /// 「预览尺寸 + 导出尺寸 + 多分辨率混批」；线性查找成本低且避免哈希/去重复杂度。
    private let maxCachedLayerCount = 8

    private func cachedLayer(_ content: WatermarkContent, _ size: CGSize) -> CGImage? {
        cacheLock.lock(); defer { cacheLock.unlock() }
        guard let idx = layerCache.firstIndex(where: {
            $0.content == content && $0.outputPixelSize == size
        }) else { return nil }
        let hit = layerCache.remove(at: idx)
        layerCache.append(LayerCacheEntry(content: hit.content, outputPixelSize: hit.outputPixelSize,
                                          image: hit.image, lastUsed: Date()))
        return hit.image
    }

    private func storeLayer(_ content: WatermarkContent, _ size: CGSize, _ image: CGImage) {
        cacheLock.lock(); defer { cacheLock.unlock() }
        layerCache.append(LayerCacheEntry(content: content, outputPixelSize: size,
                                          image: image, lastUsed: Date()))
        while layerCache.count > maxCachedLayerCount {
            // 淘汰最久未使用
            if let oldest = layerCache.firstIndex(where: {
                $0.lastUsed == layerCache.map(\.lastUsed).min()
            }) {
                layerCache.remove(at: oldest)
            } else {
                layerCache.removeFirst()
            }
        }
    }

    // MARK: - 契约 API①：水印层生成

    /// 生成水印层位图（应用字色/描边/阴影/不透明度/字间距，PNG 保 alpha），不含 placement 几何。
    /// outputPixelSize 用于字号 pt→px 换算与 scale 基准；同一 config 结果内部缓存，避免逐帧重建。
    func watermarkLayerImage(for content: WatermarkContent,
                             outputPixelSize: CGSize) throws -> CGImage {
        if let hit = cachedLayer(content, outputPixelSize) {
            return hit
        }
        let image: CGImage
        switch content {
        case .text(let textConfig):
            // 文字层按目标分辨率矢量光栅化（不缩放已有位图）
            image = try WatermarkTextRenderer.render(
                config: textConfig,
                pixelsPerPoint: Self.pixelsPerPoint(for: outputPixelSize)
            )
        case .image(let imageWatermark):
            // Logo：原始像素与 alpha 原样保留，不做任何缩放/色彩转换
            image = try Self.decodeImageWatermark(imageWatermark)
        }
        storeLayer(content, outputPixelSize, image)
        return image
    }

    /// 解码 PNG Logo：CGImageSource 直接解码（kCGImageSourceShouldCache=false，任务级不重复占用缓存），
    /// 不缩放、不改色彩空间、保 alpha。
    private static func decodeImageWatermark(_ watermark: ImageWatermark) throws -> CGImage {
        guard watermark.pixelSize.width > 0, watermark.pixelSize.height > 0 else {
            throw WatermarkError.renderFailed("Logo 像素尺寸非法")
        }
        guard let source = CGImageSourceCreateWithData(
            watermark.pngData as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ) else {
            throw WatermarkError.renderFailed("Logo PNG 数据无法解码")
        }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw WatermarkError.renderFailed("Logo 首帧解码失败")
        }
        return image
    }

    // MARK: - 契约 API②：几何合成（GPU）

    /// 将 base 与水印层按 placement（位置/缩放/旋转/平铺/安全区吸附）合成，返回同尺寸 CGImage。
    /// 画布 = base 原始像素尺寸；全分辨率 GPU 输出，绝无降采样。
    func composite(base: CGImage,
                   watermark: CGImage,
                   config: WatermarkConfig,
                   outputPixelSize: CGSize) throws -> CGImage {
        let W = CGFloat(base.width)
        let H = CGFloat(base.height)
        guard W > 0, H > 0 else {
            throw WatermarkError.renderFailed("底图尺寸非法")
        }
        guard config.placement.scaleNormalized > 0 else {
            throw WatermarkError.renderFailed("水印缩放比例必须大于 0")
        }

        let baseCI = CIImage(cgImage: base)
        let wmCI = CIImage(cgImage: watermark)
        let layerSize = CGSize(width: CGFloat(watermark.width), height: CGFloat(watermark.height))

        // 水印层目标长边 = scaleNormalized × 输出短边（契约定义）
        let targetLongSide = config.placement.scaleNormalized * min(W, H)

        let composited: CIImage
        if config.tiling.isEnabled {
            composited = Self.tiledLayer(
                wmCI, layerSize: layerSize, targetLongSide: targetLongSide,
                config: config, canvasSize: CGSize(width: W, height: H)
            )
        } else {
            let (centerX, centerY) = Self.snappedCenter(
                config: config, layerSize: layerSize,
                scale: Self.uniformScale(forLayer: layerSize, targetLongSide: targetLongSide),
                canvasSize: CGSize(width: W, height: H)
            )
            let placed = Self.placedLayer(
                wmCI, layerSize: layerSize, config: config,
                scale: Self.uniformScale(forLayer: layerSize, targetLongSide: targetLongSide),
                // 坐标系边界：模型与 snappedCenter 都在「左上角原点、Y 向下」（UIKit）里算，
                // 而 CI 画布 Y 向上。必须在进入仿射变换前翻转一次——
                // 否则 centerYNormalized=0.9（语义：贴底）会被渲染到贴顶，九宫格的「底部」跑到最上面。
                center: (x: centerX, y: H - centerY)
            )
            composited = placed.composited(over: baseCI)
        }

        // 输出位深跟随底图：≥16bpc 用 RGBA16，避免高位深素材被压到 8bit（无损支柱）；
        // 色彩空间原样保留（base.colorSpace，如 Display P3）。
        let format: CIFormat = base.bitsPerComponent >= 16 ? .RGBA16 : .RGBA8
        let colorSpace = base.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let canvasRect = CGRect(x: 0, y: 0, width: W, height: H)
        guard let out = ciContext.createCGImage(composited, from: canvasRect,
                                                format: format, colorSpace: colorSpace) else {
            throw WatermarkError.renderFailed("Core Image 输出位图失败")
        }
        return out
    }

    /// 等比缩放系数：水印层长边缩放到 targetLongSide。
    private static func uniformScale(forLayer layerSize: CGSize, targetLongSide: CGFloat) -> CGFloat {
        targetLongSide / max(layerSize.width, layerSize.height)
    }

    /// 单水印的仿射变换：缩放到目标长边 → 旋转（正角度=画面顺时针，UIKit 语义；
    /// CI 坐标 Y 向上故取 -θ）→ 平移到吸附后的中心。
    /// `center` 必须是 **CI 坐标（Y 向上）**，调用方负责从 UIKit 坐标翻转后再传入。
    /// CGAffineTransform: a.concatenating(b) 先应用 b 再应用 a。
    private static func placedLayer(_ wmCI: CIImage,
                                    layerSize: CGSize,
                                    config: WatermarkConfig,
                                    scale: CGFloat,
                                    center: (x: CGFloat, y: CGFloat)) -> CIImage {
        let theta = config.placement.rotationDegrees * .pi / 180
        let transform = CGAffineTransform(translationX: center.x, y: center.y)
            .concatenating(CGAffineTransform(rotationAngle: -theta))
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: -layerSize.width / 2, y: -layerSize.height / 2))
        return wmCI.transformed(by: transform)
    }

    /// 安全区吸附（PRD F-08）：水印旋转外接框的任一边距画布边 < safeMarginNormalized×对应边长时，
    /// 吸附至「边距 = 阈值」。与 UI 手势层同一公式（双保险）；平铺模式不参与。
    /// 坐标系：左上角原点、Y 向下（UIKit 习惯）。
    private static func snappedCenter(config: WatermarkConfig,
                                      layerSize: CGSize,
                                      scale: CGFloat,
                                      canvasSize: CGSize) -> (CGFloat, CGFloat) {
        let W = canvasSize.width, H = canvasSize.height
        let w = layerSize.width * scale, h = layerSize.height * scale
        let theta = config.placement.rotationDegrees * .pi / 180
        // 旋转后的轴对齐外接框
        let bw = abs(w * cos(theta)) + abs(h * sin(theta))
        let bh = abs(w * sin(theta)) + abs(h * cos(theta))

        let marginX = config.safeMarginNormalized * W
        let marginY = config.safeMarginNormalized * H
        var cx = config.placement.centerXNormalized * W
        var cy = config.placement.centerYNormalized * H

        if cx - bw / 2 < marginX {
            cx = marginX + bw / 2
        } else if cx + bw / 2 > W - marginX {
            cx = W - marginX - bw / 2
        }
        if cy - bh / 2 < marginY {
            cy = marginY + bh / 2
        } else if cy + bh / 2 > H - marginY {
            cy = H - marginY - bh / 2
        }
        // 防御性夹取：水印比画布大时保证中心仍落在画布内
        cx = min(max(cx, 0), W)
        cy = min(max(cy, 0), H)
        return (cx, cy)
    }

    /// 平铺模式（PRD F-10，v2.0）：无限平铺水印层。
    /// 实现：缩放+旋转单个水印 → 放入「外接框+间距」的透明瓦片画布（保证旋转后的字形
    /// 绝不跨越瓦片边界）→ CIAffineTile 无限重复 → 相位平移使画布中心恒有水印 → 裁回画布。
    private static func tiledLayer(_ wmCI: CIImage,
                                   layerSize: CGSize,
                                   targetLongSide: CGFloat,
                                   config: WatermarkConfig,
                                   canvasSize: CGSize) -> CIImage {
        let scale = uniformScale(forLayer: layerSize, targetLongSide: targetLongSide)
        let w = layerSize.width * scale, h = layerSize.height * scale
        let theta = config.tiling.rotationDegrees * .pi / 180
        let gap = config.tiling.spacingNormalized * targetLongSide   // 间距 = 比例 × 水印长边（契约定义）

        // 旋转后外接框
        let bw = abs(w * cos(theta)) + abs(h * sin(theta))
        let bh = abs(w * sin(theta)) + abs(h * cos(theta))
        let tileW = bw + gap, tileH = bh + gap

        // 缩放 → 绕自身中心旋转 → 置于瓦片画布中心（旋转内容必然完整落在瓦片内）
        let intoTile = CGAffineTransform(translationX: tileW / 2, y: tileH / 2)
            .concatenating(CGAffineTransform(rotationAngle: -theta))
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: -layerSize.width / 2, y: -layerSize.height / 2))
        let tile = wmCI.transformed(by: intoTile)
            .cropped(to: CGRect(x: 0, y: 0, width: tileW, height: tileH))

        // 无限平铺
        guard let tileFilter = CIFilter(name: "CIAffineTile") else {
            // 系统滤镜缺失属于不可恢复环境问题；回退单水印而非崩溃
            return placedLayer(wmCI, layerSize: layerSize, config: config,
                               scale: scale, center: (x: canvasSize.width / 2, y: canvasSize.height / 2))
        }
        tileFilter.setValue(tile, forKey: kCIInputImageKey)
        tileFilter.setValue(CGAffineTransform.identity, forKey: kCIInputTransformKey)
        let lattice = (tileFilter.outputImage ?? tile)
            // 相位平移：保证画布中心位置恒有水印（视觉居中起点）
            .transformed(by: CGAffineTransform(
                translationX: canvasSize.width / 2 - tileW / 2,
                y: canvasSize.height / 2 - tileH / 2
            ))
        return lattice.cropped(to: CGRect(x: 0, y: 0, width: canvasSize.width, height: canvasSize.height))
    }

    // MARK: - 契约 API③：预览与导出统一入口

    /// 预览与导出统一入口。seconds 为素材当前时间（视频/Live 视频段）；
    /// nil 或落在 timeRange 外且非全程时返回不带水印的 base（downscale 由调用方决定）。
    /// 照片/GIF 恒传 nil。
    ///
    /// 时间可见性判定：
    /// - seconds == nil（照片/GIF，无时间轴概念）→ 恒显示水印；
    /// - timeRange == nil → 全程显示水印；
    /// - 两者均非 nil → 仅当 timeRange.contains(seconds) 显示。
    func compositedFrame(base: CGImage,
                         config: WatermarkConfig,
                         outputPixelSize: CGSize,
                         seconds: TimeInterval?) throws -> CGImage {
        let showWatermark: Bool
        if let range = config.timeRange, let t = seconds {
            showWatermark = range.contains(t)
        } else {
            // seconds 为 nil（照片/GIF）或 timeRange 为 nil（全程）→ 恒显示
            showWatermark = true
        }
        guard showWatermark else {
            return base
        }
        let layer = try watermarkLayerImage(for: config.content, outputPixelSize: outputPixelSize)
        return try composite(base: base, watermark: layer,
                             config: config, outputPixelSize: outputPixelSize)
    }
}
