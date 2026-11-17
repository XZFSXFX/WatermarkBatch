//
//  ExportService.swift
//  WatermarkBatch（水印工坊 BatchMark）
//
//  块B · 相册写回（契约 §4 `ProcessedOutputBundle` / `ExportSummary` / `ExportService` 签名一字不改）
//
//  写回口径（§六.8）：
//  - **分块** `performChanges`：每块最多 8 个 bundle，块内仍是一次原子写入；
//    photo/animated → `.photo` 资源（data）；video → `.video` 资源（fileURL）；
//    livePhoto → **同一个** PHAssetCreationRequest 内 `.photo` + `.pairedVideo` 双资源
//    （配对标识已在 LivePhotoProcessor 内写好），相册长按可播放；
//  - 保留 creationDate / originalFilename（PHAssetResourceCreationOptions）；
//  - 原图只读：只用 PHAssetCreationRequest 新建，从不 modify/delete 原资产；
//  - albumName 非空 → 「已加水印」相簿（AlbumWriter 幂等 upsert，在同一 change block 内）；
//  - addOnly 授权同样可用（PHAssetCreationRequest 不要求完全访问；相簿归集在 addOnly 下跳过）。
//
//  ── 为什么必须分块（内存，v1.1 峰值目标 <200MB）─────────────────────────
//  视频 / Live Photo 的产物是沙盒 tmp 里的真实文件，performChanges 返回前不能删。
//  100 个 Live Photo 的 still(≈2.5MB) + MOV(≈3.5MB) 若全量驻留 tmp，峰值 ≈600MB，
//  直接击穿目标；分块 8 个后峰值 ≈ 8×6MB + 在飞 2-3 个 ≈ 65MB。
//  每块 performChanges 返回后立刻释放**成功项**的 tmp（见 defer）；失败项保留到用户放弃重试，
//  超过 1 小时且用户未处理时由 ProcessingTempFile.sweepStaleFiles 回收。
//
//  容错：块内原子写入是快路径；某块失败则回退为「块内逐条写入」以定位失败素材，
//  避免一个坏素材拖垮整批（PRD F-16 单任务失败不阻断）。
//

import Foundation
import Photos

// MARK: - 产物包（契约，签名一字不改）

struct ProcessedOutputBundle: Sendable {
    let assetIdentifier: String
    let output: ProcessedOutput
    let originalCreationDate: Date?
    let originalFilename: String?
    let isRawConverted: Bool        // RAW→HEIC 告知标记
    /// v1.2：输出侧说明（PNG 容器变化 + PNG 未携带的元数据分组）。非 PNG 产物为 nil。
    /// var + 默认值：memberwise init 向后兼容（原有 5 参与不变）。
    var outputNote: String? = nil
}

// MARK: - 导出汇总（契约，签名一字不改）

struct ExportSummary: Sendable, Equatable {
    let records: [ExportRecord]     // 每素材一条，含成败与耗时
}

// MARK: - 导出服务

final class ExportService: @unchecked Sendable {

    /// 单块写回数量（8-10 之间取 8）。块越大 tmp 峰值越高，块越小 performChanges 次数越多；
    /// 8 个 Live Photo ≈48MB tmp + 在飞 2-3 个 ≈18MB，离 200MB 目标有足够余量。
    static let writeChunkSize = 8

    // MARK: 依赖

    private let albumWriter: AlbumWriter
    private let recordStore: ExportRecordStore

    init(albumWriter: AlbumWriter = AlbumWriter(),
         recordStore: ExportRecordStore = .shared) {
        self.albumWriter = albumWriter
        self.recordStore = recordStore
    }

    // MARK: 契约 API

