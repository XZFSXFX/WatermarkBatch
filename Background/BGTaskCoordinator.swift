//
//  BGTaskCoordinator.swift
//  WatermarkBatch（水印工坊 BatchMark）
//
//  块B · 后台续跑（§七 BGProcessingTask）
//
//  机制：
//  ① 批任务启动时把「待办清单（assetIdentifier 列表 + WatermarkConfig + rawConsent + 档位）」
//     落盘到 `Documents/PendingBatch.json`，并向 BGTaskScheduler 提交 `com.watermarkbatch.export`；
//  ② 系统在后台唤起后，从清单重建 LibraryAsset（PHAsset fetch + 稳定 ID 派生）→ 重建 BatchQueue 续跑；
//  ③ expirationHandler：`batchQueue.cancel()`（幂等、不回滚已完成）+ 把「未完成项」重新落盘；
//  ④ 续跑完成的产物照常经 ExportService 一次 performChanges 写回。
//
//  Info.plist 必需键（块C 负责）：BGTaskSchedulerPermittedIdentifiers = ["com.watermarkbatch.export"]、
//  UIBackgroundModes 含 "processing"。
//

import BackgroundTasks
import Foundation
import Photos

// MARK: - 待办描述

/// 后台续跑的持久化描述（Codable：WatermarkConfig 本身已 Codable）。
struct PendingBatchDescriptor: Codable, Sendable {
    var assetIdentifiers: [String]
    var config: WatermarkConfig
    var rawConsent: Bool
    var tier: ProcessingTier
    var createdAt: Date
    var originalTotalCount: Int

    /// 当前剩余项（每次续跑后会被更新）。
    var remainingCount: Int { assetIdentifiers.count }
}

// MARK: - 待办存储/// `Documents/PendingBatch.json`：单文件原子读写。
struct PendingBatchStore: Sendable {

    private var fileURL: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("PendingBatch.json")
    }

    func load() -> PendingBatchDescriptor? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(PendingBatchDescriptor.self, from: data)
    }

    func save(_ descriptor: PendingBatchDescriptor) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(descriptor)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
    }

    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}

// MARK: - 任务完成封装

/// BGTask 不是 Sendable（系统对象），但必须在异步任务里调用 `setTaskCompleted`。
/// 用一个极薄的 @unchecked Sendable 包装器隔离，避免在 Swift 6 下把非 Sendable 值
/// 直接捕进 `Task {}`。包装器只做一次转发，不持有其它可变状态。
private final class TaskCompletionBox: @unchecked Sendable {
    private let task: BGTask
    init(_ task: BGTask) { self.task = task }
    func complete(success: Bool) { task.setTaskCompleted(success: success) }
}

// MARK: - 协调器

final class BGTaskCoordinator: @unchecked Sendable {

    static let shared = BGTaskCoordinator()

    /// 与 Info.plist `BGTaskSchedulerPermittedIdentifiers` 必须一致。
    static let taskIdentifier = "com.watermarkbatch.export"

    private let store = PendingBatchStore()
    private let lock = NSLock()
    private var isRegistered = false
    private var activeQueue: BatchQueue?

    init() {}

    // MARK: 注册（App 启动时调用，必须早于 didFinishLaunching 结束）

