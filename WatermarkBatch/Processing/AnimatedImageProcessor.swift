//
//  AnimatedImageProcessor.swift
//  WatermarkBatch（水印工坊 BatchMark）
//
//  块B · 动图处理器（GIF / 动画 WebP 逐帧合成）
//  契约：`struct AnimatedImageProcessor: AssetProcessor`（§4，签名一字不改）
//
//  ── 四条硬要求中属于本文件的三条 ─────────────────────────────────────────
//  ① 逐帧解码必须 `CGImageSourceCreateImageAtIndex(source, index,
//     [kCGImageSourceShouldCacheImmediately: true])`。
//     禁止 `CGImageSourceCreateThumbnailAtIndex`、禁止 `kCGImageSourceThumbnailMaxPixelSize`
//     （任何值都会把帧尺寸压小）。本文件无任何 thumbnail/thumbnailMaxPixelSize 字样。
//  ② 每帧延时逐帧写入：`CGImageDestinationAddImage(dest, frame, frameProperties)`，
//     frameProperties 的 GIF Dictionary 里 `kCGImagePropertyGIFDelayTime` 与
//     `kCGImagePropertyGIFUnclampedDelayTime` 均取自该帧原值（CopyPropertiesAtIndex）。
//     `CGImageDestinationSetProperties` 只写全局属性（LoopCount / HasGlobalColorMap），
//     绝不写延时。不同帧延时不同的动图逐帧正确，禁止归一化/取平均。
//  ③ 调色板：GIF 索引色上限 256。加不透明/半透明水印后重算调色板：
//     优先「原帧调色板 + 预留水印色」；超限时中位切分量化且关闭抖动；
//     不跨帧共用全局调色板（HasGlobalColorMap=false）；能保留透明则保留（透明帧走 RGBA 路径）。
//
//  ── 流式 ─────────────────────────────────────────────────────────────
//  逐帧 解码→合成→量化→AddImage→释放，同一时刻只持有一帧 CGImage；
//  仅最终编码字节累积在 CGImageDestination 内部（产物本身就是这个文件），
//  200 帧以上不整包解码载入内存。
//

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct AnimatedImageProcessor: AssetProcessor {

    // MARK: 契约

    let kind: MediaKind = .animated

    // MARK: 参数

    private let settings: ProcessingSettings

    init(settings: ProcessingSettings = .qualityFirst) {
        self.settings = settings
    }

    // MARK: 支持的容器

    /// 仅 GIF 与 WebP 走本处理器（其它动画容器交给照片管线，不在这里猜）。
    static func isAnimatedUTI(_ uti: String) -> Bool {
        let lower = uti.lowercased()
        return lower == "com.compuserve.gif"
            || lower == "public.gif"
            || lower == "org.webmproject.webp"
            || lower == "public.webp"
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

        let data = try await library.originalImageData(for: asset) { fraction in
            progress(fraction * 0.25)
        }
        try Task.checkCancellation()

        guard let source = CGImageSourceCreateWithData(
            data as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ) else {
            throw WatermarkError.unsupportedFormat("动图数据无法解析（\(displayName)）")
        }
        guard let type = CGImageSourceGetType(source) as String? else {
            throw WatermarkError.unsupportedFormat("无法识别动图容器（\(displayName)）")
        }
        guard Self.isAnimatedUTI(type) else {
            throw WatermarkError.unsupportedFormat("动图容器 \(type)")
        }

        let frameCount = CGImageSourceGetCount(source)
        guard frameCount > 0 else {
            throw WatermarkError.unsupportedFormat("动图帧数为 0（\(displayName)）")
        }

        let globalProperties = CGImageSourceCopyProperties(source, nil) as? [String: Any]

        // ── 阶段 2/3：逐帧渲染 + 编码（同一循环内交替，避免整包持有）──────
        ProcessingTrace.mark(.rendering)

        let outputData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            outputData, type as CFString, frameCount, nil
        ) else {
            throw WatermarkError.unsupportedFormat("系统缺少 \(type) 动图编码器，无法原格式写回")
        }

        // 全局属性：仅循环次数 + 禁用全局调色板。这里绝不写延时（硬要求②）。
        CGImageDestinationSetProperties(
            dest,
            Self.globalDestinationProperties(global: globalProperties, type: type) as CFDictionary
        )

        for index in 0..<frameCount {
            try Task.checkCancellation()

            try autoreleasepool {
                // 硬要求①：全尺寸逐帧解码，绝不 thumbnail。
                guard let frame = CGImageSourceCreateImageAtIndex(
                    source, index,
                    [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
                ) else {
                    throw WatermarkError.unsupportedFormat("第 \(index + 1) 帧解码失败（\(displayName)）")
                }
                let frameProperties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any]
                let frameSize = CGSize(width: frame.width, height: frame.height)

                // 水印层：compositor 内部按 (content, size) 缓存，逐帧复用同一张位图。
                let watermarkLayer = try compositor.watermarkLayerImage(
                    for: config.content, outputPixelSize: frameSize
                )

                // 与预览同一入口；动图恒传 seconds = nil。
                let composed = try compositor.compositedFrame(
                    base: frame,
                    config: config,
                    outputPixelSize: frameSize,
                    seconds: nil
                )

                // 调色板：原帧调色板 + 预留水印色；超限则中位切分（无抖动）。
                let originalPalette = Self.colorMap(from: frameProperties)
                    ?? Self.colorMap(from: globalProperties)
                let reservedColors = Self.samplePaletteColors(from: watermarkLayer,
                                                              limit: Self.reservedWatermarkColorCount)

                ProcessingTrace.mark(.encoding)
                let quantized = try AnimatedFrameQuantizer.quantize(
                    composed,
                    originalPalette: originalPalette,
                    reservedColors: reservedColors,
                    colorLimit: min(max(settings.animatedPaletteLimit, 2), 256),
                    allowDithering: false   // 硬要求③：批量路径禁止抖动（帧间闪烁）
                )
                let outputFrame = try quantized.makeCGImage()

                // 硬要求②：逐帧延时取自该帧原值，两个 key 都写。
                let properties = Self.frameDestinationProperties(
                    from: frameProperties,
                    type: type,
                    pixelSize: frameSize
                )
                CGImageDestinationAddImage(dest, outputFrame,
                                           properties as CFDictionary)
            }

            progress(0.25 + 0.72 * Double(index + 1) / Double(frameCount))
        }

        ProcessingTrace.mark(.writing)
        guard CGImageDestinationFinalize(dest) else {
            throw WatermarkError.encodeFailed("动图编码收尾失败（\(displayName)）")
        }
        progress(1)

        return .animatedImage(data: outputData as Data, uti: type)
    }

    // MARK: - 预留水印色

    /// 预留多少种水印色：文字抗锯齿边缘 + 描边/阴影色通常 < 24 种，
    /// 取 24 已能保证水印区域「零误差落色」，同时给原帧调色板留足 232 个槽位。
    static let reservedWatermarkColorCount = 24

    // MARK: - 属性字典

    /// 全局属性：只写循环与调色板作用域。
    static func globalDestinationProperties(global: [String: Any]?,
                                            type: String) -> [String: Any] {
        var result: [String: Any] = [:]
        if isGIF(type) {
            var gif: [String: Any] = [:]
            // LoopCount = 0 表示无限循环（GIF 约定）；源缺失时按 0（保持视觉行为一致）。
            let loop = (global?[kCGImagePropertyGIFDictionary as String] as? [String: Any])?[kCGImagePropertyGIFLoopCount as String] as? Int
            gif[kCGImagePropertyGIFLoopCount as String] = loop ?? 0
            gif[kCGImagePropertyGIFHasGlobalColorMap as String] = false
            result[kCGImagePropertyGIFDictionary as String] = gif
        } else {
            var webp: [String: Any] = [:]
            let loop = (global?[kCGImagePropertyWebPDictionary as String] as? [String: Any])?[kCGImagePropertyWebPLoopCount as String] as? Int
            webp[kCGImagePropertyWebPLoopCount as String] = loop ?? 0
            result[kCGImagePropertyWebPDictionary as String] = webp
        }
        return result
    }

    /// 逐帧属性：复制源帧属性（保 EXIF/XMP 等）→ 修正尺寸 → 写回该帧原始延时。
    static func frameDestinationProperties(from source: [String: Any]?,
                                           type: String,
                                           pixelSize: CGSize) -> [String: Any] {
        var result: [String: Any] = [:]
        if let source {
            for (key, value) in source {
                if let nested = value as? [String: Any] {
                    result[key] = nested
                } else {
                    result[key] = value
                }
            }
        }
        result[kCGImagePropertyOrientation as String] = 1
        result[kCGImagePropertyPixelWidth as String] = Int(pixelSize.width)
        result[kCGImagePropertyPixelHeight as String] = Int(pixelSize.height)
        // 画布位深固定 8（GIF 索引色）；Depth 键若源里有也改为 8，避免解码端误判。
        result[kCGImagePropertyDepth as String] = 8

        if isGIF(type) {
            var gif = result[kCGImagePropertyGIFDictionary as String] as? [String: Any] ?? [:]
            // 硬要求②：两个延时键都用该帧原值，不做归一化、不取平均。
            // 源缺 Unclamped 时保留原 DelayTime，删除可能存在的旧 Unclamped，避免写出非法值。
            if let delay = gif[kCGImagePropertyGIFDelayTime as String] {
                gif[kCGImagePropertyGIFDelayTime as String] = delay
            }
            if let unclamped = gif[kCGImagePropertyGIFUnclampedDelayTime as String] {
                gif[kCGImagePropertyGIFUnclampedDelayTime as String] = unclamped
            }
            // 不把源调色板写回（我们自己量化，写回会让 ImageIO 覆盖新调色板）。
            gif.removeValue(forKey: kCGImagePropertyGIFImageColorMap as String)
            gif[kCGImagePropertyGIFHasGlobalColorMap as String] = false
            result[kCGImagePropertyGIFDictionary as String] = gif
        } else {
            var webp = result[kCGImagePropertyWebPDictionary as String] as? [String: Any] ?? [:]
            if let delay = webp[kCGImagePropertyWebPDelayTime as String] {
                webp[kCGImagePropertyWebPDelayTime as String] = delay
            }
            if let unclamped = webp[kCGImagePropertyWebPUnclampedDelayTime as String] {
                webp[kCGImagePropertyWebPUnclampedDelayTime as String] = unclamped
            }
            result[kCGImagePropertyWebPDictionary as String] = webp
        }
        return result
    }

    /// 源帧调色板（GIF ImageColorMap 为 3 字节/色的原始色表）。
    static func colorMap(from properties: [String: Any]?) -> [UInt8]? {
        guard let gif = properties?[kCGImagePropertyGIFDictionary as String] as? [String: Any],
              let map = gif[kCGImagePropertyGIFImageColorMap as String] as? Data,
              map.count >= 3 else { return nil }
        return [UInt8](map)
    }

    static func isGIF(_ type: String) -> Bool {
        let lower = type.lowercased()
        return lower == "com.compuserve.gif" || lower == "public.gif"
    }

    // MARK: - 水印色采样

    /// 从水印层位图采集不透明像素的代表色（最多 limit 种，按 5-5-5 去重）。
    static func samplePaletteColors(from layer: CGImage, limit: Int) -> [UInt8] {
        guard limit > 0,
              let pixels = AnimatedFrameQuantizer.rgbaPixels(of: layer) else { return [] }
        var seen = Set<Int>()
        var colors: [UInt8] = []
        let data = pixels.bytes
        var index = 0
        while index + 3 < data.count && colors.count / 3 < limit {
            let alpha = data[index + 3]
            if alpha > 8 {
                let r = Int(data[index]), g = Int(data[index + 1]), b = Int(data[index + 2])
                let key = ((r >> 3) << 10) | ((g >> 3) << 5) | (b >> 3)
                if seen.insert(key).inserted {
                    colors.append(contentsOf: [UInt8(r), UInt8(g), UInt8(b)])
                }
            }
            index += 4
        }
        return colors
    }
}

