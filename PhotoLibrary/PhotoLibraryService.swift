//
//  PhotoLibraryService.swift
//  WatermarkBatch（水印工坊 BatchMark）
//
//  块A · 相册服务（§4 接口契约签名一字不改）
//  职责：权限 / 取数（混合类型、日期倒序）/ 日期分组 / 列表预缓存 /
//        iCloud 原图下载（进度+重试，不降级）/ Live Photo 拆解 / 原始格式探测。
//
//  红线：原图数据全程只读（仅 PHAssetCreationRequest 新建副本，不修改原资产）；
//  下载原图失败抛 iCloudDownloadFailed，绝不静默用缩略图替代（PRD F-02）。
//

import AVFoundation
import CoreGraphics
import CoreMedia
import CryptoKit
import Foundation
import ImageIO
import Photos
import UniformTypeIdentifiers

final class PhotoLibraryService: @unchecked Sendable {

    private let cachingManager = AssetCachingManager()
    private let downloadCoordinator = ICloudDownloadCoordinator()

    /// 相簿写入器（块B ExportService 在 performChanges 内复用）。
    let albumWriter = AlbumWriter()

    /// 原图 Data 进程内 LRU 缓存：避免「formatInfo 探测 + 处理器取原图」对同一素材二次
    /// 下载/解码（§六.1-③ 同一素材严禁二次解码）。
    /// 上限 64MB：按 v1.1 裁决「内存峰值目标 <200MB，超限降并发不降画质」收敛
    /// （降并发由块B BatchQueue 负责，块A 主动收紧缓存给解码/合成峰值留余量）；
    /// NSCache 在系统内存压力下自动淘汰。
    private let originalDataCache = NSCache<NSString, NSData>()
    private let formatCache = NSCache<NSString, FormatInfoBox>()
    private let availabilityCache = NSCache<NSString, NSNumber>()

    /// NSCache 装箱（AssetFormatInfo 为 struct）。
    final class FormatInfoBox: @unchecked Sendable {
        let value: AssetFormatInfo
        init(_ value: AssetFormatInfo) { self.value = value }
    }

    /// iCloud 原图下载重试次数（与 ICloudDownloadCoordinator 同语义）。
    private let maxDownloadRetries = 3

    init() {
        originalDataCache.totalCostLimit = 64 * 1024 * 1024
    }

    // MARK: - 权限

    func requestAccess() async -> PhotoAccessLevel {
        let status: PHAuthorizationStatus
        if PHPhotoLibrary.authorizationStatus(for: .readWrite) == .notDetermined {
            status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        } else {
            status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        }
        return Self.level(for: status)
    }