    func register() {
        lock.lock()
        if isRegistered {
            lock.unlock()
            return
        }
        isRegistered = true
        lock.unlock()

        _ = BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.taskIdentifier, using: nil) { [weak self] task in
            guard let self, let processingTask = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            self.handle(processingTask)
        }
    }

    // MARK: 提交

    /// 前台启动批处理时调用：落盘待办 + 向系统申请后台续跑时间片。
    /// - Note: `requiresNetworkConnectivity = false` 按 §七 口径；iCloud 素材若未下载，
    ///   续跑时会以 iCloudDownloadFailed 进失败清单（可重试），不会静默降级。
    @discardableResult
    func submit(assetIdentifiers: [String],
                config: WatermarkConfig,
                rawConsent: Bool,
                tier: ProcessingTier) -> Bool {
        guard !assetIdentifiers.isEmpty else { return false }
        let descriptor = PendingBatchDescriptor(assetIdentifiers: assetIdentifiers,
                                                config: config,
                                                rawConsent: rawConsent,
                                                tier: tier,
                                                createdAt: Date(),
                                                originalTotalCount: assetIdentifiers.count)
        do {
            try store.save(descriptor)
        } catch {
            let writer = BatchLogStore.shared.beginBatch(label: "后台提交", totalCount: 0)
            writer.line("待办清单落盘失败：\(error.localizedDescription)")
            writer.close()
            return false
        }

        let request = BGProcessingTaskRequest(identifier: Self.taskIdentifier)
        request.requiresNetworkConnectivity = false
        request.requiresExternalPower = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: 60)
        do {
            try BGTaskScheduler.shared.submit(request)
            return true
        } catch {
            // 模拟器/后台刷新被用户关闭时会失败：不影响前台批处理，仅失去续跑能力。
            return false
        }
    }

    /// 前台批次已全部完成（或用户放弃）时清理待办。
    func clearPending() {
        store.clear()
        lock.lock(); activeQueue = nil; lock.unlock()
    }

    var pendingDescriptor: PendingBatchDescriptor? {
        store.load()
    }

    // MARK: 后台唤起

    private func handle(_ task: BGProcessingTask) {
        guard let descriptor = store.load(), !descriptor.assetIdentifiers.isEmpty else {
            task.setTaskCompleted(success: false)
            return
        }

        let settings = descriptor.tier == .preferSpeed
            ? ProcessingSettings.preferSpeed
            : ProcessingSettings.qualityFirst
        let effectiveSettings = settings.withRawConsent(descriptor.rawConsent)

        let library = PhotoLibraryService()
        let compositor = WatermarkCompositor.shared
        let queue = BatchQueue(settings: settings)

        lock.lock()
        activeQueue = queue
        lock.unlock()

        // 系统即将收回时间片：取消（幂等）+ 落盘剩余清单。
        task.expirationHandler = { [weak self] in
            queue.cancel()
            self?.persistRemaining(from: descriptor, queue: queue)
        }

        let assets = Self.rebuildAssets(identifiers: descriptor.assetIdentifiers)
        guard !assets.isEmpty else {
            // 素材被删除/权限变化：没有可续跑项，直接收尾并清空待办。
            clearPending()
            task.setTaskCompleted(success: false)
            return
        }
        // RAW 未同意：不要在后台反复重试一个永远失败的批次（前台必须先弹窗确认）。
        if !descriptor.rawConsent, assets.contains(where: { $0.kind == .raw }) {
            clearPending()
            task.setTaskCompleted(success: false)
            return
        }

        let completion = TaskCompletionBox(task)

        let stream = queue.run(tasks: assets,
                               config: descriptor.config,
                               rawConsent: descriptor.rawConsent,
                               processorProvider: AssetProcessorFactory.provider(settings: effectiveSettings),
                               library: library,
                               compositor: compositor)

        Task { [weak self] in
            guard let self else {
                completion.complete(success: false)
                return
            }
            var settled = Set<String>()
            for await progress in stream {
                if progress.status == .succeeded || progress.status == .failed || progress.status == .cancelled {
                    settled.insert(progress.assetID)
                }
            }

            let outputs = queue.outputs
            guard !outputs.isEmpty else {
                self.persistRemaining(from: descriptor, queue: queue, settled: settled)
                completion.complete(success: false)
                return
            }

            do {
                let summary = try await ExportService().saveToLibrary(
                    outputs,
                    albumName: AlbumWriter.defaultAlbumName,
                    onRawConversion: { _ in /* RAW 已在批次启动前告知；后台续跑不重复弹窗 */ }
                )
                // 临时文件由 ExportService 在分块写回的 chunk 内 defer 清理（只清成功项，
                // 失败项保留到用户放弃重试）；崩溃/被杀残留由 ProcessingTempFile.sweepStaleFiles 回收。
                // 此处不再重复清理——否则后台路径会把失败项的 tmp 也删掉，与保留策略冲突。

                let failed = summary.records.filter { $0.status == .failed }.count
                if failed == 0 && queue.failures.isEmpty {
                    self.clearPending()
                } else {
                    self.persistRemaining(from: descriptor, queue: queue, settled: settled)
                }
                completion.complete(success: failed == 0)
            } catch {
                self.persistRemaining(from: descriptor, queue: queue, settled: settled)
                completion.complete(success: false)
            }
        }
    }

    // MARK: 剩余清单

    /// 把「未完成 + 失败（可重跑）」的素材写回待办清单，供下次后台唤起或前台「重试失败项」。
    private func persistRemaining(from descriptor: PendingBatchDescriptor,
                                  queue: BatchQueue,
                                  settled: Set<String> = []) {
        let failedIDs = Set(queue.failures.map(\.assetIdentifier))
        let remaining = descriptor.assetIdentifiers.filter { identifier in
            if failedIDs.contains(identifier) { return true }
            return !settled.contains(identifier)
        }
        if remaining.isEmpty {
            clearPending()
            return
        }
        var updated = descriptor
        updated.assetIdentifiers = remaining
        try? store.save(updated)

        lock.lock(); activeQueue = nil; lock.unlock()
    }

    // MARK: 素材重建

    /// assetIdentifier → LibraryAsset（顺序与清单一致；已删除的素材自动跳过）。
    static func rebuildAssets(identifiers: [String]) -> [LibraryAsset] {
        guard !identifiers.isEmpty else { return [] }
        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        var byIdentifier: [String: LibraryAsset] = [:]
        fetch.enumerateObjects { asset, _, _ in
            byIdentifier[asset.localIdentifier] = PhotoLibraryService.makeLibraryAsset(from: asset)
        }
        return identifiers.compactMap { byIdentifier[$0] }
    }
}
