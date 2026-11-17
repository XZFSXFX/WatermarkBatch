//
//  VideoProcessor.swift
//  WatermarkBatch（水印工坊 BatchMark）
//
//  块B · 视频处理器（AVAssetReader → compositedFrame → AVAssetWriter 硬编）
//  契约：`struct VideoProcessor: AssetProcessor`（§4，签名一字不改）
//
//  ── 硬要求④ 的执行点 ───────────────────────────────────────────────────
//  - 编码器同源：源 fourCC → VideoCodec（avc1→H.264 / hvc1→HEVC），无法识别直接抛错，绝不换编码器。
//  - 码率：VideoWriterConfig.targetBitrate = max(源×1.3（速度档 1.0）, 平台推荐)，无任何硬编码常量。
//  - profile/level：VideoWriterConfig.profileLevel；输出后回读 level，低于源则**带显式 level 重试一次**，
//    仍低则如实报错（绝不改目标值假装达标）。
//  - GOP：预扫源关键帧间隔推算（夹取 0.5s~10s，绝不放大到 10s 以上）。
//  - 音频：AudioPassthrough 直通（sourceFormatHint，无 outputSettings，不重编码）。
//  - `writer.shouldOptimizeForNetworkUse = false`；全程不用 AVAssetExportSession。
//
//  ── 画质/内存 ────────────────────────────────────────────────────────
//  - 零缩放：输出像素 = 源显示像素（preferredTransform 烘焙进 buffer，输出不带旋转元数据）。
//  - 10bit/HDR：读帧/写帧用 420 10bit 像素格式，色彩空间按传递函数选用 HLG/PQ/BT.2020，禁 tone map。
//  - 内存：逐帧 autoreleasepool + CVPixelBufferPool，不预读、不攒帧。
//  - 单管线：每帧仍调 `compositor.compositedFrame(...)`（与预览同一入口，契约要点②）。
//

import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import Metal

// MARK: - 处理器

struct VideoProcessor: AssetProcessor {

    // MARK: 契约

    let kind: MediaKind = .video

    // MARK: 参数

    private let settings: ProcessingSettings
    /// 指定输出容器；nil 时按源扩展名推断（Live Photo 由 LivePhotoProcessor 强制 .mov）。
    private let fileType: AVFileType?

    init(settings: ProcessingSettings = .qualityFirst, fileType: AVFileType? = nil) {
        self.settings = settings
        self.fileType = fileType
    }

    // MARK: 主流程

    func process(asset: LibraryAsset,
                 config: WatermarkConfig,
                 library: PhotoLibraryService,
                 compositor: WatermarkCompositor,
                 progress: @Sendable @escaping (Double) -> Void) async throws -> ProcessedOutput {

        ProcessingTrace.mark(.reading)
        progress(0)

        // 源文件来自 PhotoKit（passthrough 导出到临时目录，不重编码）。
        let sourceURL = try await library.originalVideoURL(for: asset) { fraction in
            progress(fraction * 0.15)
        }
        try Task.checkCancellation()

        let ext = fileType == .mp4 ? "mp4" : ProcessingTempFile.fileExtension(forSourceURL: sourceURL)
        let outputURL = ProcessingTempFile.makeURL(extension: ext)

        ProcessingTrace.mark(.rendering)

        do {
            try await VideoWatermarkPipeline.run(
                sourceURL: sourceURL,
                destinationURL: outputURL,
                config: config,
                compositor: compositor,
                options: VideoWatermarkPipeline.Options(
                    fileType: fileType,
                    contentIdentifier: nil,
                    preserveMetadataTracks: false,
                    settings: settings
                )
            ) { fraction in
                progress(0.15 + fraction * 0.85)
            }
        } catch {
            PhotoLibraryService.removeTemporaryFile(at: outputURL)
            PhotoLibraryService.removeTemporaryFile(at: sourceURL)
            throw error
        }

        PhotoLibraryService.removeTemporaryFile(at: sourceURL)
        progress(1)
        return .video(url: outputURL)
    }
}

// MARK: - 管线

/// 视频水印管线（VideoProcessor 与 LivePhotoProcessor 共用）。
enum VideoWatermarkPipeline {

