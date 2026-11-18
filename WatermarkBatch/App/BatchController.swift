//
//  BatchController.swift
//  WatermarkBatch（水印工坊 BatchMark）
//
//  块C · 批量任务状态机（消费块B 的 BatchQueue / ExportService）
//
//  职责：
//  1) 把「选中素材 + 水印配置 + 处理策略」交给 BatchQueue，逐条消费 AsyncStream<BatchProgress>；
//  2) 维护逐任务进度、成功/失败/取消计数、总进度（全部在 MainActor，UI 不阻塞）；
//  3) stream finish 后取 `queue.outputs` 交 ExportService 一次写库；
//  4) 汇总为 BatchHistoryRecord 落盘（导出记录页数据源），并触发完成通知；
//  5) 失败清单（文件名/原因/阶段）文本导出与「勾选失败项单独重跑」。
//
//  并发：BatchQueue/@unchecked Sendable，工作全在其内部 TaskGroup；本类只做 UI 状态聚合。
//

import Foundation

// MARK: - 单任务 UI 状态

struct BatchItemState: Identifiable, Equatable, Sendable {
    let id: UUID                  // = LibraryAsset.id
    let assetID: String           // = assetIdentifier
    let filename: String
    let kind: MediaKind
    var status: TaskStatus = .pending
    var fraction: Double = 0
    /// 失败原因（WatermarkError.userReadableDescription，禁止裸字符串）。
    var errorText: String?
    /// 失败阶段（取原图 / 下载 / 渲染 / 编码 / 写入）。
    var stageText: String?
    var startedAt: Date?
    var duration: TimeInterval?
}

// MARK: - 历史记录（导出记录页数据源）

struct BatchHistoryItem: Codable, Identifiable, Sendable, Equatable {
    let id: UUID
    let assetIdentifier: String
    let filename: String
    let kind: MediaKind
    let status: TaskStatus
    let errorText: String?
    let stageText: String?
    let duration: TimeInterval?
    /// v1.2：块B ExportService 写入的实际输出容器 UTI（如 `public.png`）。
    /// 默认 nil + 可选：旧 BatchHistory.json 解码不受影响；块C 只展示不推导。
    var outputUTI: String? = nil
    /// v1.2：输出侧说明（PNG 容器变化 + PNG 未携带的元数据分组），非 PNG 产物为 nil。
    var outputNote: String? = nil
}

struct BatchHistoryRecord: Codable, Identifiable, Sendable, Equatable {
    let id: UUID
    let startedAt: Date
    let finishedAt: Date
    let assetCount: Int
    let succeededCount: Int
    let failedCount: Int
    let cancelledCount: Int
    let items: [BatchHistoryItem]

    var duration: TimeInterval { finishedAt.timeIntervalSince(startedAt) }

    /// 「成功 98 / 失败 2」。
    var countSummary: String {
        var text = "成功 \(succeededCount)"
        if failedCount > 0 { text += " / 失败 \(failedCount)" }
        if cancelledCount > 0 { text += " / 取消 \(cancelledCount)" }
        return text
    }
}

/// 导出记录持久化（Documents JSON，保留最近 50 批 / 90 天）。
/// 说明：契约未规定块B `ExportRecordStore` 的 API，块C 自持一份「批次级」历史以免与逐素材记录耦合；
/// 若块B 的存储落地后可一对一切换（见 README 对齐点）。
enum BatchHistoryStore {

    private static let maxRecords = 50
    private static let maxAgeDays = 90

    private static var fileURL: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("BatchHistory.json", isDirectory: false)
    }

    static func load() -> [BatchHistoryRecord] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let records = try? decoder.decode([BatchHistoryRecord].self, from: data) else { return [] }
        return prune(records)
    }

    static func save(_ records: [BatchHistoryRecord]) {
        let trimmed = prune(records)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(trimmed) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private static func prune(_ records: [BatchHistoryRecord]) -> [BatchHistoryRecord] {
        let cutoff = Date().addingTimeInterval(-Double(maxAgeDays) * 86_400)
        let sorted = records.sorted { $0.startedAt > $1.startedAt }
        return Array(sorted.filter { $0.startedAt >= cutoff }.prefix(maxRecords))
    }
}

