//
//  ProcessingTrace.swift
//  WatermarkBatch（水印工坊 BatchMark）
//
//  块B · 任务阶段打点（读取 / 渲染 / 编码 / 写入）与耗时统计
//
//  背景：契约 §4 的 `AssetProcessor.process(...)` 签名不允许增加参数（一字不改），
//  但失败清单必须带「阶段」、日志必须带分段耗时。故用 TaskLocal 绑定的记录器：
//  BatchQueue 在派发每个任务时 `ProcessingTrace.$recorder.withValue(recorder) { ... }`，
//  处理器内部只调 `ProcessingTrace.mark(.rendering)`，无参数改动、无全局可变状态。
//
//  重要：TaskLocal 只在「同一任务上下文（含其子任务）」可见；处理器内部若自行
//  `Task.detached`，打点会失效（不会报错，只会缺少阶段信息）——故块B 内部禁止 detached。
//

import Foundation

// MARK: - 阶段

/// 单任务的四个处理阶段（失败清单与日志的归类口径）。
enum ProcessStage: String, Sendable, CaseIterable {
    /// 读取：iCloud 下载 / 原图解码 / 轨道加载 / 元数据探测。
    case reading
    /// 渲染：Core Image 合成（水印层 + 底图）。
    case rendering
    /// 编码：CGImageDestination / AVAssetWriter（含调色板量化与压缩）。
    case encoding
    /// 写入：产物落盘 / 重配对注入 / 相册写回前的收尾。
    case writing

    /// 中文标签（失败清单导出纯文本用）。
    var label: String {
        switch self {
        case .reading:   return "读取"
        case .rendering: return "渲染"
        case .encoding:  return "编码"
        case .writing:   return "写入"
        }
    }
}

// MARK: - 阶段快照

/// 阶段耗时快照（值类型，可安全跨并发域传递与序列化）。
struct StageSnapshot: Sendable, Equatable {
    /// 各阶段累计耗时（秒）。同一阶段被多次进入时累加。
    let durations: [ProcessStage: TimeInterval]
    /// 失败/结束时所处阶段。
    let lastStage: ProcessStage?
    /// 从任务开始到快照时刻的总耗时（秒）。
    let totalDuration: TimeInterval

    static let empty = StageSnapshot(durations: [:], lastStage: nil, totalDuration: 0)

    /// 单阶段耗时（秒），缺省 0。
    func duration(of stage: ProcessStage) -> TimeInterval {
        durations[stage] ?? 0
    }

    /// 纯文本一行：`读取 0.42s / 渲染 1.08s / 编码 0.66s / 写入 0.05s`。
    var compactDescription: String {
        ProcessStage.allCases
            .map { "\($0.label) \(String(format: "%.2f", duration(of: $0)))s" }
            .joined(separator: " / ")
    }
}

// MARK: - 记录器

/// 阶段计时器：线程安全（处理器可能在多个队列/子任务内打点）。
final class StageRecorder: @unchecked Sendable {

    private let lock = NSLock()
    private let startedAt = Date()
    private var stageStartedAt: Date?
    private var currentStage: ProcessStage?
    private var durations: [ProcessStage: TimeInterval] = [:]

    init() {}

    /// 进入某阶段：结束上一阶段并累计其耗时。
    /// 允许重复进入同一阶段（幂等，不重复计时）；允许回退（如重试时 writing → encoding）。
    func mark(_ stage: ProcessStage) {
        lock.lock(); defer { lock.unlock() }
        if currentStage == stage { return }
        closeCurrentStageLocked()
        currentStage = stage
        stageStartedAt = Date()
    }

    /// 结束计时（任务收尾时调用，避免最后一段耗时丢失）。
    func finish() {
        lock.lock(); defer { lock.unlock() }
        closeCurrentStageLocked()
        currentStage = nil
        stageStartedAt = nil
    }

    /// 当前阶段（失败归因用；未打点时为 nil）。
    var activeStage: ProcessStage? {
        lock.lock(); defer { lock.unlock() }
        return currentStage
    }

    /// 快照（会先结算当前阶段已消耗的时间，不结束计时）。
    func snapshot() -> StageSnapshot {
        lock.lock(); defer { lock.unlock() }
        var merged = durations
        if let stage = currentStage, let start = stageStartedAt {
            merged[stage, default: 0] += Date().timeIntervalSince(start)
        }
        return StageSnapshot(
            durations: merged,
            lastStage: currentStage,
            totalDuration: Date().timeIntervalSince(startedAt)
        )
    }

    // MARK: 私有

    private func closeCurrentStageLocked() {
        guard let stage = currentStage, let start = stageStartedAt else { return }
        durations[stage, default: 0] += Date().timeIntervalSince(start)
        stageStartedAt = Date()
    }
}

// MARK: - TaskLocal 入口

/// 处理器内打点入口（无参数、无全局状态）。
enum ProcessingTrace {

    /// 当前任务绑定的记录器；BatchQueue 之外的调用（如单张预览导出）为 nil，打点自动空转。
    @TaskLocal static var recorder: StageRecorder?

    /// 标记进入阶段。记录器缺失时静默跳过（预览链路不需要阶段统计）。
    static func mark(_ stage: ProcessStage) {
        recorder?.mark(stage)
    }

    /// 结束当前任务计时。
    static func finish() {
        recorder?.finish()
    }

    /// 当前阶段（异常映射时取用）。
    static var activeStage: ProcessStage? {
        recorder?.activeStage
    }
}