    private var currentAccessLevel: PhotoAccessLevel {
        Self.level(for: PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    private static func level(for status: PHAuthorizationStatus) -> PhotoAccessLevel {
        switch status {
        case .authorized, .limited:
            return .full       // limited（部分照片）仍可读取选中范围，映射为完全访问
        case .addOnly:
            return .addOnly    // 仅添加：无法读取既有相册——批量导入不可用（§七 注释）
        default:
            return .denied
        }
    }

    // MARK: - 取数（混合类型，按创建日期倒序）

    func fetchAllAssets() async -> [LibraryAsset] {
        // addOnly/denied 下 PHAsset fetch 无结果；显式短路，UI 据权限态引导
        guard currentAccessLevel == .full else { return [] }

        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.includeHiddenAssets = false
        let fetch = PHAsset.fetchAssets(with: options)

        var assets: [LibraryAsset] = []
        assets.reserveCapacity(fetch.count)
        fetch.enumerateObjects { phAsset, _, _ in
            autoreleasepool {
                assets.append(Self.makeLibraryAsset(from: phAsset))
            }
        }
        return assets
    }

    /// PHAsset → LibraryAsset：类型探测（照片/Live/GIF·动画WebP/视频/RAW）、
    /// 像素尺寸、时长、文件名；每素材一次 PHAssetResource 查询（读元数据，不下载）。
    static func makeLibraryAsset(from phAsset: PHAsset) -> LibraryAsset {
        let resources = PHAssetResource.assetResources(for: phAsset)
        let kind = detectKind(phAsset: phAsset, resources: resources)
        let primary = primaryResource(for: phAsset, kind: kind, resources: resources)
        return LibraryAsset(
            id: stableUUID(for: phAsset.localIdentifier),
            assetIdentifier: phAsset.localIdentifier,
            kind: kind,
            pixelSize: CGSize(width: phAsset.pixelWidth, height: phAsset.pixelHeight),
            duration: (kind == .video || kind == .livePhoto) ? phAsset.duration : nil,
            creationDate: phAsset.creationDate,
            originalFilename: primary?.filename,
            isInICloud: false   // 系统无公开 API 同步查询；见 isOriginalInICloud(_:)
        )
    }

    /// 类型探测优先级：视频 → Live Photo → RAW → 动图 → 照片。
    static func detectKind(phAsset: PHAsset, resources: [PHAssetResource]) -> MediaKind {
        if phAsset.mediaType == .video { return .video }
        if phAsset.mediaSubtypes.contains(.photoLive) { return .livePhoto }
        if resources.contains(where: isRawResource) { return .raw }
        // PHAssetPlaybackStyle.imageAnimated 覆盖 GIF 与动画 WebP；资源 UTI 兜底
        if phAsset.playbackStyle == .imageAnimated { return .animated }
        if let uti = resources.first?.uniformTypeIdentifier,
           uti == "public.gif" || uti == "com.compuserve.gif" {
            return .animated
        }
        return .photo
    }

    /// RAW 判定：UTI 遵循 public.camera-raw-image（UniformTypeIdentifiers 原生支持，
    /// 覆盖 DNG/CR2/CR3/NEF/ARW 等），或按文件扩展名兜底（UTType 之外的历史后缀）。
    static func isRawResource(_ resource: PHAssetResource) -> Bool {
        if let uti = resource.uniformTypeIdentifier,
           let type = UTType(uti),
           type.conforms(to: .rawImage) {
            return true
        }
        let rawExtensions: Set<String> = ["dng", "cr2", "cr3", "nef", "arw", "raf",
                                          "orf", "rw2", "pef", "srw", "3fr", "iiq"]
        if let ext = resource.filename?.split(separator: ".").last?.lowercased(),
           rawExtensions.contains(ext) {
            return true
        }
        return false
    }

    /// 主资源：文件名/UTI/下载的取数对象。
    /// 照片类：.fullSizePhoto（用户当前所见的高清版本，含编辑）> .photo > .adjustmentBasePhoto；
    /// 视频：.fullSizeVideo > .video；Live 视频段：.fullSizePairedVideo > .pairedVideo。
    static func primaryResource(for phAsset: PHAsset,
                                kind: MediaKind,
                                resources: [PHAssetResource]) -> PHAssetResource? {
        let order: [PHAssetResourceType]
        switch kind {
        case .photo, .raw, .animated:
            order = [.fullSizePhoto, .photo, .adjustmentBasePhoto]
        case .video:
            order = [.fullSizeVideo, .video]
        case .livePhoto:
            order = [.fullSizePairedVideo, .pairedVideo]
        }
        for type in order {
            if let hit = resources.first(where: { $0.type == type }) {
                return hit
            }
        }
        return resources.first
    }

    /// 照片类素材的原图资源（originalImageData / livePhotoPair 静帧取数对象）。
    static func stillResource(resources: [PHAssetResource]) -> PHAssetResource? {
        for type: PHAssetResourceType in [.fullSizePhoto, .photo, .adjustmentBasePhoto] {
            if let hit = resources.first(where: { $0.type == type }) {
                return hit
            }
        }
        return resources.first
    }

    /// Live Photo 配对视频资源。
    static func pairedVideoResource(resources: [PHAssetResource]) -> PHAssetResource? {
        for type: PHAssetResourceType in [.fullSizePairedVideo, .pairedVideo] {
            if let hit = resources.first(where: { $0.type == type }) {
                return hit
            }
        }
        return nil
    }

    /// assetIdentifier → 确定性 UUID（v5 布局，SHA256 派生）：
    /// 同一 PHAsset 多次取数 ID 稳定，选中态/任务引用不漂移。
    static func stableUUID(for identifier: String) -> UUID {
        let digest = SHA256.hash(data: Data(identifier.utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50   // version 5 布局
        bytes[8] = (bytes[8] & 0x3F) | 0x80   // RFC 4122 variant
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3],
                           bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11],
                           bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    // MARK: - 日期分组

    func groupByDay(_ assets: [LibraryAsset]) -> [AssetDayGroup] {
        let calendar = Calendar.current
        var buckets: [Date: [LibraryAsset]] = [:]
        for asset in assets {
            let day = calendar.startOfDay(for: asset.creationDate ?? .distantPast)
            buckets[day, default: []].append(asset)
        }
        // 组间：日期倒序；组内：保持传入的创建日期倒序（fetchAllAssets 已保证，此处再防御性排序）
        return buckets.keys.sorted(by: >).map { day in
            AssetDayGroup(id: day, assets: buckets[day]!.sorted {
                ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast)
            })
        }
    }

    // MARK: - 列表预缓存（PHCachingImageManager 封装）

    func startCaching(_ assets: [LibraryAsset], targetSize: CGSize) {
        cachingManager.startCaching(
            assetIdentifiers: assets.map(\.assetIdentifier),
            targetSize: targetSize
        )
    }

    func stopCaching() {
        cachingManager.stopCaching()
    }

    /// 相册列表/预览基图缩略图（仅 UI 用途，导出链路禁止调用）。
    func thumbnail(for asset: LibraryAsset, targetSize: CGSize) async -> CGImage? {
        await cachingManager.thumbnail(for: asset.assetIdentifier, targetSize: targetSize)
    }

    // MARK: - iCloud 原图下载

    /// iCloud 原图数据下载：带进度回调、内部最多重试 3 次，失败抛 iCloudDownloadFailed（不降级缩略图）。
    func originalImageData(for asset: LibraryAsset,
                           progress: @Sendable @escaping (Double) -> Void) async throws -> Data {
        let cacheKey = asset.assetIdentifier as NSString
        if let cached = originalDataCache.object(forKey: cacheKey) {
            progress(1)
            return cached as Data
        }
        guard let phAsset = self.phAsset(asset.assetIdentifier) else {
            throw WatermarkError.assetUnavailable(assetIdentifier: asset.assetIdentifier)
        }
        let resources = PHAssetResource.assetResources(for: phAsset)
        guard let resource = Self.stillResource(resources: resources) else {
            throw WatermarkError.unsupportedFormat("未找到照片原始资源")
        }
        let data = try await downloadCoordinator.resourceData(for: resource, progress: progress)
        originalDataCache.setObject(data as NSData, forKey: cacheKey, cost: data.count)
        return data
    }

    /// 视频/Live 视频段：导出为临时文件 URL（AVAssetExportSession passthrough），同上语义
    /// （进度 + 3 次重试 + iCloudDownloadFailed）。passthrough 不重编码视频轨。
    /// 临时文件生命周期归调用方（块B 处理完成后调 removeTemporaryFile 清理）。
    func originalVideoURL(for asset: LibraryAsset,
                          progress: @Sendable @escaping (Double) -> Void) async throws -> URL {
        guard let phAsset = self.phAsset(asset.assetIdentifier) else {
            throw WatermarkError.assetUnavailable(assetIdentifier: asset.assetIdentifier)
        }
        guard phAsset.mediaType == .video else {
            throw WatermarkError.unsupportedFormat("素材不是视频")
        }
        progress(0)
        for attempt in 0...maxDownloadRetries {
            do {
                return try await exportVideoOnce(phAsset, for: asset, progress: progress)
            } catch {
                if error is CancellationError || Task.isCancelled { throw error }
                if attempt < maxDownloadRetries {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
        }
        throw WatermarkError.iCloudDownloadFailed(assetIdentifier: asset.assetIdentifier)
    }

    /// 单次 passthrough 导出：requestAVAsset（网络允许，iCloud 由系统拉取）→
    /// AVAssetExportSession(preset: Passthrough) → 轮询进度 → 临时文件。
    private func exportVideoOnce(_ phAsset: PHAsset,
                                  for asset: LibraryAsset,
                                  progress: @Sendable @escaping (Double) -> Void) async throws -> URL {
        let avAsset = try await requestOriginalAVAsset(for: phAsset, assetIdentifier: asset.assetIdentifier)
        guard let session = AVAssetExportSession(asset: avAsset,
                                                 presetName: AVAssetExportPresetPassthrough) else {
            throw WatermarkError.unsupportedFormat("无法创建视频导出会话")
        }
        let compatible = await withCheckedContinuation { continuation in
            nonisolated(unsafe) let session = session
            session.determineCompatibleFileTypes { types in
                continuation.resume(returning: types)
            }
        }
        // 容器选择：与源容器一致优先（.mov 保 Live/MOV 系元数据），否则首个兼容类型
        let outputType: AVFileType
        if compatible.contains(.mov) {
            outputType = .mov
        } else if let first = compatible.first {
            outputType = first
        } else {
            throw WatermarkError.unsupportedFormat("无兼容的视频容器")
        }
        let ext = outputType == .mp4 ? "mp4" : "mov"
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("WatermarkBatch-\(UUID().uuidString).\(ext)")
        session.outputURL = outputURL
        session.outputFileType = outputType
        session.shouldOptimizeForNetworkUse = false

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            nonisolated(unsafe) let session = session
            // 导出期间轮询系统进度（0.2s 间隔），导出回调到达即停止
            let poller = Task {
                while session.status == .waiting || session.status == .exporting {
                    progress(Double(session.progress))
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
            }
            session.exportAsynchronously {
                poller.cancel()
                if let error = session.error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
        guard FileManager.default.fileExists(atPath: outputURL.path) else {
            throw WatermarkError.iCloudDownloadFailed(assetIdentifier: asset.assetIdentifier)
        }
        progress(1)
        return outputURL
    }

    /// PHImageManager 取原始 AVAsset（网络允许；失败信息在 info[PHImageErrorKey]）。
    private func requestOriginalAVAsset(for phAsset: PHAsset,
                                        assetIdentifier: String) async throws -> AVAsset {
        try await withCheckedThrowingContinuation { continuation in
            nonisolated(unsafe) let phAsset = phAsset
            let options = PHVideoRequestOptions()
            options.version = .original
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .highQualityFormat
            PHImageManager.default().requestAVAsset(forVideo: phAsset, options: options) { avAsset, _, info in
                if let avAsset {
                    continuation.resume(returning: avAsset)
                } else if let error = info?[PHImageErrorKey] as? Error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(
                        throwing: WatermarkError.assetUnavailable(assetIdentifier: assetIdentifier)
                    )
                }
            }
        }
    }

    /// Live Photo 拆解为 still 数据 + paired MOV URL。
    /// still 走资源管理器字节下载；paired MOV 走 PHAssetResourceManager.writeData
    /// 字节级直拷（容器/编码/元数据原样保留，优于重封装）。
    func livePhotoPair(for asset: LibraryAsset,
                       progress: @Sendable @escaping (Double) -> Void) async throws -> (stillData: Data, stillUTI: String, videoURL: URL) {
        guard let phAsset = self.phAsset(asset.assetIdentifier) else {
            throw WatermarkError.assetUnavailable(assetIdentifier: asset.assetIdentifier)
        }
        guard phAsset.mediaSubtypes.contains(.photoLive) else {
            throw WatermarkError.unsupportedFormat("素材不是 Live Photo")
        }
        let resources = PHAssetResource.assetResources(for: phAsset)
        guard let still = Self.stillResource(resources: resources) else {
            throw WatermarkError.unsupportedFormat("Live Photo 缺少静帧资源")
        }
        guard let pairedVideo = Self.pairedVideoResource(resources: resources) else {
            throw WatermarkError.unsupportedFormat("Live Photo 缺少配对视频资源")
        }

        // 进度分配：静帧 0...0.5，视频段 0.5...1（资源管理器下载完成前半段即可见）
        let stillData = try await downloadCoordinator.resourceData(for: still) { fraction in
            progress(fraction * 0.5)
        }
        let videoURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("WatermarkBatch-Live-\(UUID().uuidString).mov")
        try await downloadCoordinator.writeResource(pairedVideo, to: videoURL) { fraction in
            progress(0.5 + fraction * 0.5)
        }
        let stillUTI = still.uniformTypeIdentifier ?? "public.heic"
        return (stillData: stillData, stillUTI: stillUTI, videoURL: videoURL)
    }

    // MARK: - 原始格式探测

    /// 原始格式探测：UTI、编码器、位深、色彩空间（EXIF 保留与处理器分流依据）。
    /// 结果缓存（NSCache）：同一素材 formatInfo 探测与原图下载共用 originalDataCache，
    /// 不产生二次下载（§六.1-③）。
    func formatInfo(for asset: LibraryAsset) async throws -> AssetFormatInfo {
        let cacheKey = asset.assetIdentifier as NSString
        if let hit = formatCache.object(forKey: cacheKey) {
            return hit.value
        }
        let info: AssetFormatInfo
        switch asset.kind {
        case .video, .livePhoto:
            info = try await videoFormatInfo(for: asset)
        case .photo, .animated, .raw:
            info = try await stillFormatInfo(for: asset)
        }
        formatCache.setObject(FormatInfoBox(info), forKey: cacheKey)
        return info
    }

    /// 照片/RAW/动图：原图 Data（走缓存）→ CGImageSource 属性探测。
    private func stillFormatInfo(for asset: LibraryAsset) async throws -> AssetFormatInfo {
        let data = try await originalImageData(for: asset, progress: { _ in })
        guard let source = CGImageSourceCreateWithData(
            data as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ) else {
            throw WatermarkError.unsupportedFormat("原图数据无法解码")
        }
        let uti = (CGImageSourceGetType(source) as String?)
            ?? primaryResourceUTI(for: asset)
            ?? "public.image"
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [AnyHashable: Any] ?? [:]
        let bitDepth = (properties[kCGImagePropertyDepth] as? Int) ?? 8
        // 优先 ICC Profile 名；缺失时退回颜色模型（RGB/Gray）
        let colorSpaceName = (properties[kCGImagePropertyProfileName] as? String)
            ?? (properties[kCGImagePropertyColorModel] as? String)
        return AssetFormatInfo(uti: uti, bitDepth: bitDepth,
                               colorSpaceName: colorSpaceName, codec: nil)
    }

    /// 视频/Live 视频段：AVAsset 视频轨 formatDescription 探测（编码器 fourCC、位深、色彩原语）。
    private func videoFormatInfo(for asset: LibraryAsset) async throws -> AssetFormatInfo {
        guard let phAsset = self.phAsset(asset.assetIdentifier) else {
            throw WatermarkError.assetUnavailable(assetIdentifier: asset.assetIdentifier)
        }
        let avAsset = try await requestOriginalAVAsset(for: phAsset, assetIdentifier: asset.assetIdentifier)
        guard let track = avAsset.tracks(withMediaType: .video).first else {
            throw WatermarkError.unsupportedFormat("视频无视频轨")
        }
        guard let description = track.formatDescriptions.compactMap({ $0 as? CMVideoFormatDescription }).first else {
            throw WatermarkError.unsupportedFormat("视频轨格式信息缺失")
        }
        let codec = Self.fourCharCodeString(CMFormatDescriptionGetMediaSubType(description))
        let bitDepth = CMVideoFormatDescriptionGetBitsPerComponent(description)
        var colorPrimaries: String?
        if let extensions = CMCopyFormatDescriptionExtensions(description) as? [String: Any] {
            colorPrimaries = extensions[kCMFormatDescriptionExtension_ColorPrimaries as String] as? String
        }
        let uti = primaryResourceUTI(for: asset) ?? "public.movie"
        return AssetFormatInfo(uti: uti,
                               bitDepth: bitDepth > 0 ? Int(bitDepth) : 8,
                               colorSpaceName: colorPrimaries,
                               codec: codec)
    }

    /// 主资源 UTI（探测辅助；不下载）。
    private func primaryResourceUTI(for asset: LibraryAsset) -> String? {
        guard let phAsset = self.phAsset(asset.assetIdentifier) else { return nil }
        let resources = PHAssetResource.assetResources(for: phAsset)
        let primary = resources.first(where: { $0.type != .fullSizeVideo })
            ?? resources.first
        return primary?.uniformTypeIdentifier
    }

    /// FourCharCode（如 0x68766331）→ "hvc1"。
    static func fourCharCodeString(_ code: FourCharCode) -> String {
        let bytes = [
            UInt8((code >> 24) & 0xFF),
            UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF),
            UInt8(code & 0xFF),
        ]
        return String(decoding: bytes, as: UTF8.self)
    }

    // MARK: - iCloud 可用性（列表云朵角标，惰性探测）

    /// 探测原图是否仅在 iCloud（系统无公开 API 同步查询，故惰性探测 + 结果缓存）：
    /// 以 isNetworkAccessAllowed=false 请求原图数据、丢弃字节——成功即本地存在，
    /// 失败（NetworkAccessRequired/ItemUnavailable）即仅在 iCloud。
    /// 视频原件体积大，为避免整文件读盘开销不做探测（返回 false）：
    /// 云端状态在导出时由 ICloudDownloadCoordinator 的真实进度暴露，不会静默降级。
    func isOriginalInICloud(_ asset: LibraryAsset) async -> Bool {
        let cacheKey = asset.assetIdentifier as NSString
        if let hit = availabilityCache.object(forKey: cacheKey) {
            return hit.boolValue
        }
        guard asset.kind == .photo || asset.kind == .raw || asset.kind == .animated,
              let phAsset = self.phAsset(asset.assetIdentifier) else {
            return false
        }
        let resources = PHAssetResource.assetResources(for: phAsset)
        guard let resource = Self.stillResource(resources: resources) else { return false }
        let locallyAvailable: Bool = await withCheckedContinuation { continuation in
            nonisolated(unsafe) let resource = resource
            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = false
            PHAssetResourceManager.default().requestData(
                for: resource,
                options: options,
                dataReceivedHandler: { _ in /* 丢弃字节，仅探测可用性 */ },
                completionHandler: { error in
                    continuation.resume(returning: error == nil)
                }
            )
        }
        let inCloud = !locallyAvailable
        availabilityCache.setObject(NSNumber(value: inCloud), forKey: cacheKey)
        return inCloud
    }

    // MARK: - 辅助

    private func phAsset(_ identifier: String) -> PHAsset? {
        PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject
    }

    /// 清理本服务生成的临时文件（视频导出/Live 配对 MOV）。
    /// 由块B 在批次结束（含取消）后对每个产物 URL 调用。
    static func removeTemporaryFile(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