    /// 管线选项。
    struct Options: Sendable {
        /// 输出容器；nil 按源扩展名推断。
        var fileType: AVFileType?
        /// 写入 MOV 的 `com.apple.quicktime.content.identifier`（Live Photo 配对）。
        var contentIdentifier: String?
        /// 是否拷贝源元数据轨（Live Photo 的 still-image-time）。
        var preserveMetadataTracks: Bool
        /// 质量/码率档位。
        var settings: ProcessingSettings

        init(fileType: AVFileType? = nil,
             contentIdentifier: String? = nil,
             preserveMetadataTracks: Bool = false,
             settings: ProcessingSettings = .qualityFirst) {
            self.fileType = fileType
            self.contentIdentifier = contentIdentifier
            self.preserveMetadataTracks = preserveMetadataTracks
            self.settings = settings
        }
    }

    // MARK: 入口

    static func run(sourceURL: URL,
                    destinationURL: URL,
                    config: WatermarkConfig,
                    compositor: WatermarkCompositor,
                    options: Options,
                    progress: @Sendable @escaping (Double) -> Void) async throws {

        let source = try await LoadedSource.load(url: sourceURL, requestedFileType: options.fileType)

        // GOP 预扫（不影响质量，只影响关键帧密度；失败会退回 2s）。
        let gopFrames = await VideoWriterConfig.estimateGOPFrameCount(
            asset: source.asset, track: source.videoTrack, frameRate: source.frameRate
        )

        // ── 第一遍：AutoLevel ────────────────────────────────────────
        let firstPlan = VideoWriterConfig.makePlan(
            source: source.profile,
            width: source.outputWidth,
            height: source.outputHeight,
            frameRate: source.frameRate,
            sourceBitrate: source.sourceBitrate,
            gopFrameCount: gopFrames,
            factor: options.settings.videoBitrateFactor,
            explicitLevel: nil
        )
        try await encodePass(source: source,
                             plan: firstPlan,
                             destinationURL: destinationURL,
                             config: config,
                             compositor: compositor,
                             options: options,
                             progressRange: 0.0...0.9,
                             progress: progress)

        // ── 回读校验：输出 level 不得低于源 ───────────────────────────
        guard let sourceLevel = source.profile.level else { return }
        let writtenLevel = await readLevel(of: destinationURL, codec: firstPlan.codec)
        guard let writtenLevel, writtenLevel < sourceLevel else { return }

        // ── 第二遍：显式 level 重试一次 ───────────────────────────────
        try? FileManager.default.removeItem(at: destinationURL)
        let retryPlan = VideoWriterConfig.makePlan(
            source: source.profile,
            width: source.outputWidth,
            height: source.outputHeight,
            frameRate: source.frameRate,
            sourceBitrate: source.sourceBitrate,
            gopFrameCount: gopFrames,
            factor: options.settings.videoBitrateFactor,
            explicitLevel: sourceLevel
        )
        try await encodePass(source: source,
                             plan: retryPlan,
                             destinationURL: destinationURL,
                             config: config,
                             compositor: compositor,
                             options: options,
                             progressRange: 0.9...1.0,
                             progress: progress)

        let retriedLevel = await readLevel(of: destinationURL, codec: retryPlan.codec)
        if let retriedLevel, retriedLevel < sourceLevel {
            try? FileManager.default.removeItem(at: destinationURL)
            throw WatermarkError.encodeFailed(
                "编码器输出 level(\(retriedLevel)) 低于源 level(\(sourceLevel))，"
                + "已用显式 level \(retryPlan.profileLevel) 重试一次仍不达标"
            )
        }
    }

    // MARK: 单遍编码

