//
//  EXIFPreserver.swift
//  WatermarkBatch（水印工坊 BatchMark）
//
//  块B · 元数据透传与静止图编码
//  依据 §六.6：`CGImageSourceCopyPropertiesAtIndex` 整个属性字典原样作为
//  `CGImageDestinationAddImage` 的 properties 传入，不做键过滤；方向以像素烘焙
//  （pre-bake orientation）后把 orientation 键写回 1，避免双重旋转；PNG 恒用无损路径保 alpha。
//
//  本文件同时是「静止图写盘」的唯一出口（照片 / RAW→HEIC / 动图帧的公共编码器），
//  目的是让 quality/位深/alpha 的处理只有一处，自查时只需看这一个文件。
//

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum EXIFPreserver {

    // MARK: - 编码质量（唯一定义处，禁止在处理器内另写数字）

    /// 有损格式 → 返回质量；无损格式 → 返回 nil（不写 quality 键 = 走无损路径）。
    ///
    /// - JPEG：`settings.lossyQuality`（画质优先 1.0 / 优先速度 0.95）
    /// - HEIC / HEIF：恒 1.0（v1.1 只授权 JPEG 降档；10bit 位深保真是红线）
    /// - WebP：恒 1.0（有损容器，但不允许在无损支柱上打折）
    /// - PNG / TIFF / BMP / GIF：nil（无损或索引色，写 quality 无意义且可能触发重编码）
    static func quality(for uti: String, settings: ProcessingSettings) -> Double? {
        switch normalizedUTI(uti) {
        case "public.jpeg", "public.jpeg-2000":
            return settings.lossyQuality
        case "public.heic", "public.heif", "public.heics", "public.heif-standard":
            return 1.0
        case "org.webmproject.webp":
            return 1.0
        default:
            return nil
        }
    }

    /// 是否是有损容器（决定是否携带 quality 键与是否允许位深变化）。
    static func isLossy(uti: String) -> Bool {
        quality(for: uti, settings: .qualityFirst) != nil
    }

    /// 是否 RAW/DNG（public.camera-raw-image 家族）。
    static func isRaw(uti: String) -> Bool {
        if let type = UTType(uti), type.conforms(to: .rawImage) { return true }
        let lower = uti.lowercased()
        return lower.contains("raw") || lower.contains("dng")
    }

    /// UTI 归一（部分系统返回 "public.heic " 带空格或大写）。
    private static func normalizedUTI(_ uti: String) -> String {
        uti.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    // MARK: - 方向

    /// 从属性字典读取 EXIF 方向（缺省 = .up）。
    static func orientation(from properties: [String: Any]?) -> CGImagePropertyOrientation {
        guard let number = properties?[kCGImagePropertyOrientation as String] as? NSNumber,
              let value = CGImagePropertyOrientation(rawValue: number.uint32Value) else { return .up }
        return value
    }

    /// 方向烘焙：把 EXIF 方向烧进像素，输出为「显示方向」的位图。
    ///
    /// 为什么要烘焙：`WatermarkCompositor` 的 placement 归一化坐标是相对**显示像素**的，
    /// 若把未旋转的原始像素直接喂给合成器，竖拍照片的水印会落在错误位置。
    /// 烘焙后输出 properties 的 orientation 恒为 1，避免系统二次旋转。
    ///
    /// 位深跟随源（`max(bitsPerComponent, 8)`），不做任何色彩空间转换、不做缩放。
    static func bakeOrientation(_ image: CGImage,
                                orientation: CGImagePropertyOrientation) -> CGImage {
        guard orientation != .up else { return image }

        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let swapsDimensions = (orientation == .left || orientation == .leftMirrored
                               || orientation == .right || orientation == .rightMirrored)
        let outputWidth = Int(swapsDimensions ? height : width)
        let outputHeight = Int(swapsDimensions ? width : height)
        guard outputWidth > 0, outputHeight > 0 else { return image }

        let colorSpace = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        // 无 alpha 的 3 通道位图无法直接建 8bpc CGContext（需 4 通道），补一个跳过通道。
        let alphaInfo: CGImageAlphaInfo = image.alphaInfo == .none ? .noneSkipLast : image.alphaInfo
        let bitsPerComponent = max(image.bitsPerComponent, 8)

        guard let context = CGContext(
            data: nil,
            width: outputWidth,
            height: outputHeight,
            bitsPerComponent: bitsPerComponent,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: alphaInfo.rawValue
        ) else {
            // 建不出上下文时退回原图（宁可不转也不降级位深）；调用方据 orientation 键仍为原值可感知。
            return image
        }

        var transform = CGAffineTransform.identity
        switch orientation {
        case .down, .downMirrored:
            transform = transform.translatedBy(x: width, y: height).rotated(by: .pi)
        case .left, .leftMirrored:
            transform = transform.translatedBy(x: width, y: 0).rotated(by: .pi / 2)
        case .right, .rightMirrored:
            transform = transform.translatedBy(x: 0, y: height).rotated(by: -.pi / 2)
        default:
            break
        }
        switch orientation {
        case .upMirrored, .downMirrored:
            transform = transform.translatedBy(x: width, y: 0).scaledBy(x: -1, y: 1)
        case .leftMirrored, .rightMirrored:
            transform = transform.translatedBy(x: height, y: 0).scaledBy(x: -1, y: 1)
        default:
            break
        }

        context.concatenate(transform)
        context.interpolationQuality = .none   // 纯方向变换，插值只会引入模糊
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }

    /// 方向烘焙后的像素尺寸。
    static func displayedPixelSize(of image: CGImage,
                                   orientation: CGImagePropertyOrientation) -> CGSize {
        let swaps = (orientation == .left || orientation == .leftMirrored
                     || orientation == .right || orientation == .rightMirrored)
        return swaps
            ? CGSize(width: image.height, height: image.width)
            : CGSize(width: image.width, height: image.height)
    }

    // MARK: - 属性字典

    /// 构造输出属性：源字典全量深拷贝 + 只改「尺寸/方向」这类必须改的键。
    ///
    /// 不做键过滤的原因：EXIF/TIFF/GPS/IPTC/MakerApple（含 Live Photo key 17）/
    /// 色彩空间/位深全在同一个字典里，过滤就会丢数据（§六.6 红线）。
    ///
    /// - Parameters:
    ///   - source: `CGImageSourceCopyPropertiesAtIndex` 的原始字典（可为 nil）。
    ///   - outputPixelSize: 方向烘焙后的输出像素尺寸（用于修正宽高）。
    ///   - makerAppleOverrides: 需要覆盖/合并进 MakerApple 字典的键值（Live Photo 配对用）。
    static func outputProperties(source: [String: Any]?,
                                 outputPixelSize: CGSize,
                                 makerAppleOverrides: [String: Any]? = nil) -> [String: Any] {
        var result: [String: Any] = [:]

        if let source {
            for (key, value) in source {
                // 嵌套字典必须深拷贝：直接写入会改到 CGImageSource 内部持有的 CFDictionary。
                if let nested = value as? [String: Any] {
                    result[key] = deepCopy(nested)
                } else if let array = value as? [Any] {
                    result[key] = array
                } else {
                    result[key] = value
                }
            }
        }

        let width = Int(outputPixelSize.width.rounded())
        let height = Int(outputPixelSize.height.rounded())

        // 顶层：方向已烘焙进像素 → 1
        result[kCGImagePropertyOrientation as String] = 1
        result[kCGImagePropertyPixelWidth as String] = width
        result[kCGImagePropertyPixelHeight as String] = height

        // TIFF：方向（很多看图工具优先读 TIFF 段）。
        // 注：ImageIO 未公开 kCGImagePropertyTIFFImageWidth/Length，故只修正方向，
        // 尺寸以顶层 PixelWidth/PixelHeight 与 EXIF PixelXDimension/PixelYDimension 为准。
        if var tiff = result[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            tiff[kCGImagePropertyTIFFOrientation as String] = 1
            result[kCGImagePropertyTIFFDictionary as String] = tiff
        }

        // EXIF：像素尺寸字段
        if var exif = result[kCGImagePropertyEXIFDictionary as String] as? [String: Any] {
            if exif[kCGImagePropertyExifPixelXDimension as String] != nil {
                exif[kCGImagePropertyExifPixelXDimension as String] = width
            }
            if exif[kCGImagePropertyExifPixelYDimension as String] != nil {
                exif[kCGImagePropertyExifPixelYDimension as String] = height
            }
            result[kCGImagePropertyEXIFDictionary as String] = exif
        }

        // MakerApple：Live Photo 的 assetIdentifier（key 17）在此合并，其余键原样保留。
        if let makerAppleOverrides {
            var makerApple = result[kCGImagePropertyMakerAppleDictionary as String] as? [String: Any] ?? [:]
            for (key, value) in makerAppleOverrides {
                makerApple[key] = value
            }
            result[kCGImagePropertyMakerAppleDictionary as String] = makerApple
        }

        return result
    }

    /// 从属性字典读出 MakerApple key 17（Live Photo assetIdentifier），用于配对自检。
    static func assetIdentifier(from properties: [String: Any]?) -> String? {
        guard let makerApple = properties?[kCGImagePropertyMakerAppleDictionary as String] as? [String: Any]
        else { return nil }
        return makerApple["17"] as? String
    }

    private static func deepCopy(_ dictionary: [String: Any]) -> [String: Any] {
        var copy: [String: Any] = [:]
        for (key, value) in dictionary {
            if let nested = value as? [String: Any] {
                copy[key] = deepCopy(nested)
            } else {
                copy[key] = value
            }
        }
        return copy
    }

    // MARK: - PNG 元数据承载审计（v1.2）

    /// PNG 容器实际未携带的元数据分组（用于「不静默丢弃」的日志与导出记录标注）。
    ///
    /// 做法：把写好的 PNG 重新解析属性（ImageIO 只读头部/chunk，不解码像素），
    /// 检查标准分组键是否存在。ImageIO 不提供「逐键写入失败」的回报，所以这里报的是
    /// 「产物里没有」这一客观事实——源本来就没 GPS 时也会出现在列表里，
    /// 但该说法对用户依然成立（这张 PNG 确实没有 GPS）。
    static func pngMissingMetadataGroups(in output: ProcessedOutput) -> [String] {
        switch output {
        case .stillImage(let data, let uti):
            guard uti.lowercased().contains("png") else { return [] }
            return pngMissingMetadataGroups(in: data)
        case .imageFile(let url, let uti):
            guard uti.lowercased().contains("png") else { return [] }
            return pngMissingMetadataGroups(in: url)
        default:
            return []
        }
    }

    static func pngMissingMetadataGroups(in data: Data) -> [String] {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return [] }
        return missingGroups(in: CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
    }

    static func pngMissingMetadataGroups(in url: URL) -> [String] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return [] }
        return missingGroups(in: CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
    }

    /// 标准元数据分组（顺序固定，便于日志比对）。
    nonisolated(unsafe) private static let groupedMetadataKeys: [(String, CFString)] = [
        ("EXIF", kCGImagePropertyExifDictionary),
        ("GPS", kCGImagePropertyGPSDictionary),
        ("TIFF", kCGImagePropertyTIFFDictionary),
        ("IPTC", kCGImagePropertyIPTCDictionary),
        ("MakerApple", kCGImagePropertyMakerAppleDictionary)
    ]

    /// 属性字典中实际存在的标准分组（PNG 编码失败时用于点名「装不下的是哪几组」）。
    static func presentMetadataGroups(in properties: [String: Any]?) -> [String] {
        guard let properties else { return [] }
        return groupedMetadataKeys.compactMap { label, key in
            let dictionary = properties[key as String] as? [String: Any]
            return (dictionary?.isEmpty ?? true) ? nil : label
        }
    }

    /// 标准元数据分组的缺失清单（顺序固定，便于日志比对）。
    /// 由 presentMetadataGroups 取补集得到：两处口径永远一致，不会出现
    /// 「披露说没丢、实际缺了」这类自相矛盾。
    private static func missingGroups(in properties: [String: Any]?) -> [String] {
        // 属性读不出来时返回空（不能把「读不到」误报成「五组全丢」）。
        guard let properties else { return [] }
        let present = Set(presentMetadataGroups(in: properties))
        return groupedMetadataKeys.map(\.0).filter { !present.contains($0) }
    }

    // MARK: - 编码（静止图唯一出口）

    /// 用原 UTI 编码单张图（不缩放、不换格式、不做色彩转换）。
    ///
    /// - Parameters:
    ///   - image: 合成后的位图（尺寸 = 源显示像素）。
    ///   - uti: 目标编码器 UTI（照片取源 UTI；RAW 取 `settings.rawOutputUTI`）。
    ///   - properties: `outputProperties(...)` 的结果。
    ///   - settings: 质量档位来源。
    /// - Returns: 编码后的完整文件字节。
    static func encode(_ image: CGImage,
                       uti: String,
                       properties: [String: Any],
                       settings: ProcessingSettings) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, uti as CFString, 1, nil
        ) else {
            // 绝不静默换成 JPEG：格式降级属 P0 缺陷（PRD 附录 2）。
            throw WatermarkError.unsupportedFormat("系统缺少 \(uti) 编码器，无法原格式写回")
        }

        var finalProperties = properties
        // 位深如实写入（10bit 源被拓宽到 16bpc 时，写 16 才能让解码端按高位深解释）。
        finalProperties[kCGImagePropertyDepth as String] = image.bitsPerComponent
        if let quality = quality(for: uti, settings: settings) {
            finalProperties[kCGImageDestinationLossyCompressionQuality as String] = quality
        } else {
            finalProperties.removeValue(forKey: kCGImageDestinationLossyCompressionQuality as String)
        }

        CGImageDestinationAddImage(destination, image, finalProperties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw WatermarkError.encodeFailed("\(uti) 编码收尾失败（数据不完整）")
        }
        return data as Data
    }
}
