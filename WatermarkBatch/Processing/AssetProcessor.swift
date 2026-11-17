//
//  AssetProcessor.swift
//  WatermarkBatch（水印工坊 BatchMark）
//
//  块B · 处理器协议 + 产物模型 + 处理器工厂
//  契约来源：《03-技术研发方案》§4【接口契约】—— 协议与 ProcessedOutput 签名一字不改。
//
//  统一约定（四个处理器共同遵守）：
//  ① 画布 = 源像素尺寸（方向烘焙后的显示像素），全链路零缩放；预览链路才允许降采样，
//     导出链路任何 resize/scale/thumbnail 都是违规。
//  ② 每一次合成必须走 `WatermarkCompositor.compositedFrame(...)`（与预览同一入口）。
//  ③ 产物是「原格式、原编码器、原元数据」的字节或临时文件 URL；临时文件由调用方
//     （ExportService / BatchQueue）在写回相册后清理。
//  ④ 处理器内部不重试、不吞错：错误一律映射为 WatermarkError 上抛，由 BatchQueue 归入失败清单。
//

import Foundation

// MARK: - 处理器协议（契约，签名一字不改）

protocol AssetProcessor: Sendable {
    var kind: MediaKind { get }
    /// 单素材端到端：取原图 → 逐帧/单帧合成 → 原格式编码。progress 0...1。
    func process(asset: LibraryAsset,
                 config: WatermarkConfig,
                 library: PhotoLibraryService,
                 compositor: WatermarkCompositor,
                 progress: @Sendable @escaping (Double) -> Void) async throws -> ProcessedOutput
}

// MARK: - 产物（契约，v1.2 新增 .imageFile）

enum ProcessedOutput: Sendable {
    case stillImage(data: Data, uti: String)                       // 照片：原编码器原样写回
    /// v1.2：大图产物落盘形态。批次内存红线（<200MB）下，>256KB 的静态/动图产物
    /// 由 BatchQueue 立即写 tmp 并转成本 case，释放 Data；写回语义与 stillImage 完全等价。
    case imageFile(url: URL, uti: String)
    case livePhoto(stillData: Data, stillUTI: String, videoURL: URL) // 已重新配对（同 assetIdentifier）
    case animatedImage(data: Data, uti: String)                     // GIF/WebP：帧数/延时/循环/调色板原样
    case video(url: URL)
}

// MARK: - 产物便捷访问（不影响契约）

extension ProcessedOutput {

    /// 需要落盘的临时文件（视频 / Live Photo 配对 MOV / v1.2 大图）。
    /// BatchQueue 与 ExportService 用它在写回成功后清理沙盒临时区。
    var temporaryFileURLs: [URL] {
        switch self {
        case .stillImage, .animatedImage:
            return []
        case .imageFile(let url, _):
            return [url]
        case .livePhoto(_, _, let videoURL):
            return [videoURL]
        case .video(let url):
            return [url]
        }
    }

    /// 产物形态的简短描述（日志用）。
    var logDescription: String {
        switch self {
        case .stillImage(let data, let uti):
            return "still \(uti) \(data.count / 1024)KB"
        case .imageFile(let url, let uti):
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil
            return "image-file \(uti) \(url.lastPathComponent) \((size ?? 0) / 1024)KB"
        case .animatedImage(let data, let uti):
            return "animated \(uti) \(data.count / 1024)KB"
        case .livePhoto(let stillData, let stillUTI, let videoURL):
            return "live \(stillUTI) \(stillData.count / 1024)KB + \(videoURL.lastPathComponent)"
        case .video(let url):
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil
            return "video \(url.lastPathComponent) \((size ?? 0) / 1024)KB"
        }
    }

    /// 是否因用户勾选「输出 PNG 无损」而换了容器（导出记录/日志标注用）。
    /// 只对静态图有意义：动图管线不读该开关（GIF/WebP 由格式硬约束决定）。
    var isPNGContainer: Bool {
        switch self {
        case .stillImage(_, let uti), .imageFile(_, let uti):
            return uti.lowercased().contains("png")
        default:
            return false
        }
    }

    /// v1.2 内存红线：大图落盘。
    ///
    /// 为什么必须在 BatchQueue 侧做：`ProcessedOutput.stillImage(data:)` 把编码后的完整
    /// 字节钉在内存里，100 张 12MP HEIC（q1.0 约 3-5MB）≈300-500MB，直接击穿 <200MB。
    /// 超过阈值就落到沙盒 tmp 并转 `.imageFile`，`outputs` 语义不变（结束后仍可取全量）。
    ///
    /// - 落盘失败 → 保留内存形态（宁可多占内存，不丢产物，也不让整个任务失败）。
    /// - 只有静态/动图走这条路；视频与 Live Photo 本来就是文件形态。
    func spilledToDiskIfLarge(threshold: Int = ProcessingTempFile.spillThresholdBytes) -> ProcessedOutput {
        switch self {
        case .stillImage(let data, let uti), .animatedImage(let data, let uti):
            guard data.count > threshold else { return self }
            let url = ProcessingTempFile.makeURL(
                extension: ProcessingTempFile.fileExtension(forUTI: uti)
            )
            do {
                try data.write(to: url, options: .atomic)
                return .imageFile(url: url, uti: uti)
            } catch {
                return self
            }
        default:
            return self
        }
    }