    /// 分块 `PHPhotoLibrary.performChanges` 批量写回（每块 8 个 bundle，块内原子）。
    /// - Parameter onRawConversion: RAW 转换告知回调（逐条触发，文案见 PRD §7.2）。
    func saveToLibrary(_ bundles: [ProcessedOutputBundle],
                       albumName: String?,
                       onRawConversion: @Sendable @escaping (String) -> Void) async throws -> ExportSummary {

        guard !bundles.isEmpty else { return ExportSummary(records: []) }

        // 权限前置：addOnly 即可写；denied/restricted 直接给可读错误，不抛系统裸错误。
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if status == .denied || status == .restricted {
            throw WatermarkError.accessDenied
        }

        // RAW 转换逐条告知（绝不静默转换）。
        for bundle in bundles where bundle.isRawConverted {
            onRawConversion(bundle.originalFilename ?? bundle.assetIdentifier)
        }

        let albumTitle = resolvedAlbumTitle(albumName)
        var records: [ExportRecord] = []
        records.reserveCapacity(bundles.count)
        var firstChunkError: Error?
        var firstItemError: Error?

        for chunk in Self.chunked(bundles, size: Self.writeChunkSize) {
            // 本块写成功的产物：块结束立即释放 tmp。
            var succeededInChunk: [ProcessedOutputBundle] = []
            succeededInChunk.reserveCapacity(chunk.count)

            // 只清成功项（成功/失败两条路径都由本 defer 收口）。
            // 失败项的临时文件保留到用户放弃重试；超过 1 小时未处理由
            // ProcessingTempFile.sweepStaleFiles 回收，不会无限堆积。
            defer {
                for bundle in succeededInChunk {
                    bundle.output.cleanupTemporaryFiles()
                }
            }

            let chunkStartedAt = Date()
            do {
                try await performWrite(chunk, albumTitle: albumTitle)
                let finishedAt = Date()
                records.append(contentsOf: chunk.map {
                    makeRecord(for: $0, status: .succeeded,
                               startedAt: chunkStartedAt, finishedAt: finishedAt,
                               errorDescription: nil)
                })
                succeededInChunk.append(contentsOf: chunk)
            } catch {
                if firstChunkError == nil { firstChunkError = error }
                // 回退：块内逐条写入，隔离失败素材（不阻断其余素材）。
                for bundle in chunk {
                    let itemStartedAt = Date()
                    do {
                        try await performWrite([bundle], albumTitle: albumTitle)
                        records.append(makeRecord(for: bundle, status: .succeeded,
                                                  startedAt: itemStartedAt, finishedAt: Date(),
                                                  errorDescription: nil))
                        succeededInChunk.append(bundle)
                    } catch {
                        if firstItemError == nil { firstItemError = error }
                        records.append(makeRecord(for: bundle, status: .failed,
                                                  startedAt: itemStartedAt, finishedAt: Date(),
                                                  errorDescription: Self.describe(error)))
                    }
                }
            }
        }

        recordStore.append(records)

        if records.allSatisfy({ $0.status == .failed }) {
            // 全部失败通常是权限/磁盘/相册不可用，直接把首个错误上抛给 UI 弹窗。
            throw Self.mapWriteError(firstItemError ?? firstChunkError
                                     ?? WatermarkError.writeFailed("写入相册失败"))
        }
        return ExportSummary(records: records)
    }

    // MARK: 便捷（不影响契约）

    /// 兜底清理（幂等）。`saveToLibrary` 每块结束已自动清理成功项，
    /// 本方法供「用户放弃重试」时由 UI 调一次，把失败项的残留也释放掉。
    static func cleanupTemporaryFiles(of bundles: [ProcessedOutputBundle]) {
        for bundle in bundles {
            bundle.output.cleanupTemporaryFiles()
        }
    }

    // MARK: - 分块

    /// 按 size 切块。刻意写成私有静态函数而不是 `Array` 扩展：
    /// 同模块内多人协作时，全局 `chunked(into:)` 扩展极易与别人的同名扩展重复定义。
    private static func chunked<T>(_ items: [T], size: Int) -> [[T]] {
        guard size > 0, items.count > size else {
            return items.isEmpty ? [] : [items]
        }
        return stride(from: 0, to: items.count, by: size).map {
            Array(items[$0..<min($0 + size, items.count)])
        }
    }

    // MARK: - performChanges