// MARK: - 批量控制器

@MainActor
@Observable
final class BatchController {

    // 任务清单与进度
    var items: [BatchItemState] = []
    var isRunning = false
    /// 队列跑完、正在写相册（写库阶段也属于「处理中」，取消不再生效）。
    var isExporting = false
    var succeededCount = 0
    var failedCount = 0
    var cancelledCount = 0
    var startedAt: Date?
    var finishedAt: Date?

    // 增强信息
    var rawConversionNotes: [String] = []
    var exportErrorMessage: String?

    // 块B 队列的结构化结果（收尾时快照；失败清单/记录页直接复用）
    private(set) var lastFailures: [BatchFailureItem] = []
    private(set) var lastTaskRecords: [BatchTaskRecord] = []
    private(set) var lastLogFileURL: URL?

    // 隐藏调试面板数据
    var memoryPeakMB: Double = 0
    var activeTaskCount: Int = 0
    var totalDuration: TimeInterval = 0
    var completedRecord: BatchHistoryRecord?

    // 回调（AppModel 注入：落历史、发通知）
    var onBatchFinished: (@MainActor (BatchHistoryRecord) -> Void)?
    var onNotify: (@MainActor (Int, Int) -> Void)?

    // 运行期依赖（重跑失败项时复用）
    private var queue: BatchQueue?
    private var runTask: Task<Void, Never>?
    private var memoryTask: Task<Void, Never>?
    private var library: PhotoLibraryService?
    private var compositor: WatermarkCompositor?
    private var config: WatermarkConfig?
    private var policy: ProcessingPolicy = ProcessingPolicy()
    private var albumName: String?
    private var rawConsent = false
    private var originalTasks: [LibraryAsset] = []

    var totalCount: Int { items.count }

    /// 总进度：各任务 fraction 的平均（完成态恒为 1）。
    var overallFraction: Double {
        guard !items.isEmpty else { return 0 }
        let sum = items.reduce(0.0) { $0 + ($1.status == .pending ? $1.fraction : max($1.fraction, 1)) }
        return min(max(sum / Double(items.count), 0), 1)
    }

    var finishedCount: Int { succeededCount + failedCount + cancelledCount }

    var failedItems: [BatchItemState] { items.filter { $0.status == .failed } }

    /// 进度文案：「已完成 23 / 100」。
    var progressText: String { "已完成 \(finishedCount) / \(totalCount)" }

    // MARK: - 启动

