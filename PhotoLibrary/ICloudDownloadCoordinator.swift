//
//  ICloudDownloadCoordinator.swift
//  WatermarkBatch（水印工坊 BatchMark）
//
//  块A · iCloud 原图下载协调器（PRD F-02 红线）
//  职责：PHAssetResourceManager 下载原图资源，带进度回调；首次失败后最多重试 3 次
//  （退避 0.5s/1.5s/4s）；彻底失败抛 iCloudDownloadFailed——绝不静默降级为缩略图。
//

import Foundation
import Photos

final class ICloudDownloadCoordinator: @unchecked Sendable {

    /// 首次失败后的最大重试次数（契约：内部最多重试 3 次 → 至多 1+3 次尝试）。
    private let maxRetries = 3
    private let retryDelays: [UInt64] = [500_000_000, 1_500_000_000, 4_000_000_000]

    init() {}

    // MARK: - 公开 API

    /// 下载资源到内存（照片/Live 静帧原图数据）。
    /// - Parameter progress: 0...1；每次尝试从资源管理器取实时进度，成功后强制上报 1.0。
    func resourceData(for resource: PHAssetResource,
                      progress: @Sendable @escaping (Double) -> Void) async throws -> Data {
        progress(0)
        var lastError: Error?
        for attempt in 0...maxRetries {
            do {
                let data = try await downloadDataOnce(resource, progress: progress)
                progress(1)
                return data
            } catch {
                // 任务取消不重试，直接上抛（映射为 WatermarkError.cancelled 由上层处理）
                if error is CancellationError || Task.isCancelled { throw error }
                lastError = error
                if attempt < maxRetries, attempt < retryDelays.count {
                    try await Task.sleep(nanoseconds: retryDelays[attempt])
                }
            }
        }
        _ = lastError // 诊断信息保留在系统错误内；对外统一走契约错误
        throw WatermarkError.iCloudDownloadFailed(assetIdentifier: resource.assetLocalIdentifier)
    }

    /// 资源字节直拷到文件（Live Photo 配对 MOV 等）。
    /// PHAssetResourceManager.writeData 为字节级透传拷贝——不重编码、不改容器，
    /// 满足「原样保留」要求。
    func writeResource(_ resource: PHAssetResource,
                       to destination: URL,
                       progress: @Sendable @escaping (Double) -> Void) async throws {
        progress(0)
        for attempt in 0...maxRetries {
            do {
                try await writeResourceOnce(resource, to: destination, progress: progress)
                progress(1)
                return
            } catch {
                if error is CancellationError || Task.isCancelled { throw error }
                if attempt < maxRetries, attempt < retryDelays.count {
                    try await Task.sleep(nanoseconds: retryDelays[attempt])
                }
            }
        }
        throw WatermarkError.iCloudDownloadFailed(assetIdentifier: resource.assetLocalIdentifier)
    }

    // MARK: - 单次尝试

    private func makeOptions(progress: @Sendable @escaping (Double) -> Void) -> PHAssetResourceRequestOptions {
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true   // iCloud 原图必须允许联网拉取
        options.progressHandler = { value in
            progress(value)
        }
        return options
    }

    private func downloadDataOnce(_ resource: PHAssetResource,
                                  progress: @Sendable @escaping (Double) -> Void) async throws -> Data {
        nonisolated(unsafe) let options = makeOptions(progress: progress)
        return try await withCheckedThrowingContinuation { continuation in
            // PHAssetResourceManager 的 block 为非并发域 ObjC 回调；accumulator 仅在
            // dataReceivedHandler 单一流内追加，completion 单次回调——无数据竞争。
            let accumulator = NSMutableData()
            PHAssetResourceManager.default().requestData(
                for: resource,
                options: options,
                dataReceivedHandler: { chunk in
                    accumulator.append(chunk)
                },
                completionHandler: { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: accumulator as Data)
                    }
                }
            )
        }
    }

    private func writeResourceOnce(_ resource: PHAssetResource,
                                    to destination: URL,
                                    progress: @Sendable @escaping (Double) -> Void) async throws {
        nonisolated(unsafe) let options = makeOptions(progress: progress)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHAssetResourceManager.default().writeData(
                for: resource,
                toFile: destination,
                options: options,
                completionHandler: { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            )
        }
    }
}