    private func performWrite(_ bundles: [ProcessedOutputBundle],
                              albumTitle: String?) async throws {
        let albumWriter = self.albumWriter
        try await PHPhotoLibrary.shared().performChanges {
            var placeholders: [PHObjectPlaceholder] = []
            placeholders.reserveCapacity(bundles.count)

            for bundle in bundles {
                let request = PHAssetCreationRequest.forAsset()
                request.creationDate = bundle.originalCreationDate

                switch bundle.output {
                case .stillImage(let data, _), .animatedImage(let data, _):
                    let options = PHAssetResourceCreationOptions()
                    options.originalFilename = bundle.originalFilename
                    request.addResource(with: .photo, data: data, options: options)

                case .imageFile(let url, _):
                    // v1.2：大图已落 tmp，写回语义与 .stillImage(data:) 完全等价（同一 .photo 资源）。
                    let options = PHAssetResourceCreationOptions()
                    options.originalFilename = bundle.originalFilename
                    request.addResource(with: .photo, fileURL: url, options: options)

                case .livePhoto(let stillData, _, let videoURL):
                    // 双资源必须进同一个 creationRequest，系统才会重建 Live Photo。
                    let stillOptions = PHAssetResourceCreationOptions()
                    stillOptions.originalFilename = bundle.originalFilename
                    request.addResource(with: .photo, data: stillData, options: stillOptions)

                    let videoOptions = PHAssetResourceCreationOptions()
                    videoOptions.originalFilename = Self.pairedVideoFilename(from: bundle.originalFilename)
                    request.addResource(with: .pairedVideo, fileURL: videoURL, options: videoOptions)

                case .video(let url):
                    let options = PHAssetResourceCreationOptions()
                    options.originalFilename = bundle.originalFilename
                    request.addResource(with: .video, fileURL: url, options: options)
                }

                if let placeholder = request.placeholderForCreatedAsset {
                    placeholders.append(placeholder)
                }
            }

            // 相簿归集（幂等 upsert 在同一 change block 内完成）。
            if let albumTitle, !albumTitle.isEmpty,
               let albumRequest = albumWriter.upsertAlbum(named: albumTitle) {
                albumWriter.add(placeholders, to: albumRequest)
            }
        }
    }

    // MARK: - 记录构造

    private func makeRecord(for bundle: ProcessedOutputBundle,
                            status: TaskStatus,
                            startedAt: Date,
                            finishedAt: Date,
                            errorDescription: String?) -> ExportRecord {
        ExportRecord(id: UUID(),
                     assetIdentifier: bundle.assetIdentifier,
                     kind: Self.kind(of: bundle),
                     status: status,
                     startedAt: startedAt,
                     finishedAt: finishedAt,
                     errorDescription: errorDescription,
                     outputUTI: Self.outputUTI(of: bundle),
                     outputNote: bundle.outputNote)
    }

    /// 记录里的实际输出容器（v1.2：`public.png` 表示用户勾选了「PNG 无损」）。
    /// 视频不猜容器（源容器已由 VideoWriterConfig 按源文件类型决定，记录页无需要）。
    private static func outputUTI(of bundle: ProcessedOutputBundle) -> String? {
        switch bundle.output {
        case .stillImage(_, let uti), .imageFile(_, let uti), .animatedImage(_, let uti):
            return uti
        case .livePhoto(_, let stillUTI, _):
            return stillUTI
        case .video:
            return nil
        }
    }

    /// 记录里的素材类型：RAW 转换过的仍标 .raw（UI 要显示「已转 HEIC」提示）。
    private static func kind(of bundle: ProcessedOutputBundle) -> MediaKind {
        if bundle.isRawConverted { return .raw }
        switch bundle.output {
        case .stillImage:   return .photo
        case .imageFile(_, let uti):
            // v1.2：动图落盘后与静态图同形，只能靠 UTI 还原类型（GIF/WebP 动画）。
            return AnimatedImageProcessor.isAnimatedUTI(uti) ? .animated : .photo
        case .animatedImage: return .animated
        case .livePhoto:    return .livePhoto
        case .video:        return .video
        }
    }

    // MARK: - 相簿

    /// addOnly 授权下无法读取相簿集合，跳过归集（仅写入仍完整可用）。
    private func resolvedAlbumTitle(_ albumName: String?) -> String? {
        guard let albumName, !albumName.isEmpty else { return nil }
        let readWrite = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard readWrite == .authorized || readWrite == .limited else { return nil }
        return albumName
    }

    /// Live Photo 配对视频文件名：与静帧同 basename，扩展名 .MOV。
    private static func pairedVideoFilename(from stillFilename: String?) -> String? {
        guard let stillFilename, !stillFilename.isEmpty else { return nil }
        let base = (stillFilename as NSString).deletingPathExtension
        return base.isEmpty ? nil : "\(base).MOV"
    }

    // MARK: - 错误

    private static func describe(_ error: Error) -> String {
        mapWriteError(error).userReadableDescription
    }

    private static func mapWriteError(_ error: Error) -> WatermarkError {
        if let watermarkError = error as? WatermarkError { return watermarkError }
        // 权限在写入过程中被收回（系统设置里关掉）→ 给权限引导，而不是裸写「写入失败」。
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if status == .denied || status == .restricted { return .accessDenied }
        let nsError = error as NSError
        return .writeFailed(nsError.localizedDescription)
    }
}