    private static func encodePass(source: LoadedSource,
                                   plan: VideoEncodePlan,
                                   destinationURL: URL,
                                   config: WatermarkConfig,
                                   compositor: WatermarkCompositor,
                                   options: Options,
                                   progressRange: ClosedRange<Double>,
                                   progress: @Sendable @escaping (Double) -> Void) async throws {

        ProcessingTrace.mark(.encoding)
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: source.asset)
        } catch {
            throw WatermarkError.encodeFailed("无法创建视频读取器：\(error.localizedDescription)")
        }

        let videoOutput = AVAssetReaderTrackOutput(
            track: source.videoTrack,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: plan.pixelFormat]
        )
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else {
            throw WatermarkError.unsupportedFormat("源视频轨无法按 \(plan.pixelFormat) 读取")
        }
        reader.add(videoOutput)

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: destinationURL, fileType: source.fileType)
        } catch {
            throw WatermarkError.writeFailed("无法创建视频输出文件：\(error.localizedDescription)")
        }
        // 硬要求：不优化网络使用（避免 moov 前置带来的二次处理与耗时）。
        writer.shouldOptimizeForNetworkUse = false
        if let identifier = options.contentIdentifier {
            writer.metadata = [LivePhotoPairer.contentIdentifierMetadataItem(identifier)]
        }

        // 编码参数前置校验：码率必须是运行时算出来的显式值（禁止依赖编码器默认值）。
        // 这一断言把「硬要求④：不写常量码率」变成运行期可验证的事实。
        let outputSettings = plan.outputSettings()
        guard let compression = outputSettings[AVVideoCompressionPropertiesKey] as? [String: Any],
              let explicitBitrate = compression[AVVideoAverageBitRateKey] as? Int,
              explicitBitrate > 0 else {
            throw WatermarkError.encodeFailed("视频编码参数缺少显式平均码率（AVVideoAverageBitRateKey）")
        }

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: outputSettings)
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else {
            throw WatermarkError.encodeFailed("\(plan.codec.displayName) 编码器不接受当前参数"
                                              + "（\(plan.width)×\(plan.height) @\(Int(plan.frameRate))fps）")
        }
        writer.add(videoInput)

        let pixelAdaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: plan.pixelFormat,
                kCVPixelBufferWidthKey as String: plan.width,
                kCVPixelBufferHeightKey as String: plan.height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary,
            ]
        )

        // ── 音频直通 ────────────────────────────────────────────────
        var audioPair: (output: AVAssetReaderTrackOutput, input: AVAssetWriterInput)?
        if let audioTrack = source.audioTrack {
            let input = try await AudioPassthrough.makeWriterInput(for: audioTrack)
            guard writer.canAdd(input) else {
                throw WatermarkError.unsupportedFormat("当前容器（\(source.fileType.rawValue)）无法直通该音频格式")
            }
            writer.add(input)
            let output = AudioPassthrough.makeReaderOutput(for: audioTrack)
            guard reader.canAdd(output) else {
                throw WatermarkError.unsupportedFormat("音频轨无法直通读取")
            }
            reader.add(output)
            audioPair = (output, input)
        }

        // ── 元数据轨直通（Live Photo still-image-time）──────────────
        var metadataTriple: (reader: AVAssetReaderOutputMetadataAdaptor,
                             input: AVAssetWriterInput,
                             writer: AVAssetWriterInputMetadataAdaptor)?
        if options.preserveMetadataTracks, let metadataTrack = source.metadataTracks.first {
            let formatDescription = await AudioPassthrough.metadataFormatDescription(of: metadataTrack)
            let input = AudioPassthrough.makeMetadataWriterInput(formatDescription: formatDescription)
            guard writer.canAdd(input) else {
                throw WatermarkError.unsupportedFormat("无法保留 Live Photo 元数据轨（still-image-time）")
            }
            writer.add(input)
            let readerAdaptor = AudioPassthrough.makeMetadataReaderAdaptor(for: metadataTrack)
            guard reader.canAdd(readerAdaptor.assetReaderTrackOutput) else {
                throw WatermarkError.unsupportedFormat("无法读取 Live Photo 元数据轨")
            }
            reader.add(readerAdaptor.assetReaderTrackOutput)
            let writerAdaptor = AVAssetWriterInputMetadataAdaptor(assetWriterInput: input)
            metadataTriple = (readerAdaptor, input, writerAdaptor)
        }

        let session = VideoTranscodeSession(
            reader: reader,
            writer: writer,
            videoOutput: videoOutput,
            videoInput: videoInput,
            pixelAdaptor: pixelAdaptor,
            audioPair: audioPair,
            metadataTriple: metadataTriple,
            compositor: compositor,
            config: config,
            plan: plan,
            transform: source.transform,
            displaySize: CGSize(width: source.outputWidth, height: source.outputHeight),
            duration: source.duration,
            colorSpace: source.workingColorSpace,
            destinationURL: destinationURL,
            progressRange: progressRange,
            progress: progress
        )

        try await withTaskCancellationHandler {
            try await session.start()
        } onCancel: {
            session.cancel()
        }
    }

    // MARK: level 回读

    /// 读取已写出文件的视频轨 level（H.264 level_idc / HEVC level_idc）。
    static func readLevel(of url: URL, codec: VideoCodec) async -> Int? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else { return nil }
        let descriptions = (try? await track.load(.formatDescriptions)) ?? []
        guard let description = descriptions.first as? CMVideoFormatDescription else { return nil }
        switch codec {
        case .h264:
            return VideoWriterConfig.h264Level(from: description)?.level
        case .hevc:
            return VideoWriterConfig.hevcProfileTierLevel(from: description)?.levelIDC
        }
    }
}

