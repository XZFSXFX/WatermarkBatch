//
//  BatchMemoryMonitor.swift
//  WatermarkBatch（水印工坊 BatchMark）
//
//  块B · 内存采样（v1.1：批处理内存峰值目标 <200MB，超限降并发、不降画质）
//
//  采样口径：
//  ① `os_proc_available_memory()`：本进程当前可用内存（iOS 13+，系统按 jetsam 限额给出），
//     用于「是否该降并发」的决策；
//  ② `task_vm_info.phys_footprint`：本进程物理占用（等同 Xcode Memory Gauge），
//     用于日志与验收记录峰值。
//
//  注意：两者都不是精确的下一帧峰值预测，只能做「趋势 + 阈值」保护；
//  真正的峰值控制靠逐帧 autoreleasepool 与并发上限（ProcessingSettings）。
//

import Darwin
import Foundation

enum BatchMemoryMonitor {

    // MARK: - 可用内存

    /// 本进程当前可用内存字节数；系统不提供时返回 nil（模拟器/极端环境）。
    static func availableBytes() -> UInt64? {
        let value = os_proc_available_memory()
        // 0 表示不可用（老系统/受限环境），不能当成「没内存了」。
        guard value > 0 else { return nil }
        return UInt64(value)
    }

    // MARK: - 已用内存

    /// 本进程物理占用（phys_footprint）字节数；查询失败返回 nil。
    static func footprintBytes() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return UInt64(info.phys_footprint)
    }

    // MARK: - 压力判定

    /// 是否已进入内存压力区（可用内存低于阈值）。
    /// - Parameter threshold: 默认取 `ProcessingSettings.memoryPressureThresholdBytes`（150MB）。
    /// - Note: 采样不到时保守返回 false——不能因为「测不到」就永久把并发压到 1，
    ///   否则画质优先档会退化成单并发，违背性能预期。
    static func isUnderPressure(threshold: UInt64 = ProcessingSettings.memoryPressureThresholdBytes) -> Bool {
        guard let available = availableBytes() else { return false }
        return available < threshold
    }

    // MARK: - 峰值追踪（日志用）

    /// 轻量峰值采样器：任务进行中每隔一段时间 `sample()`，批次结束读 `peakFootprintBytes`。
    final class PeakTracker: @unchecked Sendable {
        private let lock = NSLock()
        private var peak: UInt64 = 0
        private var lowestAvailable: UInt64 = .max

        init() {}

        func sample() {
            let footprint = BatchMemoryMonitor.footprintBytes()
            let available = BatchMemoryMonitor.availableBytes()
            lock.lock(); defer { lock.unlock() }
            if let footprint { peak = max(peak, footprint) }
            if let available { lowestAvailable = min(lowestAvailable, available) }
        }

        var peakFootprintBytes: UInt64 {
            lock.lock(); defer { lock.unlock() }
            return peak
        }

        var lowestAvailableBytes: UInt64 {
            lock.lock(); defer { lock.unlock() }
            return lowestAvailable == .max ? 0 : lowestAvailable
        }

        /// 日志行：峰值物理占用 / 最低可用内存（MB）。
        func summaryLine() -> String {
            let peakMB = Double(peakFootprintBytes) / 1024 / 1024
            let lowMB = Double(lowestAvailableBytes) / 1024 / 1024
            return String(format: "内存峰值 %.1fMB，最低可用 %.1fMB", peakMB, lowMB)
        }
    }
}