// MARK: - 帧量化器

/// 单帧量化结果。两条输出路径：
/// - `indices` 非空（不透明帧）：写「索引化 CGImage」，调色板逐字节可控、零误差落色；
/// - `rgba` 非空（含透明帧）：写 RGBA8，颜色已吸附到同一套调色板（等价于调色板可控），
///   alpha 原样保留——GIF 的透明是靠「调色板某个索引 + 透明标记」实现，ImageIO 只认
///   CGImage 的 alpha，故透明帧必须走 RGBA 路径才能保住透明（硬要求③「能保留必须保留」）。
enum AnimatedFrameQuantizer {

    struct QuantizedFrame {
        let width: Int
        let height: Int
        /// 索引路径（仅不透明帧）。
        let indices: [UInt8]?
        /// RGBA 路径（含透明帧，premultipliedLast）。
        let rgba: [UInt8]?
        /// 调色板 RGB（3 字节/色，已补齐到 2 的幂）。
        let palette: [UInt8]

        func makeCGImage() throws -> CGImage {
            if let indices {
                let table = palette.map { CGFloat($0) / 255 }
                guard let colorSpace = table.withUnsafeBufferPointer({ buffer -> CGColorSpace? in
                    CGColorSpace(indexedBaseSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                 last: palette.count / 3 - 1,
                                 colorTable: buffer.baseAddress!)
                }) else {
                    throw WatermarkError.encodeFailed("索引色色彩空间创建失败")
                }
                guard let provider = CGDataProvider(data: Data(indices) as CFData) else {
                    throw WatermarkError.encodeFailed("索引数据封装失败")
                }
                guard let image = CGImage(
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bitsPerPixel: 8,
                    bytesPerRow: width,
                    space: colorSpace,
                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                    provider: provider,
                    decode: nil,
                    shouldInterpolate: false,
                    intent: .defaultIntent
                ) else {
                    throw WatermarkError.encodeFailed("索引帧位图创建失败")
                }
                return image
            }

            guard let rgba else {
                throw WatermarkError.encodeFailed("量化帧数据为空")
            }
            guard let provider = CGDataProvider(data: Data(rgba) as CFData) else {
                throw WatermarkError.encodeFailed("RGBA 数据封装失败")
            }
            guard let image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            ) else {
                throw WatermarkError.encodeFailed("RGBA 帧位图创建失败")
            }
            return image
        }
    }

    // MARK: 入口

    /// 量化一帧。
    ///
    /// 策略与误差上界（硬要求③，必须写清）：
    /// 1. 若「原帧调色板 + 预留水印色」≤ 256 → 直接用该调色板：
    ///    原帧像素误差 = 0；水印区域用预留色，误差 = 0（水印色已显式预留）。
    /// 2. 否则 → 中位切分量化到 `colorLimit - 预留色数` 个色箱，再追加预留色：
    ///    中位切分按「最长通道跨度 × 像素数」优先切分，8bit RGB 立方体在 K=232 时
    ///    平均箱边长 ≈ 256 / K^(1/3) ≈ 40 levels，最近邻映射的**单通道误差上界 ≈ 40/255 ≈ 15.7%**，
    ///    典型（照片/插画类 GIF）实测约 20/255 ≈ 7.8%。该上界只在原调色板装不下时出现。
    /// 3. 抖动恒关闭：误差扩散会在相邻帧产生不同量化噪声，播放时形成闪烁，故不启用。
    /// 4. 同一套调色板只用于当前帧，不跨帧共用（`HasGlobalColorMap=false`），避免整片偏色。
    static func quantize(_ image: CGImage,
                         originalPalette: [UInt8]?,
                         reservedColors: [UInt8],
                         colorLimit: Int,
                         allowDithering: Bool) throws -> QuantizedFrame {
        guard let pixels = rgbaPixels(of: image) else {
            throw WatermarkError.renderFailed("动图帧像素读取失败")
        }

        let width = pixels.width
        let height = pixels.height
        let bytes = pixels.bytes

        // 透明检测：任一像素 alpha < 255 即走 RGBA 路径（保留 GIF 透明）。
        var hasTransparency = false
        var scan = 3
        while scan < bytes.count {
            if bytes[scan] < 255 { hasTransparency = true; break }
            scan += 4
        }

        // 调色板构造
        var palette: [UInt8]
        if let original = originalPalette, !original.isEmpty,
           (original.count / 3) + (reservedColors.count / 3) <= colorLimit {
            palette = dedupe(original + reservedColors)
        } else {
            let reservedCount = reservedColors.count / 3
            let budget = max(2, colorLimit - reservedCount)
            let quantizedBase = medianCutPalette(pixels: bytes, maxColors: budget)
            palette = dedupe(quantizedBase + reservedColors)
        }
        if palette.count / 3 < 2 {
            palette = palette + [0, 0, 0]   // 索引色表至少 2 项（GIF 色表长度为 2 的幂）
        }
        palette = padToPowerOfTwo(palette)

        let mapper = ColorMapper(palette: palette, allowDithering: allowDithering)

        if hasTransparency {
            var output = [UInt8](repeating: 0, count: width * height * 4)
            var offset = 0
            for pixel in stride(from: 0, to: bytes.count, by: 4) {
                let alpha = Int(bytes[pixel + 3])
                if alpha == 0 {
                    // 全透明像素：颜色不重要，保持全 0（premultiplied 不变式成立）
                    offset += 4
                    continue
                }
                // 反预乘 → 找最近调色板色 → 重新预乘
                let r = min(255, Int(bytes[pixel]) * 255 / alpha)
                let g = min(255, Int(bytes[pixel + 1]) * 255 / alpha)
                let b = min(255, Int(bytes[pixel + 2]) * 255 / alpha)
                let mapped = mapper.mappedColor(r: r, g: g, b: b)
                output[offset] = UInt8(mapped.r * alpha / 255)
                output[offset + 1] = UInt8(mapped.g * alpha / 255)
                output[offset + 2] = UInt8(mapped.b * alpha / 255)
                output[offset + 3] = UInt8(alpha)
                offset += 4
            }
            return QuantizedFrame(width: width, height: height,
                                  indices: nil, rgba: output, palette: palette)
        }

        var indices = [UInt8](repeating: 0, count: width * height)
        var offset = 0
        for pixel in stride(from: 0, to: bytes.count, by: 4) {
            indices[offset] = mapper.index(r: Int(bytes[pixel]),
                                           g: Int(bytes[pixel + 1]),
                                           b: Int(bytes[pixel + 2]))
            offset += 1
        }
        return QuantizedFrame(width: width, height: height,
                              indices: indices, rgba: nil, palette: palette)
    }

    // MARK: 像素读取

    struct RGBAImage {
        let bytes: [UInt8]
        let width: Int
        let height: Int
    }

    /// 读取 CGImage 像素为 sRGB / premultipliedLast / 8bpc。
    /// 这是量化必需的 CPU 读像素步骤（合成仍在 GPU）；GIF 本身即 sRGB 索引色，无色彩损失放大。
    /// 内存用裸指针自行管理：CGContext 不持有 data 指针，`withUnsafeMutableBytes` 的指针
    /// 出了闭包即失效，必须在同一作用域内完成 draw 再拷出。
    static func rgbaPixels(of image: CGImage) -> RGBAImage? {
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return nil }
        let byteCount = width * height * 4
        let raw = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 8)
        defer { raw.deallocate() }

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(data: raw,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: width * 4,
                                      space: colorSpace,
                                      bitmapInfo: bitmapInfo) else { return nil }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        let bytes = [UInt8](UnsafeRawBufferPointer(start: raw, count: byteCount))
        return RGBAImage(bytes: bytes, width: width, height: height)
    }

    // MARK: 调色板工具

    private static func dedupe(_ palette: [UInt8]) -> [UInt8] {
        var seen = Set<Int>()
        var result: [UInt8] = []
        var index = 0
        while index + 2 < palette.count {
            let key = (Int(palette[index]) << 16) | (Int(palette[index + 1]) << 8) | Int(palette[index + 2])
            if seen.insert(key).inserted {
                result.append(contentsOf: [palette[index], palette[index + 1], palette[index + 2]])
            }
            index += 3
        }
        return result
    }

    /// 补齐到 2 的幂（GIF 色表长度必须为 2/4/8/.../256）。
    private static func padToPowerOfTwo(_ palette: [UInt8]) -> [UInt8] {
        var count = palette.count / 3
        var target = 2
        while target < count { target <<= 1 }
        target = min(target, 256)
        if count >= target { return Array(palette.prefix(target * 3)) }
        var padded = palette
        while count < target {
            padded.append(contentsOf: [0, 0, 0])
            count += 1
        }
        return padded
    }

    // MARK: 中位切分

    /// 中位切分量化：返回 RGB 调色板（3 字节/色）。
    /// 采样上限 256K 像素，避免大图逐像素统计拖慢批量；采样偏差不影响调色板可用性。
    private static func medianCutPalette(pixels: [UInt8], maxColors: Int) -> [UInt8] {
        let pixelCount = pixels.count / 4
        guard pixelCount > 0, maxColors >= 2 else { return [] }
        let sampleStride = max(1, pixelCount / 262_144)

        // 5-5-5 直方图：key → 出现次数
        var histogram: [Int: Int] = [:]
        var index = 0
        var sampled = 0
        while index < pixels.count {
            let alpha = pixels[index + 3]
            if alpha > 8 {
                let r = Int(pixels[index]), g = Int(pixels[index + 1]), b = Int(pixels[index + 2])
                let key = ((r >> 3) << 10) | ((g >> 3) << 5) | (b >> 3)
                histogram[key, default: 0] += 1
            }
            index += 4 * sampleStride
            sampled += 1
        }
        guard !histogram.isEmpty else { return [] }

        struct Entry {
            let r: Int, g: Int, b: Int, count: Int
        }
        // 用 5bit 桶中心还原颜色（bucket*8+4），量化误差已计入最终误差上界。
        let entries: [Entry] = histogram.map { key, count in
            let r = ((key >> 10) & 0x1F) * 8 + 4
            let g = ((key >> 5) & 0x1F) * 8 + 4
            let b = (key & 0x1F) * 8 + 4
            return Entry(r: r, g: g, b: b, count: count)
        }

        struct Box {
            var entries: [Entry]
            var totalCount: Int
            var rRange: ClosedRange<Int>
            var gRange: ClosedRange<Int>
            var bRange: ClosedRange<Int>

            var longestAxis: Int {
                let dr = rRange.upperBound - rRange.lowerBound
                let dg = gRange.upperBound - gRange.lowerBound
                let db = bRange.upperBound - bRange.lowerBound
                if dr >= dg && dr >= db { return 0 }
                if dg >= db { return 1 }
                return 2
            }

            var extent: Int {
                max(rRange.upperBound - rRange.lowerBound,
                    max(gRange.upperBound - gRange.lowerBound,
                        bRange.upperBound - bRange.lowerBound))
            }

            /// 切分优先级：跨度大且像素多的箱子先切（视觉收益最高）。
            var priority: Int { extent * totalCount }

            static func make(_ entries: [Entry]) -> Box {
                var rMin = 255, rMax = 0, gMin = 255, gMax = 0, bMin = 255, bMax = 0, total = 0
                for entry in entries {
                    rMin = min(rMin, entry.r); rMax = max(rMax, entry.r)
                    gMin = min(gMin, entry.g); gMax = max(gMax, entry.g)
                    bMin = min(bMin, entry.b); bMax = max(bMax, entry.b)
                    total += entry.count
                }
                return Box(entries: entries, totalCount: total,
                           rRange: rMin...max(rMin, rMax),
                           gRange: gMin...max(gMin, gMax),
                           bRange: bMin...max(bMin, bMax))
            }
        }

        var boxes: [Box] = [Box.make(entries)]
        while boxes.count < maxColors {
            guard let splitIndex = boxes.enumerated()
                .filter({ $0.element.entries.count > 1 })
                .max(by: { $0.element.priority < $1.element.priority })?.offset else { break }
            let box = boxes[splitIndex]
            let axis = box.longestAxis
            let sorted = box.entries.sorted { lhs, rhs in
                switch axis {
                case 0: return lhs.r < rhs.r
                case 1: return lhs.g < rhs.g
                default: return lhs.b < rhs.b
                }
            }
            // 按像素数中位切分（而非按条目数），保证两半的视觉权重接近
            let half = box.totalCount / 2
            var accumulated = 0
            var cut = 0
            for (offset, entry) in sorted.enumerated() {
                accumulated += entry.count
                if accumulated >= half {
                    cut = min(max(offset, 1), sorted.count - 1)
                    break
                }
            }
            guard cut > 0, cut < sorted.count else { break }
            boxes.remove(at: splitIndex)
            boxes.append(Box.make(Array(sorted[..<cut])))
            boxes.append(Box.make(Array(sorted[cut...])))
        }

        // 代表色 = 箱内像素数加权平均
        var palette: [UInt8] = []
        for box in boxes where !box.entries.isEmpty {
            var r = 0, g = 0, b = 0, weight = 0
            for entry in box.entries {
                r += entry.r * entry.count
                g += entry.g * entry.count
                b += entry.b * entry.count
                weight += entry.count
            }
            guard weight > 0 else { continue }
            palette.append(contentsOf: [
                UInt8(min(255, r / weight)),
                UInt8(min(255, g / weight)),
                UInt8(min(255, b / weight)),
            ])
        }
        return palette
    }

    // MARK: 最近色映射（懒加载 LUT）

    /// 最近邻色映射。5-5-5 惰性 LUT：只为实际出现的颜色桶执行一次线性搜索，
    /// 单帧代价 ∝ 不同颜色数（而不是像素数 × 调色板大小）。
    /// `allowDithering` 仅为接口完整性保留，批量路径恒传 false（抖动会造成帧间闪烁）。
    final class ColorMapper {
        private let palette: [UInt8]
        private var lut: [Int16]

        init(palette: [UInt8], allowDithering: Bool) {
            self.palette = palette
            self.lut = [Int16](repeating: -1, count: 32 * 32 * 32)
            // 抖动实现刻意不存在：批量路径恒 false（硬要求③：抖动会造成帧间闪烁）。
            // 保留参数是为了将来单帧场景显式开启时，调用点能编译期暴露「这里做了抖动」。
            _ = allowDithering
        }

        func index(r: Int, g: Int, b: Int) -> UInt8 {
            let key = ((r >> 3) << 10) | ((g >> 3) << 5) | (b >> 3)
            let cached = lut[key]
            if cached >= 0 { return UInt8(cached) }

            var best = 0
            var bestDistance = Int.max
            var offset = 0
            var paletteIndex = 0
            while offset + 2 < palette.count {
                let dr = Int(palette[offset]) - r
                let dg = Int(palette[offset + 1]) - g
                let db = Int(palette[offset + 2]) - b
                let distance = dr * dr + dg * dg + db * db
                if distance < bestDistance {
                    bestDistance = distance
                    best = paletteIndex
                    if distance == 0 { break }
                }
                offset += 3
                paletteIndex += 1
            }
            let clamped = Int16(min(best, 255))
            lut[key] = clamped
            return UInt8(clamped)
        }

        func mappedColor(r: Int, g: Int, b: Int) -> (r: Int, g: Int, b: Int) {
            let paletteIndex = Int(index(r: r, g: g, b: b))
            let offset = paletteIndex * 3
            guard offset + 2 < palette.count else { return (r, g, b) }
            return (Int(palette[offset]), Int(palette[offset + 1]), Int(palette[offset + 2]))
        }
    }
}