// MARK: - 源加载

/// 源视频的全部已加载信息（只读；生命周期与一次编码相同）。
final class LoadedSource: @unchecked Sendable {

    let asset: AVURLAsset
    let videoTrack: AVAssetTrack
    let audioTrack: AVAssetTrack?
    let metadataTracks: [AVAssetTrack]
    let profile: VideoSourceProfile
    let outputWidth: Int
    let outputHeight: Int
    let transform: CGAffineTransform
    let frameRate: Double
    let sourceBitrate: Double
    let duration: CMTime
    let fileType: AVFileType
    let workingColorSpace: CGColorSpace

    private init(asset: AVURLAsset,
                 videoTrack: AVAssetTrack,
                 audioTrack: AVAssetTrack?,
                 metadataTracks: [AVAssetTrack],
                 profile: VideoSourceProfile,
                 outputWidth: Int,
                 outputHeight: Int,
                 transform: CGAffineTransform,
                 frameRate: Double,
                 sourceBitrate: Double,
                 duration: CMTime,
                 fileType: AVFileType,
                 workingColorSpace: CGColorSpace) {
        self.asset = asset
        self.videoTrack = videoTrack
        self.audioTrack = audioTrack
        self.metadataTracks = metadataTracks
        self.profile = profile
        self.outputWidth = outputWidth
        self.outputHeight = outputHeight
        self.transform = transform
        self.frameRate = frameRate
        self.sourceBitrate = sourceBitrate
        self.duration = duration
        self.fileType = fileType
        self.workingColorSpace = workingColorSpace
    }

    static func load(url: URL, requestedFileType: AVFileType?) async throws -> LoadedSource {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let duration = try await asset.load(.duration)

        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw WatermarkError.unsupportedFormat("视频无视频轨")
        }
        let descriptions = try await videoTrack.load(.formatDescriptions)
        guard let description = descriptions.first as? CMVideoFormatDescription else {
            throw WatermarkError.unsupportedFormat("视频轨缺少格式描述")
        }
        let fourCC = PhotoLibraryService.fourCharCodeString(CMFormatDescriptionGetMediaSubType(description))
        guard let codec = VideoWriterConfig.codec(fromFourCC: fourCC) else {
            throw WatermarkError.unsupportedFormat("视频编码器 \(fourCC)（仅支持同源 H.264/HEVC）")
        }
        let profile = VideoWriterConfig.sourceProfile(from: description, codec: codec)

        let naturalSize = try await videoTrack.load(.naturalSize)
        let transform = try await videoTrack.load(.preferredTransform)
        let bitrate = try await videoTrack.load(.estimatedDataRate)

        var frameRate = Double(try await videoTrack.load(.nominalFrameRate))
        if frameRate <= 0.5 {
            let minFrameDuration = try await videoTrack.load(.minFrameDuration)
            if minFrameDuration.isValid, minFrameDuration.seconds > 0 {
                frameRate = 1.0 / minFrameDuration.seconds
            }
        }
        if frameRate <= 0.5 { frameRate = 30 }