    /// 清理临时文件（写回相册后调用；失败路径也要调用，避免沙盒堆积）。
    func cleanupTemporaryFiles() {
        for url in temporaryFileURLs {
            PhotoLibraryService.removeTemporaryFile(at: url)
        }
    }
}

// MARK: - 临时文件命名

enum ProcessingTempFile {

    /// 产物临时文件统一前缀（清理陈旧残留时按此前缀识别，避免误删系统 tmp）。
    static let filePrefix = "WatermarkBatch-out-"

    /// 陈旧阈值：1 小时。正常批次在 ExportService 分块写回后立即删除，超过 1 小时仍存在的
    /// 只可能是崩溃/被系统杀死/用户强杀留下的孤儿文件。
    static let staleAge: TimeInterval = 60 * 60

    static func makeURL(extension ext: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(filePrefix)\(UUID().uuidString).\(ext)")
    }

    /// 清扫沙盒 temporaryDirectory 内的孤儿产物（前缀匹配 + mtime 超过 1 小时）。
    ///
    /// 调用点：`BatchQueue.execute` 入口（每次批量启动时一次性清扫）；App 启动时也可再调一次。
    /// 只删自己命名空间下的文件，不触碰系统/其它模块的 tmp。
    ///
    /// - Returns: 实际删除的文件数（写日志用；失败不影响批次）。
    @discardableResult
    static func sweepStaleFiles(olderThan age: TimeInterval = staleAge,
                                now: Date = Date()) -> Int {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: fileManager.temporaryDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        var removed = 0
        for url in entries {
            guard url.lastPathComponent.hasPrefix(filePrefix) else { continue }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            guard let modified = values?.contentModificationDate,
                  now.timeIntervalSince(modified) > age else { continue }
            if (try? fileManager.removeItem(at: url)) != nil { removed += 1 }
        }
        return removed
    }

    /// 图产物落盘阈值（v1.2）：>256KB 立刻转 `.imageFile` 释放内存。
    /// 256KB 的取舍：小于它的图（缩略图级 / 极小 PNG）落盘反而多一次磁盘往返，
    /// 保留在内存里对峰值影响可以忽略；大于它的（12MP HEIC 3-5MB、PNG 25-35MB）必须落盘。
    static let spillThresholdBytes = 256 * 1024

    /// 从 UTType 推断容器扩展名（视频产物 / v1.2 图产物）。
    static func fileExtension(forUTI uti: String?) -> String {
        guard let uti else { return "mov" }
        let lower = uti.lowercased()
        // 图产物（v1.2 imageFile）：先判图，再判视频，避免 heic/heif 落到 mov。
        if lower.contains("png") { return "png" }
        if lower.contains("heic") || lower.contains("heif") { return "heic" }
        if lower.contains("jpeg") || lower.contains("jpg") { return "jpg" }
        if lower.contains("gif") { return "gif" }
        if lower.contains("webp") { return "webp" }
        if lower.contains("tiff") { return "tiff" }
        if lower.contains("bmp") { return "bmp" }
        if lower.contains("mp4") || lower.contains("mpeg-4") { return "mp4" }
        if lower.contains("quicktime") || lower.contains("mov") { return "mov" }
        return "mov"
    }

    /// 从源文件扩展名推断容器（mp4/m4v → mp4，其它 → mov）。
    static func fileExtension(forSourceURL url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "mp4", "m4v": return "mp4"
        default: return "mov"
        }
    }
}

// MARK: - 处理器工厂（块B 内部/后台续跑用）

/// 按素材类型分发处理器（**后台续跑**与无 UI 场景的构造点）。
///
/// 注意：UI 侧的唯一构造点是块C 的 `ProcessorFactory.make(for:policy:)`（见 App/BatchController.swift），
/// 两者不要同名，否则同模块内 `ProcessorFactory` 会重定义。命名分工：
/// - 块C `ProcessorFactory`：把 `ProcessingPolicy`（UI 展示值）翻译成处理器实例；
/// - 块B `AssetProcessorFactory`：给 BGTaskCoordinator 等无 UI 场景按 `ProcessingSettings` 构造。
///
/// `settings` 必须与 BatchQueue 使用同一份（「优先速度」开关同时影响并发与编码参数）。
enum AssetProcessorFactory {

    static func processor(for kind: MediaKind,
                          settings: ProcessingSettings = .qualityFirst) -> any AssetProcessor {
        switch kind {
        case .photo:
            return PhotoProcessor(kind: .photo, settings: settings)
        case .raw:
            // RAW 走照片管线，但输出容器为 HEIC（settings.rawOutputUTI），且强制 rawConsent 门禁。
            return PhotoProcessor(kind: .raw, settings: settings)
        case .animated:
            return AnimatedImageProcessor(settings: settings)
        case .livePhoto:
            return LivePhotoProcessor(settings: settings)
        case .video:
            return VideoProcessor(settings: settings)
        }
    }

    /// 供 `BatchQueue.run(processorProvider:)` 直接使用的闭包（无 UI 场景默认实现）。
    static func provider(settings: ProcessingSettings = .qualityFirst)
        -> @Sendable (MediaKind) -> any AssetProcessor {
        { kind in processor(for: kind, settings: settings) }
    }
}
