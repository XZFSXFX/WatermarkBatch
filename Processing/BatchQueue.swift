//
//  BatchQueue.swift
//  WatermarkBatch（水印工坊 BatchMark）
//
//  块B · 批处理队列（契约 §4 签名一字不改）
//
//  ── 并发（v1.1 最高裁决）──────────────────────────────────────────────
//  - 默认「画质优先」：照片并发 2、视频并发 1；照片槽与视频槽分开计数；
//  - 「优先速度」：照片并发 3-4（physicalMemory ≤4GB→3，>4GB→4，即 recommendedConcurrency）；
//  - 视频恒不并跑：视频/Live Photo 都占用唯一视频槽（Live Photo 也要编一条 MOV）。
//
//  ── 内存（<200MB 目标）──────────────────────────────────────────────
//  派发前用 `os_proc_available_memory` 采样；低于阈值时把「已有一张在跑」的照片槽关掉
//  （降并发、不降画质）；批次结束写日志记录 phys_footprint 峰值供验收核对。
//
//  ── 容错 ───────────────────────────────────────────────────────────
//  - 单任务失败不阻断：错误归入失败清单（文件名 + 原因 + 阶段），继续下一个；
//  - cancel() 幂等：只终止未完成任务，已完成产物保留在 outputs；
//  - outputs 在 stream finish 之后可取（契约要点③）；
//  - 按 assetID 单独重跑：`retryTasks(all:failures:)` + 再次 `run(tasks:)`。
//

import Foundation

// MARK: - 进度事件（契约，签名一字不改）

/// 单条进度事件（UI 逐条消费）。
/// 每个事件都带累计计数（succeeded/failed/total），所以即使 stream 缓冲丢掉了中间帧，
/// UI 也不会算错总数；终态事件（succeeded/failed/cancelled）一定伴随最终计数。
struct BatchProgress: Sendable, Equatable {
    let taskID: UUID
    let assetID: String            // assetIdentifier
    let status: TaskStatus         // running/succeeded/failed/cancelled
    let fractionCompleted: Double  // 单任务 0...1
    let succeededCount: Int
    let failedCount: Int
    let totalCount: Int
    let error: WatermarkError?
}

// MARK: - 批处理队列

final class BatchQueue: @unchecked Sendable {

    // MARK: 契约

    /// 「优先速度」档推荐并发：physicalMemory ≤ 4GB → 3，> 4GB → 4。
    static func recommendedConcurrency(physicalMemoryBytes: UInt64) -> Int {
        ProcessingSettings.speedPhotoConcurrency(physicalMemoryBytes: physicalMemoryBytes)
    }

    /// 批处理主入口。失败单任务不阻断；cancel() 只终止未完成任务，已完成保留。
    /// 返回 AsyncStream，UI 逐条消费；任务全部结束后 stream 正常 finish。
    ///
    /// - Parameter rawConsent: RAW/DNG 显式同意标记。为 false 且批次含 RAW 时整批拒绝启动
    ///   （每个 RAW 任务上报 failed + `rawConversionRequiresConsent`，不静默转换）。
    func run(tasks: [LibraryAsset],
             config: WatermarkConfig,
             rawConsent: Bool,
             processorProvider: @Sendable @escaping (MediaKind) -> any AssetProcessor,
             library: PhotoLibraryService,
             compositor: WatermarkCompositor) -> AsyncStream<BatchProgress> {

        resetState()

        var continuation: AsyncStream<BatchProgress>.Continuation!
        let stream = AsyncStream<BatchProgress>(bufferingPolicy: .unbounded) { streamContinuation in
            continuation = streamContinuation
        }

        let photoLimit = settings.photoConcurrency(
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory
        )

        let task = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else {
                continuation.finish()
                return
            }
            await self.execute(tasks: tasks,
                               config: config,
                               rawConsent: rawConsent,
                               photoLimit: photoLimit,
                               processorProvider: processorProvider,
                               library: library,
                               compositor: compositor,
                               continuation: continuation)
        }