        // 显示像素：旋转烘焙后的尺寸（不做任何缩放/取整到 16 的倍数）。
        let transformed = naturalSize.applying(transform)
        let width = Int(abs(transformed.width).rounded())
        let height = Int(abs(transformed.height).rounded())
        guard width > 0, height > 0 else {
            throw WatermarkError.unsupportedFormat("视频显示尺寸非法")
        }

        let audioTrack = try await asset.loadTracks(withMediaType: .audio).first
        let metadataTracks = try await asset.loadTracks(withMediaType: .metadata)

        let fileType = resolveFileType(sourceURL: url, requested: requestedFileType)
        let colorSpace = workingColorSpace(for: profile)

        return LoadedSource(asset: asset,
                            videoTrack: videoTrack,
                            audioTrack: audioTrack,
                            metadataTracks: metadataTracks,
                            profile: profile,
                            outputWidth: width,
                            outputHeight: height,
                            transform: transform,
                            frameRate: frameRate,
                            sourceBitrate: max(bitrate, 0),
                            duration: duration,
                            fileType: fileType,
                            workingColorSpace: colorSpace)
    }

    /// 容器选择：显式指定优先；否则跟随源扩展名（.mp4/.m4v → mp4，其它 → mov）。
    private static func resolveFileType(sourceURL: URL, requested: AVFileType?) -> AVFileType {
        if let requested { return requested }
        switch sourceURL.pathExtension.lowercased() {
        case "mp4", "m4v": return .mp4
        default: return .mov
        }
    }

    /// 工作色彩空间：按源传递函数/原色选择，保证 HDR 不被 tone map 到 SDR。
    private static func workingColorSpace(for profile: VideoSourceProfile) -> CGColorSpace {
        let transfer = profile.transferFunction?.uppercased() ?? ""
        let primaries = profile.colorPrimaries?.uppercased() ?? ""
        if transfer.contains("2084") || transfer.contains("PQ") {
            return CGColorSpace(name: CGColorSpace.itur_2100_PQ) ?? CGColorSpace(name: CGColorSpace.sRGB)!
        }
        if transfer.contains("HLG") || transfer.contains("2100") {
            return CGColorSpace(name: CGColorSpace.itur_2100_HLG) ?? CGColorSpace(name: CGColorSpace.sRGB)!
        }
        if primaries.contains("2020") {
            return CGColorSpace(name: CGColorSpace.itur_2020) ?? CGColorSpace(name: CGColorSpace.sRGB)!
        }
        if primaries.contains("P3") {
            return CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpace(name: CGColorSpace.sRGB)!
        }
        return CGColorSpace(name: CGColorSpace.sRGB)!
    }
}

// MARK: - 编解码会话

/// 一次 Reader→Writer 的搬运会话。
///
/// 线程模型：video / audio / metadata 三路各自 `requestMediaDataWhenReady` 在自己的串行队列上泵数据，
/// 三路都结束后在 finish 队列结算。共享状态用 NSLock 保护；`@unchecked Sendable` 的依据即此。
private final class VideoTranscodeSession: @unchecked Sendable {

    // MARK: 依赖

    private let reader: AVAssetReader
    private let writer: AVAssetWriter
    private let videoOutput: AVAssetReaderTrackOutput
    private let videoInput: AVAssetWriterInput
    private let pixelAdaptor: AVAssetWriterInputPixelBufferAdaptor
    private let audioPair: (output: AVAssetReaderTrackOutput, input: AVAssetWriterInput)?
    private let metadataTriple: (reader: AVAssetReaderOutputMetadataAdaptor,
                                  input: AVAssetWriterInput,
                                  writer: AVAssetWriterInputMetadataAdaptor)?
    private let compositor: WatermarkCompositor
    private let config: WatermarkConfig
    private let plan: VideoEncodePlan
    private let transform: CGAffineTransform
    private let displaySize: CGSize
    private let duration: CMTime
    private let colorSpace: CGColorSpace
    private let destinationURL: URL
    private let progressRange: ClosedRange<Double>
    private let progress: @Sendable (Double) -> Void
    private let ciContext: CIContext

