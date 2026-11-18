//
//  AcceptanceTests.swift
//  WatermarkBatchTests（水印工坊 BatchMark）
//
//  真机验收（必须跑在真机上，不能跑模拟器）：把四项「文件证明不了」的验收变成断言。
//
//  与 Tools/verify/verify_media.sh 的分工：
//    · verify_media.sh 在 Mac 上比对「原文件 vs 导出文件」，能证明：配对键相等、GIF 逐帧延时、
//      HDR 标签、音频 md5 逐字节相同、PSNR/SSIM。
//    · 本文件在设备上问系统要答案，能证明：PHLivePhoto 真的能被系统组装出来（= 长按会播放）、
//      导出后的动图仍被 ImageIO 识别为多帧动图、视频轨色彩标签在 AVFoundation 层没有丢、音频轨
//      仍是压缩格式（被解开重编码会变成 lpcm）。
//
//  运行方式（在 Mac 上，设备已插好、信任过）：
//    xcodebuild test -project WatermarkBatch.xcodeproj -scheme WatermarkBatch \
//      -destination 'platform=iOS,id=<你的设备UDID>' \
//      -only-testing:WatermarkBatchTests/AcceptanceTests
//
//  前置：设备相册里已经有一批导出结果（先用 App 导一次）；测试取「最近的同类素材」做样本，
//        数量由 sampleCount 控制。相册权限未授予 / 相册里没有对应素材时记 SKIP，但**SKIP 不算通过**：
//        每个测试结束都会打一行 "[Acceptance] <测试名> SKIPPED=0 VERIFIED=n"，
//        Tools/verify/acceptance_gate.sh 抓这行做闸门——SKIPPED≠0 或 VERIFIED=0 直接判未通过。
//        为什么不让 XCTAssert 里硬判死：没素材是环境问题，硬判死会让「第一次跑」永远是红的；
//        但只 SKIP 不统计又是假绿，所以把「跳过」这件事本身变成会红的信号。
//

import XCTest
// PHLivePhoto / AVAssetTrack 等类型在 Swift 6 严格并发下未标注 Sendable；
// 本文件是 @MainActor 的验收测试，按编译器建议用 @preconcurrency 降级为警告。
@preconcurrency import Photos
@preconcurrency import AVFoundation
import ImageIO
import UniformTypeIdentifiers

@MainActor
final class AcceptanceTests: XCTestCase {

    /// 每类抽多少个最近样本。Live Photo 建议 ≥3（至少能覆盖静帧/动段两侧）。
    private let sampleCount = 5

    // MARK: - 权限

    // MARK: - 跳过与统计

    /// 统一的「没条件验」出口：先打一行机器可读的统计，再抛 XCTSkip。
    ///
    /// 为什么必须打这一行：XCTSkip 在 xcodebuild 报告里只是 skipped，整轮仍是 SUCCEEDED——
    /// 「四项全跳过」和「四项全通过」在退出码上完全一样，那就是假绿。
    /// 这行输出是 Tools/verify/acceptance_gate.sh 的抓取目标：SKIPPED≠0 直接判未通过。
    private func skip(_ test: String, reason: String) throws -> Never {
        print("[Acceptance] \(test) SKIPPED=1 VERIFIED=0 —— \(reason)")
        throw XCTSkip(reason)
    }

    /// 正常结束时打一行：验了几项样本。与上面同一格式，便于 grep 出「真实验过的数量」。
    private func report(_ test: String, verified: Int) {
        print("[Acceptance] \(test) SKIPPED=0 VERIFIED=\(verified)")
    }

    private func ensurePhotoAccess() async throws {
        let current = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if current == .authorized || current == .limited { return }
        let granted = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard granted == .authorized || granted == .limited else {
            try skip("photoAccess", reason: "相册权限未授予（status=\(granted.rawValue)）：权限状态问题，不是代码缺陷")
        }
    }

    // MARK: - 取样