        stateLock.lock()
        runningTask = task
        stateLock.unlock()

        return stream
    }

    /// 幂等取消：只终止未完成任务；已完成任务的产物已在 outputs 中，不回滚。
    func cancel() {
        stateLock.lock()
        if cancelledFlag {
            stateLock.unlock()
            return
        }
        cancelledFlag = true
        let task = runningTask
        let log = activeLog
        stateLock.unlock()

        log?.line("收到取消请求：停止未完成任务，已完成的 \(outputs.count) 个产物保留")
        task?.cancel()
    }

    /// 全部成功产物（stream finish 之后读取）。
    var outputs: [ProcessedOutputBundle] {
        stateLock.lock(); defer { stateLock.unlock() }
        return collectedOutputs
    }

    // MARK: 扩展 API（不影响契约，供 UI 失败清单/记录页使用）

    /// 失败清单（文件名 + 原因 + 阶段）。
    var failures: [BatchFailureItem] {
        stateLock.lock(); defer { stateLock.unlock() }
        return collectedFailures
    }

    /// 本批全部任务记录（含成功项的四阶段耗时）。
    var records: [BatchTaskRecord] {
        stateLock.lock(); defer { stateLock.unlock() }
        return collectedRecords
    }

    /// 本批日志文件（Documents/Logs/…），供「导出日志」。
    var logFileURL: URL? {
        stateLock.lock(); defer { stateLock.unlock() }
        return activeLogFileURL
    }

    var isCancelled: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return cancelledFlag
    }

    /// 调试面板数据源：当前空闲许可 / 等待数（直接读唯一限流器）+ 本批配置上限。
    ///
    /// 为什么要把上限也放进来：UI 调试页要同时看「配了几个」和「还剩几个」，
    /// 否则只能看到空闲数、看不出档位是否真的生效（「优先速度」开关的验收点）。
    func debugSnapshot() async -> [String: Int] {
        stateLock.lock()
        let limiter = activeLimiter
        let photoLimit = configuredPhotoLimit
        let videoLimit = configuredVideoLimit
        stateLock.unlock()

        var snapshot: [String: Int]
        if let limiter {
            snapshot = await limiter.debugSnapshot
        } else {
            snapshot = ["photoFree": photoLimit, "videoFree": videoLimit, "waiting": 0]
        }
        snapshot["photoLimit"] = photoLimit
        snapshot["videoLimit"] = videoLimit
        return snapshot
    }

    /// 失败项 → 待重跑的素材列表（保持原批次顺序；UI 勾选后可再传入 run）。
    static func retryTasks(all: [LibraryAsset], failures: [BatchFailureItem]) -> [LibraryAsset] {
        let failedIDs = Set(failures.map(\.assetIdentifier))
        return all.filter { failedIDs.contains($0.assetIdentifier) }
    }

    // MARK: 依赖

    private let settings: ProcessingSettings
    private let logStore: BatchLogStore

    // MARK: 状态

    private let stateLock = NSLock()
    private var collectedOutputs: [ProcessedOutputBundle] = []
    private var collectedFailures: [BatchFailureItem] = []
    private var collectedRecords: [BatchTaskRecord] = []
    private var cancelledFlag = false
    private var runningTask: Task<Void, Never>?
    private var activeLog: BatchLogWriter?
    private var activeLogFileURL: URL?
    /// 本批唯一限流器（调试面板只读；并发上限的唯一物理执行点）。
    private var activeLimiter: ConcurrencyLimiter?
    private var configuredPhotoLimit = ProcessingSettings.qualityFirstPhotoConcurrency
    private var configuredVideoLimit = ProcessingSettings.defaultVideoConcurrency

    // MARK: 初始化

    /// - Parameter settings: 必须与 `processorProvider` 使用的档位一致
    ///   （「优先速度」同时影响并发数、视频码率系数、JPEG 质量）。
    init(settings: ProcessingSettings = .qualityFirst,
         logStore: BatchLogStore = .shared) {
        self.settings = settings
        self.logStore = logStore
    }

    // MARK: - 执行

    private func execute(tasks: [LibraryAsset],
                         config: WatermarkConfig,
                         rawConsent: Bool,
                         photoLimit: Int,
                         processorProvider: @Sendable @escaping (MediaKind) -> any AssetProcessor,
                         library: PhotoLibraryService,
                         compositor: WatermarkCompositor,
                         continuation: AsyncStream<BatchProgress>.Continuation) async {

        let total = tasks.count
        let log = logStore.beginBatch(label: "批量水印", totalCount: total)
        let peak = BatchMemoryMonitor.PeakTracker()
        let counters = BatchCounters(total: total)

        stateLock.lock()
        activeLog = log
        activeLogFileURL = log.fileURL
        stateLock.unlock()

        // 崩溃残留清理：杀掉 1 小时前未删的产物临时文件。跑在后台任务里，不阻塞调用方。
        let swept = ProcessingTempFile.sweepStaleFiles()
        if swept > 0 { log.line("清理陈旧临时文件 \(swept) 个（>1 小时的崩溃残留）") }

        log.line("参数档 \(settings.tier.rawValue)｜照片并发 \(photoLimit)｜视频并发 1"
                 + "｜rawConsent=\(rawConsent)｜视频码率系数 \(settings.videoBitrateFactor)"
                 + "｜JPEG 质量 \(settings.jpegQuality)")

        guard total > 0 else {
            log.finish(succeeded: 0, failed: 0, cancelled: 0)
            continuation.finish()
            return
        }

        if rawConsent && !settings.rawConsent {
            log.line("警告：run(rawConsent: true) 但处理器档位 settings.rawConsent=false；"
                     + "RAW 处理会因门禁失败。请用 settings.withRawConsent(true) 构造处理器。")
        }

        // ── RAW 门禁：未同意且含 RAW → 整批拒绝启动（不静默转换）────────
        let rawAssets = tasks.filter { $0.kind == .raw }
        if !rawConsent && !rawAssets.isEmpty {
            log.line("RAW 未同意：批次含 \(rawAssets.count) 个 RAW，整批拒绝启动")
            for asset in tasks {
                let taskID = UUID()
                let startedAt = Date()
                let isRaw = asset.kind == .raw
                let error: WatermarkError = isRaw
                    ? .rawConversionRequiresConsent(asset.originalFilename ?? asset.assetIdentifier)
                    : .rawConversionRequiresConsent("本批次含 RAW 素材，需先确认 RAW→HEIC 转换")
                let snapshot = StageSnapshot(durations: [:], lastStage: .reading, totalDuration: 0)
                let record = BatchTaskRecord(taskID: taskID,
                                             assetIdentifier: asset.assetIdentifier,
                                             filename: asset.originalFilename,
                                             kind: asset.kind,
                                             status: .failed,
                                             stageSnapshot: snapshot,
                                             errorDescription: error.userReadableDescription,
                                             startedAt: startedAt,
                                             finishedAt: Date())
                let failure = BatchFailureItem(taskID: taskID,
                                               assetIdentifier: asset.assetIdentifier,
                                               filename: asset.originalFilename,
                                               kind: asset.kind,
                                               stage: .reading,
                                               error: error,
                                               reason: error.userReadableDescription,
                                               occurredAt: Date())
                counters.bumpFailed()
                append(record: record, failure: failure)
                log.record(record)
                let snapshotCounts = counters.snapshot()
                continuation.yield(BatchProgress(taskID: taskID,
                                                assetID: asset.assetIdentifier,
                                                status: .failed,
                                                fractionCompleted: 0,
                                                succeededCount: snapshotCounts.succeeded,
                                                failedCount: snapshotCounts.failed,
                                                totalCount: total,
                                                error: error))
            }
            log.finish(succeeded: 0, failed: total, cancelled: 0)
            log.close()
            continuation.finish()
            return
        }

        // ── 主调度 ───────────────────────────────────────────────────
        // 两层职责（不重复实现同一策略）：
        // ① 调度器（本方法）：决定「谁先跑、哪个任务在跑」，照片/视频分槽，内存压力时收紧照片槽；
        // ② 许可闸门（ConcurrencyLimiter）：并发上限的唯一物理执行点，即使调度器将来被改坏，
        //    「同一时刻最多 1 个视频编码」也不会被破坏。
        let limiter = ConcurrencyLimiter(photoPermits: photoLimit,
                                         videoPermits: settings.videoConcurrency)

        stateLock.lock()
        activeLimiter = limiter
        configuredPhotoLimit = photoLimit
        configuredVideoLimit = settings.videoConcurrency
        stateLock.unlock()

        var pending = tasks
        var runningPhotos = 0
        var runningVideos = 0
        var outcomeCount = 0

        await withTaskGroup(of: TaskOutcome.self) { group in
            while true {
                if isCancelled {
                    // 取消：把尚未启动的任务标记为 cancelled（不阻断已完成产物）
                    while let asset = pending.first {
                        pending.removeFirst()
                        let record = makeCancelledRecord(for: asset)
                        counters.bumpCancelled()
                        append(record: record, failure: nil)
                        log.record(record)
                        outcomeCount += 1
                        let snapshot = counters.snapshot()
                        continuation.yield(BatchProgress(taskID: record.taskID,
                                                        assetID: asset.assetIdentifier,
                                                        status: .cancelled,
                                                        fractionCompleted: 0,
                                                        succeededCount: snapshot.succeeded,
                                                        failedCount: snapshot.failed,
                                                        totalCount: total,
                                                        error: .cancelled))
                    }
                } else {
                    peak.sample()
                    while let index = pending.firstIndex(where: {
                        canLaunch($0, runningPhotos: runningPhotos,
                                  runningVideos: runningVideos, photoLimit: photoLimit)
                    }) {
                        let asset = pending.remove(at: index)
                        let isVideoSlot = (asset.kind == .video || asset.kind == .livePhoto)
                        if isVideoSlot { runningVideos += 1 } else { runningPhotos += 1 }

                        let taskID = UUID()
                        let processor = processorProvider(asset.kind)
                        let lane: ConcurrencyLimiter.Lane = isVideoSlot ? .video : .photo
                        let reporter = TaskProgressReporter(taskID: taskID,
                                                            assetID: asset.assetIdentifier,
                                                            total: total,
                                                            counters: counters,
                                                            continuation: continuation)
                        group.addTask { [weak self] in
                            guard let self else {
                                let now = Date()
                                let record = BatchTaskRecord(taskID: taskID,
                                                             assetIdentifier: asset.assetIdentifier,
                                                             filename: asset.originalFilename,
                                                             kind: asset.kind,
                                                             status: .cancelled,
                                                             stageSnapshot: .empty,
                                                             errorDescription: nil,
                                                             startedAt: now,
                                                             finishedAt: now)
                                return .cancelled(record)
                            }
                            return await self.processOne(asset: asset,
                                                         taskID: taskID,
                                                         config: config,
                                                         processor: processor,
                                                         library: library,
                                                         compositor: compositor,
                                                         reporter: reporter,
                                                         limiter: limiter,
                                                         lane: lane)
                        }
                    }
                }

                if runningPhotos == 0 && runningVideos == 0 && pending.isEmpty {
                    break
                }

                guard let outcome = await group.next() else { break }

                switch outcome {
                case .succeeded(let record, let bundle):
                    if record.kind == .video || record.kind == .livePhoto {
                        runningVideos = max(0, runningVideos - 1)
                    } else {
                        runningPhotos = max(0, runningPhotos - 1)
                    }
                    counters.bumpSucceeded()
                    append(record: record, output: bundle)
                    log.record(record)
                    // 用户勾选「输出 PNG 无损」时留痕：容器变化 + PNG 承载不了的元数据分组，
                    // 逐项写进批次日志（同一条 note 也会随 bundle 进导出记录）。
                    if let note = bundle.outputNote {
                        log.line("\(note)：\(record.filename ?? record.assetIdentifier)")
                    }
                    outcomeCount += 1
                    let snapshot = counters.snapshot()
                    continuation.yield(BatchProgress(taskID: record.taskID,
                                                    assetID: record.assetIdentifier,
                                                    status: .succeeded,
                                                    fractionCompleted: 1,
                                                    succeededCount: snapshot.succeeded,
                                                    failedCount: snapshot.failed,
                                                    totalCount: total,
                                                    error: nil))

                case .failed(let record, let failure):
                    if record.kind == .video || record.kind == .livePhoto {
                        runningVideos = max(0, runningVideos - 1)
                    } else {
                        runningPhotos = max(0, runningPhotos - 1)
                    }
                    counters.bumpFailed()
                    append(record: record, failure: failure)
                    log.record(record)
                    outcomeCount += 1
                    let snapshot = counters.snapshot()
                    continuation.yield(BatchProgress(taskID: record.taskID,
                                                    assetID: record.assetIdentifier,
                                                    status: .failed,
                                                    fractionCompleted: record.stageSnapshot.totalDuration > 0 ? 1 : 0,
                                                    succeededCount: snapshot.succeeded,
                                                    failedCount: snapshot.failed,
                                                    totalCount: total,
                                                    error: failure.mapToWatermarkError()))

                case .cancelled(let record):
                    if record.kind == .video || record.kind == .livePhoto {
                        runningVideos = max(0, runningVideos - 1)
                    } else {
                        runningPhotos = max(0, runningPhotos - 1)
                    }
                    counters.bumpCancelled()
                    append(record: record, failure: nil)
                    log.record(record)
                    outcomeCount += 1
                    let snapshot = counters.snapshot()
                    continuation.yield(BatchProgress(taskID: record.taskID,
                                                    assetID: record.assetIdentifier,
                                                    status: .cancelled,
                                                    fractionCompleted: 0,
                                                    succeededCount: snapshot.succeeded,
                                                    failedCount: snapshot.failed,
                                                    totalCount: total,
                                                    error: .cancelled))
                }
            }
        }

        peak.sample()
        log.line(peak.summaryLine())
        log.line("调度结算：\(outcomeCount) 个任务")
        let final = counters.snapshot()
        log.finish(succeeded: final.succeeded, failed: final.failed, cancelled: final.cancelled)
        log.close()

        stateLock.lock()
        activeLog = nil
        activeLimiter = nil
        stateLock.unlock()

        continuation.finish()
    }

    // MARK: - 单任务

    private func processOne(asset: LibraryAsset,
                            taskID: UUID,
                            config: WatermarkConfig,
                            processor: any AssetProcessor,
                            library: PhotoLibraryService,
                            compositor: WatermarkCompositor,
                            reporter: TaskProgressReporter,
                            limiter: ConcurrencyLimiter,
                            lane: ConcurrencyLimiter.Lane) async -> TaskOutcome {

        let startedAt = Date()
        let recorder = StageRecorder()
        reporter.update(0)

        do {
            var output = try await limiter.withPermit(lane) {
                try await ProcessingTrace.$recorder.withValue(recorder) {
                    try await processor.process(asset: asset,
                                                config: config,
                                                library: library,
                                                compositor: compositor) { fraction in
                        reporter.update(fraction)
                    }
                }
            }
            recorder.finish()

            // v1.2 内存红线：>256KB 的图产物立刻落 tmp 并转 .imageFile，释放 Data。
            // 用重赋值而不是新增一个变量：旧枚举值失去唯一强引用后，其 Data 立即被 ARC 释放
            //（对应裁决里的「原 Data 引用置 nil」）。时机在 permit 之后、构造 bundle 之前，
            // 所以 collectedOutputs 追加的一定已是落盘形态，常驻内存不随批量线性增长。
            output = output.spilledToDiskIfLarge()
            let outputNote = Self.pngNote(for: output)

            let record = BatchTaskRecord(taskID: taskID,
                                         assetIdentifier: asset.assetIdentifier,
                                         filename: asset.originalFilename,
                                         kind: asset.kind,
                                         status: .succeeded,
                                         stageSnapshot: recorder.snapshot(),
                                         errorDescription: nil,
                                         startedAt: startedAt,
                                         finishedAt: Date())
            let bundle = ProcessedOutputBundle(assetIdentifier: asset.assetIdentifier,
                                               output: output,
                                               originalCreationDate: asset.creationDate,
                                               originalFilename: asset.originalFilename,
                                               isRawConverted: asset.kind == .raw,
                                               outputNote: outputNote)
            return .succeeded(record, bundle)
        } catch {
            // 阶段要在 finish 之前取：finish 会清空 currentStage。
            let stageAtFailure = recorder.activeStage ?? .reading
            recorder.finish()
            let snapshot = recorder.snapshot()
            let mapped = Self.mapError(error)

            if mapped == .cancelled {
                let record = BatchTaskRecord(taskID: taskID,
                                             assetIdentifier: asset.assetIdentifier,
                                             filename: asset.originalFilename,
                                             kind: asset.kind,
                                             status: .cancelled,
                                             stageSnapshot: snapshot,
                                             errorDescription: nil,
                                             startedAt: startedAt,
                                             finishedAt: Date())
                return .cancelled(record)
            }

            let record = BatchTaskRecord(taskID: taskID,
                                         assetIdentifier: asset.assetIdentifier,
                                         filename: asset.originalFilename,
                                         kind: asset.kind,
                                         status: .failed,
                                         stageSnapshot: snapshot,
                                         errorDescription: mapped.userReadableDescription,
                                         startedAt: startedAt,
                                         finishedAt: Date())
            let failure = BatchFailureItem(taskID: taskID,
                                           assetIdentifier: asset.assetIdentifier,
                                           filename: asset.originalFilename,
                                           kind: asset.kind,
                                           stage: stageAtFailure,
                                           error: mapped,
                                           reason: mapped.userReadableDescription,
                                           occurredAt: Date())
            return .failed(record, failure)
        }
    }

    // MARK: - 调度判定

    /// 是否可立刻派发（照片/视频分槽；内存压力时照片降到 1）。
    private func canLaunch(_ asset: LibraryAsset,
                           runningPhotos: Int,
                           runningVideos: Int,
                           photoLimit: Int) -> Bool {
        switch asset.kind {
        case .video, .livePhoto:
            return runningVideos < settings.videoConcurrency
        case .photo, .raw, .animated:
            guard runningPhotos < photoLimit else { return false }
            if runningPhotos >= 1, BatchMemoryMonitor.isUnderPressure() {
                // 降并发、不降画质：已有一张在跑就让出内存，等它结束再派发。
                return false
            }
            return true
        }
    }

    // MARK: - 状态写入

    private func append(record: BatchTaskRecord,
                        output: ProcessedOutputBundle? = nil,
                        failure: BatchFailureItem? = nil) {
        stateLock.lock(); defer { stateLock.unlock() }
        collectedRecords.append(record)
        if let output { collectedOutputs.append(output) }
        if let failure { collectedFailures.append(failure) }
    }

    private func resetState() {
        stateLock.lock(); defer { stateLock.unlock() }
        collectedOutputs.removeAll()
        collectedFailures.removeAll()
        collectedRecords.removeAll()
        cancelledFlag = false
        runningTask = nil
        activeLimiter = nil
    }

    private func makeCancelledRecord(for asset: LibraryAsset) -> BatchTaskRecord {
        let now = Date()
        return BatchTaskRecord(taskID: UUID(),
                               assetIdentifier: asset.assetIdentifier,
                               filename: asset.originalFilename,
                               kind: asset.kind,
                               status: .cancelled,
                               stageSnapshot: StageSnapshot(durations: [:],
                                                            lastStage: nil,
                                                            totalDuration: 0),
                               errorDescription: nil,
                               startedAt: now,
                               finishedAt: now)
    }

    // MARK: - 错误映射

    /// PNG 容器标注（v1.2）：用户勾选「输出 PNG 无损」时，容器变化与「PNG 承载不了的
    /// 元数据分组」必须写进日志与导出记录——不允许静默丢弃。
    /// 非 PNG 产物返回 nil（绝大多数任务）。
    static func pngNote(for output: ProcessedOutput) -> String? {
        guard output.isPNGContainer else { return nil }
        var note = "容器按用户勾选改为 PNG（无损、保 alpha、位深不降）"
        let missing = EXIFPreserver.pngMissingMetadataGroups(in: output)
        if !missing.isEmpty {
            note += "；PNG 容器未携带：\(missing.joined(separator: "/"))"
        }
        return note
    }

    /// 任意错误 → WatermarkError（杜绝裸错误漏出，§六 非功能基线）。
    static func mapError(_ error: Error) -> WatermarkError {
        if let watermarkError = error as? WatermarkError { return watermarkError }
        if error is CancellationError { return .cancelled }
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain { return .writeFailed(nsError.localizedDescription) }
        return .renderFailed(nsError.localizedDescription)
    }
}