    // MARK: 状态

    private let stateLock = NSLock()
    private var cancelled = false
    private var failure: Error?
    private var lastReportedFraction: Double = -1
    private var didLeaveVideo = false
    private var didLeaveAudio = false
    private var didLeaveMetadata = false
    private var finished = false
    private var continuation: CheckedContinuation<Void, Error>?

    private let group = DispatchGroup()
    private let videoQueue = DispatchQueue(label: "com.watermarkbatch.video.pump", qos: .userInitiated)
    private let audioQueue = DispatchQueue(label: "com.watermarkbatch.video.audio", qos: .utility)
    private let metadataQueue = DispatchQueue(label: "com.watermarkbatch.video.metadata", qos: .utility)
    private let finishQueue = DispatchQueue(label: "com.watermarkbatch.video.finish")

    // MARK: 初始化

    init(reader: AVAssetReader,
         writer: AVAssetWriter,
         videoOutput: AVAssetReaderTrackOutput,
         videoInput: AVAssetWriterInput,
         pixelAdaptor: AVAssetWriterInputPixelBufferAdaptor,
         audioPair: (output: AVAssetReaderTrackOutput, input: AVAssetWriterInput)?,
         metadataTriple: (reader: AVAssetReaderOutputMetadataAdaptor,
                          input: AVAssetWriterInput,
                          writer: AVAssetWriterInputMetadataAdaptor)?,
         compositor: WatermarkCompositor,
         config: WatermarkConfig,
         plan: VideoEncodePlan,
         transform: CGAffineTransform,
         displaySize: CGSize,
         duration: CMTime,
         colorSpace: CGColorSpace,
         destinationURL: URL,
         progressRange: ClosedRange<Double>,
         progress: @Sendable @escaping (Double) -> Void) {
        self.reader = reader
        self.writer = writer
        self.videoOutput = videoOutput
        self.videoInput = videoInput
        self.pixelAdaptor = pixelAdaptor
        self.audioPair = audioPair
        self.metadataTriple = metadataTriple
        self.compositor = compositor
        self.config = config
        self.plan = plan
        self.transform = transform
        self.displaySize = displaySize
        self.duration = duration
        self.colorSpace = colorSpace
        self.destinationURL = destinationURL
        self.progressRange = progressRange
        self.progress = progress

        // 独立的 CIContext：需要显式控制输出色彩空间（HDR）与关闭中间结果缓存（省内存）。
        // 与 block A 的合成器共用同一 Metal 设备，色彩计算在同一条 GPU 管线内闭环。
        if let device = MTLCreateSystemDefaultDevice() {
            self.ciContext = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        } else {
            self.ciContext = CIContext(options: [.cacheIntermediates: false])
        }
    }

    // MARK: 启动 / 取消

    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.continuation = continuation

            guard writer.startWriting() else {
                let error = WatermarkError.encodeFailed(
                    "AVAssetWriter 启动失败：\(writer.error?.localizedDescription ?? "未知原因")"
                )
                writer.cancelWriting()
                try? FileManager.default.removeItem(at: self.destinationURL)
                self.resume(.failure(error))
                return
            }
            writer.startSession(atSourceTime: .zero)

            guard reader.startReading() else {
                let error = WatermarkError.encodeFailed(
                    "AVAssetReader 启动失败：\(reader.error?.localizedDescription ?? "未知原因")"
                )
                writer.cancelWriting()
                try? FileManager.default.removeItem(at: self.destinationURL)
                resume(.failure(error))
                return
            }

            group.enter()
            videoInput.requestMediaDataWhenReady(on: videoQueue) { [weak self] in
                self?.pumpVideo()
            }

            if let audioPair {
                group.enter()
                audioPair.input.requestMediaDataWhenReady(on: audioQueue) { [weak self] in
                    self?.pumpAudio()
                }
            }

            if let metadataTriple {
                group.enter()
                metadataTriple.input.requestMediaDataWhenReady(on: metadataQueue) { [weak self] in
                    self?.pumpMetadata()
                }
            }