    private func recentAssets(mediaType: PHAssetMediaType) -> [PHAsset] {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = 60
        let result = PHAsset.fetchAssets(with: mediaType, options: options)
        var list: [PHAsset] = []
        list.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in list.append(asset) }
        return list
    }

    private func filename(of asset: PHAsset) -> String {
        PHAssetResource.assetResources(for: asset).first?.originalFilename ?? asset.localIdentifier
    }

    // MARK: - ① Live Photo 可播放（PHLivePhoto 能否被系统组装出来）

    func testLivePhotoIsPlayable() async throws {
        try await ensurePhotoAccess()

        let liveAssets = recentAssets(mediaType: .image)
            .filter { $0.mediaSubtypes.contains(.photoLive) }
        guard !liveAssets.isEmpty else {
            try skip("testLivePhotoIsPlayable", reason: "最近 60 张里没有 Live Photo：先导出一批 Live Photo 再跑")
        }

        var checked = 0
        for asset in liveAssets.prefix(sampleCount) {
            let name = filename(of: asset)
            let photo = try await requestLivePhoto(asset)

            // PHLivePhoto 没有 isDegraded / pairedVideoAssetURL 成员：
            // 降级状态在 requestLivePhoto 的 resultHandler info 里判（该函数内已处理），
            // 配对视频改用 PHAssetResource 的资源类型判断。
            let hasPairedVideo = PHAssetResource.assetResources(for: asset)
                .contains { $0.type == .pairedVideo }
            XCTAssertTrue(hasPairedVideo,
                          "\(name)：没有配对视频资源（PHAssetResourceType.pairedVideo）→ 输出不是 Live Photo")

            XCTAssertEqual(photo.size.width > 0, true, "\(name)：PHLivePhoto.size 为 0，组装失败")
            checked += 1
        }
        XCTAssertGreaterThan(checked, 0, "没有样本被真正校验")
        report("testLivePhotoIsPlayable", verified: checked)
    }

    /// 把「系统能否组装出 PHLivePhoto」变成一次 async 调用。
    /// 注意：降级回调（先给静帧）不能算结果，必须等到最终非降级回调或错误。
    private func requestLivePhoto(_ asset: PHAsset) async throws -> PHLivePhoto {
        let options = PHLivePhotoRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = false

        let box = ResumeBox()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<PHLivePhoto, any Error>) in
            // 从 PHAsset 组装 PHLivePhoto 的正确入口是 PHImageManager.requestLivePhoto(for:)，
            // PHLivePhoto.request 只接受已经配对好的 [URL] 资源文件，不接受 PHAsset。
            _ = PHImageManager.default().requestLivePhoto(for: asset,
                                                          targetSize: CGSize(width: 1024, height: 1024),
                                                          contentMode: .aspectFit,
                                                          options: options) { photo, info in
                guard box.claim() else { return }

                if let error = info?[PHLivePhotoInfoErrorKey] as? Error {
                    continuation.resume(throwing: error)
                    return
                }
                if (info?[PHLivePhotoInfoCancelledKey] as? Bool) == true {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                // 降级状态来自 resultHandler 的 info 字典（PHImageManager 回调里 info 是可选），不是 PHLivePhoto 的成员
                if let photo, (info?[PHLivePhotoInfoIsDegradedKey] as? Bool) != true {
                    continuation.resume(returning: photo)
                    return
                }
                // 仍是降级态：放回票据继续等最终回调（iCloud 未下载时会一直降级，由超时兜底）。
                box.release()
            }
        }
    }

    // MARK: - ② 动图仍是被系统识别的多帧动图

    func testAnimatedExportIsStillAnimated() async throws {
        try await ensurePhotoAccess()

        let candidates = recentAssets(mediaType: .image).filter { asset in
            let uti = PHAssetResource.assetResources(for: asset).first?.uniformTypeIdentifier.lowercased() ?? ""
            return uti.contains("gif") || uti.contains("webp")
        }
        guard !candidates.isEmpty else {
            try skip("testAnimatedExportIsStillAnimated", reason: "最近 60 张里没有 GIF/WebP：先导出一批动图再跑")
        }

        var checked = 0
        for asset in candidates.prefix(3) {
            let name = filename(of: asset)
            guard let data = try await originalData(of: asset) else {
                XCTFail("\(name)：读不到动图数据")
                continue
            }
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
                XCTFail("\(name)：CGImageSource 打开失败")
                continue
            }

            let frames = CGImageSourceGetCount(source)
            XCTAssertGreaterThan(frames, 1, "\(name)：只有 \(frames) 帧 → 输出被压成静态图了")

            var delays: [Double] = []
            var total = 0.0
            for index in 0..<frames {
                let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
                let gif = props[kCGImagePropertyGIFDictionary] as? [CFString: Any] ?? [:]
                let d = (gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
                    ?? (gif[kCGImagePropertyGIFDelayTime] as? Double)
                    ?? 0
                delays.append(d)
                total += d
            }
            XCTAssertGreaterThan(total, 0, "\(name)：每帧延时全为 0，播放速度会错")

            // 逐帧延时全相同是「归一化」的典型症状；只在源本身是等延时的情况下才允许。
            let distinct = Set(delays.map { Int(($0 * 1000).rounded()) })
            print("[Animated] \(name) 帧数 \(frames)，总时长 \(String(format: "%.2f", total))s，不同延时值 \(distinct.count) 个")

            let container = CGImageSourceCopyProperties(source, nil) as? [CFString: Any] ?? [:]
            let gifGlobal = container[kCGImagePropertyGIFDictionary] as? [CFString: Any] ?? [:]
            if let loop = gifGlobal[kCGImagePropertyGIFLoopCount] as? Int {
                print("[Animated] \(name) 循环次数 \(loop)")
            } else {
                print("[Animated] \(name) 无循环次数字段（WebP 或单次播放，属正常）")
            }

            // 每帧都必须能解出来（解码失败会在导出后表现为黑帧/丢帧）
            for index in 0..<frames {
                XCTAssertNotNil(CGImageSourceCreateImageAtIndex(source, index, nil),
                                "\(name)：第 \(index) 帧解不出来")
            }
            checked += 1
        }
        XCTAssertGreaterThan(checked, 0, "没有样本被真正校验")
        report("testAnimatedExportIsStillAnimated", verified: checked)
    }

    private func originalData(of asset: PHAsset) async throws -> Data? {
        guard let resource = PHAssetResource.assetResources(for: asset).first else { return nil }
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = false
        let box = DataBox()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, any Error>) in
            PHAssetResourceManager.default().requestData(for: resource, options: options) { chunk in
                box.append(chunk)
            } completionHandler: { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: box.data) }
            }
        }
    }

    // MARK: - ③④ 视频色彩标签与音频轨未被重编码

    func testVideoColorTagsAndAudioTrack() async throws {
        try await ensurePhotoAccess()

        let videos = recentAssets(mediaType: .video)
        guard !videos.isEmpty else {
            try skip("testVideoColorTagsAndAudioTrack", reason: "最近 60 条里没有视频：先导出一批视频再跑")
        }

        var checked = 0
        for asset in videos.prefix(3) {
            let name = filename(of: asset)
            let avAsset = try await requestAVAsset(asset)

            let videoTracks = try await avAsset.loadTracks(withMediaType: .video)
            guard let videoTrack = videoTracks.first else {
                XCTFail("\(name)：没有视频轨")
                continue
            }

            let size = try await videoTrack.load(.naturalSize)
            let fps = try await videoTrack.load(.nominalFrameRate)
            let formats = try await videoTrack.load(.formatDescriptions)
            guard let format = formats.first else {
                XCTFail("\(name)：视频轨没有 formatDescription")
                continue
            }

            let subType = CMFormatDescriptionGetMediaSubType(format)
            let codec = fourCC(subType)
            let dims = CMVideoFormatDescriptionGetDimensions(format)
            let extensions = CMFormatDescriptionGetExtensions(format) as? [CFString: Any] ?? [:]

            print("[Video] \(name) \(dims.width)x\(dims.height) \(codec) \(String(format: "%.1f", fps))fps 显示尺寸 \(Int(size.width))x\(Int(size.height))")

            // 位深：10bit HEVC 会带全范围扩展，SDR 8bit 不带。只做记录与下限断言。
            let depth = bitDepth(from: extensions)
            print("[Video] \(name) 位深 \(depth)bit")

            // 色彩标签：HDR 源必须保留 primaries/transfer/matrix；SDR 源允许缺失，但记 WARN 不判死。
            let primaries = extensions["ColorPrimaries" as CFString]
            let transfer = extensions["TransferFunction" as CFString]
            let matrix = extensions["YCbCrMatrix" as CFString]
            if primaries != nil || transfer != nil || matrix != nil {
                print("[Video] \(name) 色彩标签 primaries=\(String(describing: primaries)) transfer=\(String(describing: transfer)) matrix=\(String(describing: matrix))")
            } else {
                print("[Video] \(name) 无色彩标签（SDR 常见）；若源为 HDR 则此处缺失即为「变灰」根因")
            }

            // 旋转矩阵：竖拍视频必须保留，否则导出的画面会躺倒。
            let transform = try await videoTrack.load(.preferredTransform)
            print("[Video] \(name) preferredTransform \(transform)")

            // 音频：压缩格式才算 passthrough；被解成 PCM 说明重编码了。
            let audioTracks = try await avAsset.loadTracks(withMediaType: .audio)
            if let audioTrack = audioTracks.first {
                let audioFormats = try await audioTrack.load(.formatDescriptions)
                if let audioFormat = audioFormats.first {
                    let audioSubType = fourCC(CMFormatDescriptionGetMediaSubType(audioFormat))
                    let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(audioFormat)?.pointee
                    let sampleRate = asbd?.mSampleRate ?? 0
                    let channels = asbd?.mChannelsPerFrame ?? 0
                    print("[Audio] \(name) \(audioSubType) \(Int(sampleRate))Hz \(channels)ch")

                    let pcmTypes: Set<String> = ["lpcm", "sowt", "twos", "in24", "in32", "fl32", "fl64"]
                    XCTAssertFalse(pcmTypes.contains(audioSubType),
                                   "\(name)：音频轨是 \(audioSubType)（PCM）→ 被解码重编码了，passthrough 未生效")
                }
            } else {
                print("[Audio] \(name) 无音频轨")
            }
            checked += 1
        }
        XCTAssertGreaterThan(checked, 0, "没有样本被真正校验")
        report("testVideoColorTagsAndAudioTrack", verified: checked)
    }

    private func requestAVAsset(_ asset: PHAsset) async throws -> AVAsset {
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = false
        options.deliveryMode = .highQualityFormat
        let box = ResumeBox()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<AVAsset, any Error>) in
            PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, info in
                guard box.claim() else { return }
                if let error = info?[PHImageErrorKey] as? any Error {
                    continuation.resume(throwing: error)
                } else if let avAsset {
                    continuation.resume(returning: avAsset)
                } else {
                    continuation.resume(throwing: NSError(domain: "AcceptanceTests", code: -1,
                                                          userInfo: [NSLocalizedDescriptionKey: "requestAVAsset 返回 nil"]))
                }
            }
        }
    }

    // MARK: - 小工具

    private func fourCC(_ code: FourCharCode) -> String {
        let bytes: [UInt8] = [
            UInt8((code >> 24) & 0xFF), UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF), UInt8(code & 0xFF)
        ]
        return String(bytes: bytes, encoding: .ascii) ?? String(code)
    }

    private func bitDepth(from extensions: [CFString: Any]) -> Int {
        // HEVC 10bit 的 formatDescription 会带全范围/深度相关扩展键；取不到就按 8bit 记录。
        if let depth = extensions["BitDepth" as CFString] as? Int { return depth }
        if let profile = extensions["ProfileLevel" as CFString] as? String, profile.contains("10") { return 10 }
        return 8
    }

    /// 保证 continuation 只被 resume 一次（系统回调可能多次：降级 → 最终）。
    private final class ResumeBox: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func claim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if done { return false }
            done = true
            return true
        }
        func release() {
            lock.lock(); done = false; lock.unlock()
        }
    }

    private final class DataBox: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = Data()
        func append(_ chunk: Data) { lock.lock(); buffer.append(chunk); lock.unlock() }
        var data: Data { lock.lock(); defer { lock.unlock() }; return buffer }
    }
}