// MARK: - 任务结果

private enum TaskOutcome: Sendable {
    case succeeded(BatchTaskRecord, ProcessedOutputBundle)
    case failed(BatchTaskRecord, BatchFailureItem)
    case cancelled(BatchTaskRecord)
}

// MARK: - 计数器

/// 批次计数（多任务并发更新）。
private final class BatchCounters: @unchecked Sendable {
    let total: Int
    private let lock = NSLock()
    private var succeededCount = 0
    private var failedCount = 0
    private var cancelledCount = 0

    init(total: Int) { self.total = total }

    func bumpSucceeded() { lock.lock(); succeededCount += 1; lock.unlock() }
    func bumpFailed() { lock.lock(); failedCount += 1; lock.unlock() }
    func bumpCancelled() { lock.lock(); cancelledCount += 1; lock.unlock() }

    func snapshot() -> (succeeded: Int, failed: Int, cancelled: Int) {
        lock.lock(); defer { lock.unlock() }
        return (succeededCount, failedCount, cancelledCount)
    }
}

// MARK: - 进度上报（节流）

/// 单任务进度上报器：把 0...1 的原始进度节流后写入 AsyncStream。
/// 每个事件都带累计计数，故 UI 即使丢掉中间帧也不会算错总数。
private final class TaskProgressReporter: @unchecked Sendable {
    private let taskID: UUID
    private let assetID: String
    private let total: Int
    private let counters: BatchCounters
    private let continuation: AsyncStream<BatchProgress>.Continuation