            group.notify(queue: finishQueue) { [weak self] in
                self?.finalize()
            }
        }
    }

    /// 取消：幂等。停止读、终止写、删除半成品文件。
    func cancel() {
        stateLock.lock()
        if cancelled {
            stateLock.unlock()
            return
        }
        cancelled = true
        stateLock.unlock()
        reader.cancelReading()
    }

    // MARK: 视频泵

    private func pumpVideo() {
        while videoInput.isReadyForMoreMediaData {
            if isCancelled {
                videoInput.markAsFinished()
                leaveVideoOnce()
                return
            }
            guard let sample = videoOutput.copyNextSampleBuffer() else {
                videoInput.markAsFinished()
                leaveVideoOnce()
                return
            }
            do {
                let presentationTime = CMSampleBufferGetPresentationTimeStamp(sample)
                let buffer = try autoreleasepool { () throws -> CVPixelBuffer in
                    try renderFrame(sample: sample, presentationTime: presentationTime)
                }
                guard pixelAdaptor.append(buffer, withPresentationTime: presentationTime) else {
                    throw WatermarkError.encodeFailed(
                        "视频帧写入失败：\(writer.error?.localizedDescription ?? "未知原因")"
                    )
                }
                reportProgress(presentationTime)
            } catch {
                record(failure: error)
                reader.cancelReading()
                videoInput.markAsFinished()
                leaveVideoOnce()
                return
            }
        }
    }

    // MARK: 音频泵（压缩样本直通，PTS 不改写）

    private func pumpAudio() {
        guard let audioPair else { return }
        while audioPair.input.isReadyForMoreMediaData {
            if isCancelled {
                audioPair.input.markAsFinished()
                leaveAudioOnce()
                return
            }
            guard let sample = audioPair.output.copyNextSampleBuffer() else {
                audioPair.input.markAsFinished()
                leaveAudioOnce()
                return
            }
            if !audioPair.input.append(sample) {
                record(failure: WatermarkError.encodeFailed(
                    "音频直通写入失败：\(writer.error?.localizedDescription ?? "未知原因")"
                ))
                reader.cancelReading()
                audioPair.input.markAsFinished()
                leaveAudioOnce()
                return
            }
        }
    }

    // MARK: 元数据泵

    private func pumpMetadata() {
        guard let metadataTriple else { return }
        while metadataTriple.input.isReadyForMoreMediaData {
            if isCancelled {
                metadataTriple.input.markAsFinished()
                leaveMetadataOnce()
                return
            }
            guard let timedGroup = metadataTriple.reader.nextTimedMetadataGroup() else {
                metadataTriple.input.markAsFinished()
                leaveMetadataOnce()
                return
            }
            if !metadataTriple.writer.append(timedGroup) {
                record(failure: WatermarkError.encodeFailed(
                    "元数据轨写入失败：\(writer.error?.localizedDescription ?? "未知原因")"
                ))
                reader.cancelReading()
                metadataTriple.input.markAsFinished()
                leaveMetadataOnce()
                return
            }
        }
    }

    // MARK: 单帧渲染

    /// CVPixelBuffer →（旋转烘焙）→ CGImage → compositedFrame → CVPixelBuffer。
    ///
    /// 中间过一次 CGImage 是契约要求（必须走 compositor.compositedFrame 的 CGImage 入口），
    /// 这一步在 GPU 内完成，无 CPU 逐像素操作。
    private func renderFrame(sample: CMSampleBuffer,
                             presentationTime: CMTime) throws -> CVPixelBuffer {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sample) else {
            throw WatermarkError.renderFailed("视频帧缺少像素缓冲")
        }

        var image = CIImage(cvPixelBuffer: imageBuffer)
        if !transform.isIdentity {
            let rotated = image.transformed(by: transform)
            // transformed 后 extent 可能为负原点，平移到 (0,0)
            image = rotated.transformed(by: CGAffineTransform(translationX: -rotated.extent.minX,
                                                              y: -rotated.extent.minY))
        }
        let canvas = CGRect(origin: .zero, size: displaySize)
        let cropped = image.cropped(to: canvas)

        let format: CIFormat = plan.isHighBitDepth ? .RGBA16 : .RGBA8
        guard let cgImage = ciContext.createCGImage(cropped, from: canvas,
                                                    format: format, colorSpace: colorSpace) else {
            throw WatermarkError.renderFailed("视频帧转换为 CGImage 失败")
        }

        let seconds = CMTimeGetSeconds(presentationTime)
        let composited = try compositor.compositedFrame(
            base: cgImage,
            config: config,
            outputPixelSize: displaySize,
            seconds: seconds.isFinite ? seconds : nil
        )

        guard let pool = pixelAdaptor.pixelBufferPool else {
            throw WatermarkError.encodeFailed("像素缓冲池不可用（writer 未就绪）")
        }
        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer) == kCVReturnSuccess,
              let pixelBuffer else {
            throw WatermarkError.encodeFailed("像素缓冲分配失败")
        }
        ciContext.render(CIImage(cgImage: composited),
                         to: pixelBuffer,
                         bounds: canvas,
                         colorSpace: colorSpace)
        return pixelBuffer
    }

    // MARK: 进度

    private func reportProgress(_ time: CMTime) {
        let total = duration.seconds
        guard total.isFinite, total > 0 else { return }
        let fraction = min(max(time.seconds / total, 0), 1)
        stateLock.lock()
        let shouldReport = fraction - lastReportedFraction >= 0.01 || fraction >= 1
        if shouldReport { lastReportedFraction = fraction }
        stateLock.unlock()
        guard shouldReport else { return }
        let mapped = progressRange.lowerBound
            + (progressRange.upperBound - progressRange.lowerBound) * fraction
        progress(mapped)
    }

    // MARK: 收尾

    private func leaveVideoOnce() {
        stateLock.lock()
        let shouldLeave = !didLeaveVideo
        didLeaveVideo = true
        stateLock.unlock()
        if shouldLeave { group.leave() }
    }

    private func leaveAudioOnce() {
        stateLock.lock()
        let shouldLeave = !didLeaveAudio
        didLeaveAudio = true
        stateLock.unlock()
        if shouldLeave { group.leave() }
    }

    private func leaveMetadataOnce() {
        stateLock.lock()
        let shouldLeave = !didLeaveMetadata
        didLeaveMetadata = true
        stateLock.unlock()
        if shouldLeave { group.leave() }
    }

    private var isCancelled: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return cancelled
    }

    private func record(failure error: Error) {
        stateLock.lock()
        if failure == nil { failure = error }
        stateLock.unlock()
    }

    private func finalize() {
        stateLock.lock()
        let error = failure
        let wasCancelled = cancelled
        stateLock.unlock()

        if let error {
            writer.cancelWriting()
            reader.cancelReading()
            try? FileManager.default.removeItem(at: destinationURL)
            resume(.failure(wasCancelled ? WatermarkError.cancelled : error))
            return
        }
        if wasCancelled {
            writer.cancelWriting()
            reader.cancelReading()
            try? FileManager.default.removeItem(at: destinationURL)
            resume(.failure(WatermarkError.cancelled))
            return
        }
        if reader.status == .failed {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: destinationURL)
            resume(.failure(WatermarkError.encodeFailed(
                "读取失败：\(reader.error?.localizedDescription ?? "未知原因")"
            )))
            return
        }

        writer.finishWriting { [weak self] in
            guard let self else { return }
            if self.writer.status == .completed {
                self.progress(1)
                self.resume(.success(()))
            } else {
                try? FileManager.default.removeItem(at: self.destinationURL)
                self.resume(.failure(WatermarkError.encodeFailed(
                    "视频写入收尾失败：\(self.writer.error?.localizedDescription ?? "未知原因")"
                )))
            }
        }
    }

    /// 单次 resume（幂等）：continuation 只能 resume 一次。
    private func resume(_ result: Result<Void, Error>) {
        stateLock.lock()
        guard !finished, let continuation else { stateLock.unlock(); return }
        finished = true
        self.continuation = nil
        stateLock.unlock()
        continuation.resume(with: result)
    }
}