    func start(tasks: [LibraryAsset],
               config: WatermarkConfig,
               rawConsent: Bool,
               policy: ProcessingPolicy,
               albumName: String?,
               library: PhotoLibraryService,
               compositor: WatermarkCompositor) {
        guard !isRunning, !tasks.isEmpty else { return }

        self.library = library
        self.compositor = compositor
        self.config = config
        self.rawConsent = rawConsent
        self.policy = policy
        self.albumName = albumName
        self.originalTasks = tasks

        items = tasks.map { asset in
            BatchItemState(
                id: asset.id,
                assetID: asset.assetIdentifier,
                filename: asset.originalFilename ?? "未命名",
                kind: asset.kind
            )
        }
        succeededCount = 0
        failedCount = 0
        cancelledCount = 0
        rawConversionNotes = []
        exportErrorMessage = nil
        completedRecord = nil
        memoryPeakMB = 0
        activeTaskCount = 0
        totalDuration = 0
        lastFailures = []
        lastTaskRecords = []
        lastLogFileURL = nil
        startedAt = Date()
        finishedAt = nil
        isRunning = true
        isExporting = false

        // 档位一致（块B 约束）：BatchQueue 的 settings 必须与 processorProvider 使用同一份
        // ProcessingSettings（「优先速度」同时影响并发、码率系数、JPEG 质量）。
        let effectiveSettings = policy.settings.withRawConsent(rawConsent)
        let queue = BatchQueue(settings: effectiveSettings)
        self.queue = queue

        let provider: @Sendable (MediaKind) -> any AssetProcessor = { kind in
            ProcessorFactory.make(for: kind, policy: policy, rawConsent: rawConsent)
        }

        let stream = queue.run(
            tasks: tasks,
            config: config,
            rawConsent: rawConsent,
            processorProvider: provider,
            library: library,
            compositor: compositor
        )

        startMemoryMonitor()

        runTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for await progress in stream {
                self.apply(progress)
            }
            await self.finalizeRun()
        }
    }

    /// 重跑指定失败项（默认全部失败项；UI 勾选后传子集）。
    func retry(assetIdentifiers: Set<String>) {
        guard !isRunning, let library, let compositor, let config else { return }
        let tasks = originalTasks.filter { assetIdentifiers.contains($0.assetIdentifier) }
        guard !tasks.isEmpty else { return }
        start(tasks: tasks, config: config, rawConsent: rawConsent, policy: policy,
              albumName: albumName, library: library, compositor: compositor)
    }

    // MARK: - 取消

    /// 取消：只终止未完成任务，已完成产物照常写库（PRD 异常分支「中途取消」）。
    func cancel() {
        guard isRunning, !isExporting else { return }
        queue?.cancel()
        for index in items.indices where items[index].status == .pending || items[index].status == .running {
            items[index].status = .cancelled
            items[index].fraction = 0
            items[index].stageText = "已取消（未处理）"
        }
        recalculateCounts()
    }

    // MARK: - 进度应用

    private func apply(_ progress: BatchProgress) {
        guard let index = items.firstIndex(where: { $0.assetID == progress.assetID }) else { return }
        var item = items[index]

        switch progress.status {
        case .running:
            if item.startedAt == nil { item.startedAt = Date() }
            item.status = .running
            item.fraction = min(max(progress.fractionCompleted, item.fraction), 1)
        case .succeeded, .failed, .cancelled:
            item.status = progress.status
            item.fraction = progress.status == .succeeded ? 1 : item.fraction
            if let started = item.startedAt {
                item.duration = Date().timeIntervalSince(started)
            }
            if let error = progress.error {
                item.errorText = error.userReadableDescription
                item.stageText = BatchController.stageText(for: error)
            } else if progress.status == .cancelled {
                item.stageText = "已取消"
            }
        case .pending:
            break
        }

        items[index] = item
        succeededCount = progress.succeededCount
        failedCount = progress.failedCount
        let finished = items.filter { $0.status == .succeeded || $0.status == .failed || $0.status == .cancelled }.count
        cancelledCount = max(finished - progress.succeededCount - progress.failedCount, 0)
        activeTaskCount = items.filter { $0.status == .running }.count
    }

    private func recalculateCounts() {
        succeededCount = items.filter { $0.status == .succeeded }.count
        failedCount = items.filter { $0.status == .failed }.count
        cancelledCount = items.filter { $0.status == .cancelled }.count
        activeTaskCount = items.filter { $0.status == .running }.count
    }

    // MARK: - 收尾：写库 + 落历史 + 通知

    private func finalizeRun() async {
        isExporting = true
        let outputs = queue?.outputs ?? []

        var summary: ExportSummary?
        if !outputs.isEmpty {
            do {
                summary = try await ExportService().saveToLibrary(
                    outputs,
                    albumName: albumName,
                    onRawConversion: { [weak self] note in
                        Task { @MainActor in
                            self?.rawConversionNotes.append(note)
                        }
                    }
                )
            } catch {
                // 写库整体失败：已渲染成功的项全部按「写入失败」计入失败（不谎报成功）。
                let reason = (error as? WatermarkError)?.userReadableDescription
                    ?? WatermarkError.writeFailed(error.localizedDescription).userReadableDescription
                exportErrorMessage = reason
                for index in items.indices where items[index].status == .succeeded {
                    items[index].status = .failed
                    items[index].errorText = reason
                    items[index].stageText = "写入相册"
                }
                recalculateCounts()
            }
        } else if failedCount == 0 && cancelledCount == 0 {
            exportErrorMessage = "队列未产出任何结果，请重试。"
        }

        // 队列结束后补齐未上报的任务状态（防御：stream 异常提前结束）
        for index in items.indices where items[index].status == .running {
            items[index].status = .failed
            items[index].errorText = "任务未完成（队列提前结束）"
            items[index].stageText = "处理中断"
        }
        recalculateCounts()

        finishedAt = Date()
        totalDuration = finishedAt?.timeIntervalSince(startedAt ?? Date()) ?? 0

        // 快照块B 队列的结构化结果（失败清单/日志），随后释放队列
        lastFailures = queue?.failures ?? []
        lastTaskRecords = queue?.records ?? []
        lastLogFileURL = queue?.logFileURL

        // 产物临时文件由块B 收口，块C 不再调用 cleanupTemporaryFiles：
        // ExportService.saveToLibrary 每分块结束已对成功项 defer 清理，
        // BatchQueue 入口有 ProcessingTempFile.sweepStaleFiles 回收陈旧文件；
        // 两处都清会让「失败项保留到用户放弃重试」的约定失效。

        memoryTask?.cancel()
        memoryTask = nil
        isRunning = false
        isExporting = false
        queue = nil
        runTask = nil

        // 逐素材导出记录 → 批次历史（只取块B 写入的 outputUTI/outputNote，不推导容器）。
        var exportRecordsByAsset: [String: ExportRecord] = [:]
        for record in summary?.records ?? [] {
            exportRecordsByAsset[record.assetIdentifier] = record
        }
        let record = makeRecord(exportRecords: exportRecordsByAsset)
        completedRecord = record
        onBatchFinished?(record)
        onNotify?(succeededCount, failedCount)
    }

    private func makeRecord(exportRecords: [String: ExportRecord]) -> BatchHistoryRecord {
        let historyItems = items.map { item in
            let exportRecord = exportRecords[item.assetID]
            return BatchHistoryItem(
                id: item.id,
                assetIdentifier: item.assetID,
                filename: item.filename,
                kind: item.kind,
                status: item.status,
                errorText: item.errorText,
                stageText: item.stageText,
                duration: item.duration,
                outputUTI: exportRecord?.outputUTI,
                outputNote: exportRecord?.outputNote
            )
        }
        return BatchHistoryRecord(
            id: UUID(),
            startedAt: startedAt ?? Date(),
            finishedAt: finishedAt ?? Date(),
            assetCount: items.count,
            succeededCount: succeededCount,
            failedCount: failedCount,
            cancelledCount: cancelledCount,
            items: historyItems
        )
    }

    // MARK: - 内存峰值采样（调试面板）

    private func startMemoryMonitor() {
        memoryTask?.cancel()
        memoryTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.isRunning else { return }
                self.memoryPeakMB = max(self.memoryPeakMB, MemoryProbe.footprintMB())
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    // MARK: - 失败清单

    /// 失败清单文本（复用块B FailureListExporter 的口径：文件名/类型/阶段/原因/完整日志指引）。
    var failureListText: String {
        FailureListExporter.text(
            failures: lastFailures,
            batchLabel: "批量水印（\(BatchController.dateText(startedAt ?? Date()))）",
            totalCount: items.count,
            succeededCount: succeededCount,
            startedAt: startedAt,
            logFileURL: lastLogFileURL
        )
    }

    /// 失败阶段映射：错误类型 → 用户可理解的阶段名（导出记录与失败清单共用）。
    static func stageText(for error: WatermarkError) -> String {
        switch error {
        case .accessDenied:
            return "权限"
        case .assetUnavailable:
            return "读取原图"
        case .iCloudDownloadFailed:
            return "iCloud 下载"
        case .unsupportedFormat:
            return "格式检测"
        case .rawConversionRequiresConsent:
            return "RAW 授权"
        case .renderFailed:
            return "水印渲染"
        case .encodeFailed:
            return "编码"
        case .writeFailed:
            return "写入相册"
        case .cancelled:
            return "已取消"
        }
    }

    static func dateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }
}

// MARK: - 处理器工厂

/// 素材类型 → 块B 处理器（UI 侧唯一构造点；委托块B AssetProcessorFactory，保证与
/// BGTask 后台续跑路径使用同一份构造逻辑与 ProcessingSettings）。
enum ProcessorFactory {
    static func make(for kind: MediaKind,
                     policy: ProcessingPolicy,
                     rawConsent: Bool = false) -> any AssetProcessor {
        AssetProcessorFactory.processor(
            for: kind,
            settings: policy.settings.withRawConsent(rawConsent)
        )
    }
}