    private let lock = NSLock()
    private var lastFraction: Double = -1
    private var lastEmitAt = Date.distantPast

    init(taskID: UUID,
         assetID: String,
         total: Int,
         counters: BatchCounters,
         continuation: AsyncStream<BatchProgress>.Continuation) {
        self.taskID = taskID
        self.assetID = assetID
        self.total = total
        self.counters = counters
        self.continuation = continuation
    }

    func update(_ fraction: Double) {
        let value = min(max(fraction, 0), 1)
        lock.lock()
        let now = Date()
        let shouldEmit = value - lastFraction >= 0.05
            || now.timeIntervalSince(lastEmitAt) >= 0.4
            || value >= 1
        if shouldEmit {
            lastFraction = value
            lastEmitAt = now
        }
        lock.unlock()
        guard shouldEmit else { return }

        let snapshot = counters.snapshot()
        continuation.yield(BatchProgress(taskID: taskID,
                                         assetID: assetID,
                                         status: .running,
                                         fractionCompleted: value,
                                         succeededCount: snapshot.succeeded,
                                         failedCount: snapshot.failed,
                                         totalCount: total,
                                         error: nil))
    }
}

// MARK: - 失败项 → 错误（UI 二次确认/重试提示用）

extension BatchFailureItem {
    /// 结构化错误原样返回（保留「可重试」语义：iCloud 下载失败可重试）。
    /// 早期版本曾用中文文案反解错误类型，字符串一改就失效，故改为直接持有 WatermarkError。
    func mapToWatermarkError() -> WatermarkError { error }
}
