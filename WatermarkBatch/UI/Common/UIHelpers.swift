//
//  UIHelpers.swift
//  WatermarkBatch（水印工坊 BatchMark）
//
//  块C · UI 通用工具：颜色/十六进制互转、尺寸与时长格式化、内存峰值采样、
//  预览图降采样解码、文本文件导出（失败清单/日志）、等比适配矩形计算。
//
//  注意：本文件不参与任何渲染决策——水印几何一律交给 WatermarkCompositor。
//

import CoreGraphics
import ImageIO
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - 颜色

extension Color {

    /// "#RRGGBB" / "#RRGGBBAA" → Color；非法值返回 nil（调用方保留上次合法色）。
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8, let value = UInt64(s, radix: 16) else { return nil }
        if s.count == 6 {
            self.init(
                .sRGB,
                red: Double((value >> 16) & 0xFF) / 255,
                green: Double((value >> 8) & 0xFF) / 255,
                blue: Double(value & 0xFF) / 255,
                opacity: 1
            )
        } else {
            self.init(
                .sRGB,
                red: Double((value >> 24) & 0xFF) / 255,
                green: Double((value >> 16) & 0xFF) / 255,
                blue: Double((value >> 8) & 0xFF) / 255,
                opacity: Double(value & 0xFF) / 255
            )
        }
    }

    /// Color → "#RRGGBBAA"（固定 8 位，避免水印层 alpha 语义丢失）。
    var hexRGBA: String {
        let resolved = UIColor(self).resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard resolved.getRed(&r, green: &g, blue: &b, alpha: &a) else { return "#FFFFFFFF" }
        return String(
            format: "#%02X%02X%02X%02X",
            Int((r * 255).rounded()),
            Int((g * 255).rounded()),
            Int((b * 255).rounded()),
            Int((a * 255).rounded())
        )
    }
}

// MARK: - 格式化

enum Format {

    /// 秒 → "1:23" / "0:07"。
    static func clock(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// 秒 → "1 分 23 秒"（用于耗时展示）。
    static func durationText(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0 秒" }
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total) 秒" }
        let m = total / 60, s = total % 60
        return s == 0 ? "\(m) 分" : "\(m) 分 \(s) 秒"
    }

    /// 毫秒级耗时（单任务调试面板）。
    static func milliseconds(_ seconds: TimeInterval) -> String {
        String(format: "%.0f ms", seconds * 1000)
    }

    /// 字节 → "12.3 MB"。
    static func bytes(_ count: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useKB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(count))
    }

    /// 归一化比例 → 百分比文本（缩放 25%）。
    static func percent(_ value: CGFloat, digits: Int = 0) -> String {
        String(format: "%.\(digits)f%%", value * 100)
    }
}

// MARK: - 内存峰值采样

/// 进程物理内存占用（phys_footprint，与 Instruments Allocations 的 Anonymous VM 口径接近）。
/// 隐藏调试面板每 0.5s 采样一次取峰值；仅用于展示，不参与调度决策。
enum MemoryProbe {

    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.phys_footprint) / 1_048_576
    }
}

// MARK: - 预览图解码（仅 UI 展示；导出链路绝不走这里）

/// 预览基图解码：统一降采样到「屏幕 2 倍像素」以内，绝不用原图像素直接上屏
/// （§六.5：预览基图允许 ≤屏幕 2 倍像素降采样；合成仍走 compositedFrame 同一管线）。
enum PreviewImageDecoder {

    /// 单帧降采样解码（JPEG/HEIC/PNG/RAW 预览、Live 静帧、视频抽帧共用）。
    static func downsampled(_ data: Data, maxPixelSize: CGFloat) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return downsampled(source: source, index: 0, maxPixelSize: maxPixelSize)
    }

    /// 多帧图（GIF/动画 WebP）的第 index 帧降采样解码。
    static func frame(_ data: Data, index: Int, maxPixelSize: CGFloat) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return downsampled(source: source, index: index, maxPixelSize: maxPixelSize)
    }

    /// 帧总数（GIF/WebP/多页 TIFF）；单帧图返回 1。
    static func frameCount(_ data: Data) -> Int {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return 1 }
        return max(CGImageSourceGetCount(source), 1)
    }

    /// 首帧 + 中间帧 + 总帧数（GIF 预览用，一次解码避免重复建 source）。
    static func firstAndMiddle(_ data: Data, maxPixelSize: CGFloat) -> (first: CGImage?, middle: CGImage?, total: Int) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return (nil, nil, 1)
        }
        let total = max(CGImageSourceGetCount(source), 1)
        let middleIndex = total > 1 ? total / 2 : 0
        return (
            downsampled(source: source, index: 0, maxPixelSize: maxPixelSize),
            middleIndex == 0 ? nil : downsampled(source: source, index: middleIndex, maxPixelSize: maxPixelSize),
            total
        )
    }

    private static func downsampled(source: CGImageSource, index: Int, maxPixelSize: CGFloat) -> CGImage? {
        guard index >= 0, index < CGImageSourceGetCount(source) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,   // 方向烘焙，预览与导出视觉一致
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(maxPixelSize, 1),
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary)
    }
}

// MARK: - 等比适配矩形

/// CGImage 跨并发域传递的装箱。
/// CGImage 为不可变 CF 对象（Apple 文档明确可跨线程读取）；Swift 6 strict concurrency 下
/// 显式声明 @unchecked Sendable，避免预览渲染把整块合成搬回主线程。
struct SendableImage: @unchecked Sendable {
    let image: CGImage
}

/// 计算 `imageSize` 在 `bounds` 内 aspect-fit 后的显示矩形（居中）。
/// 手势层用它把屏幕 pt 位移换算为归一化坐标——归一化基准永远是「画面」而不是容器，
/// 否则画布留白会导致水印拖拽比例失真。
func fittedRect(imageSize: CGSize, in bounds: CGSize) -> CGRect {
    guard imageSize.width > 0, imageSize.height > 0,
          bounds.width > 0, bounds.height > 0 else { return .zero }
    let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
    let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    return CGRect(
        x: (bounds.width - size.width) / 2,
        y: (bounds.height - size.height) / 2,
        width: size.width,
        height: size.height
    )
}

// MARK: - 文本文件导出（失败清单 / 日志）

/// 文本 FileDocument：`fileExporter` 导出到「文件」App（失败清单、处理日志）。
struct TextFileDocument: FileDocument {

    static var readableContentTypes: [UTType] { [.plainText] }

    var text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        text = String(decoding: data, as: UTF8.self)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

// MARK: - 相册跳转

enum PhotoAppLink {

    /// 打开系统「照片」App（`photos-redirect://` 为系统公开可用的重定向 scheme）。
    static func openPhotosApp() {
        guard let url = URL(string: "photos-redirect://") else { return }
        UIApplication.shared.open(url)
    }

    /// 打开本 App 的系统设置页（权限被拒时的引导出口）。
    static func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}
