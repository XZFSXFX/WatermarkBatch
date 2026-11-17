//
//  ConcurrencyLimiter.swift
//  WatermarkBatch（水印工坊 BatchMark）
//
//  块B · 唯一并发限流闸门
//
//  为什么单独成文件：并发上限是「画质优先档 2 照片/1 视频、速度档 3-4」这条裁决的唯一执行点。
//  BatchQueue 只允许通过本 actor 取许可，禁止在别处再写 DispatchSemaphore / 自建计数器，
//  否则「同一时刻最多一个视频在编码」这条硬约束会出现第二个真相来源。
//
//  设计要点：
//  ① 分通道发许可（photo / video 各自计数），视频通道恒定 1（默认档）——两条通道互不抢占；
//  ② FIFO 排队，不让后来的大任务插队饿死前面的；
//  ③ 支持取消：等待者被 cancel 时立刻以 CancellationError 唤醒，不占许可、不泄漏 continuation；
//  ④ 许可释放优先给同通道等待者，没有等待者才归还额度，避免「归还-再取」的窗口被别的任务抢走。
//

import Foundation

actor ConcurrencyLimiter {

    enum Lane: Hashable, Sendable {
        case photo
        case video
    }

    private struct Waiter {
        let id: UInt64
        let lane: Lane
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var available: [Lane: Int]
    /// 各通道的许可上限。release 用它做钳制——没有这份上限，任何一处重复 defer
    /// 都会把配额悄悄加回去，表现为「并发慢慢超过 2/1」，且从外部完全看不出来。
    private let permits: [Lane: Int]
    private var waiters: [Waiter] = []
    private var cancelledIDs: Set<UInt64> = []
    private var nextID: UInt64 = 0

    /// - Parameters:
    ///   - photoPermits: 画质优先档 2；「优先速度」档 3-4（由 ProcessingSettings 决定）
    ///   - videoPermits: 恒为 1（任何档位都不允许两个视频同时编码）
    init(photoPermits: Int, videoPermits: Int) {
        precondition(photoPermits >= 1, "照片并发至少 1")
        precondition(videoPermits >= 1, "视频并发至少 1")
        let limits: [Lane: Int] = [.photo: photoPermits, .video: videoPermits]
        self.permits = limits
        self.available = limits
    }

    // MARK: - 取 / 还许可

    func acquire(_ lane: Lane) async throws {
        precondition(permits[lane] != nil, "未配置的通道：\(lane)")
        if Task.isCancelled { throw CancellationError() }

        if let free = available[lane], free > 0 {
            available[lane] = free - 1
            return
        }

        let id = nextID
        nextID &+= 1

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                // 取消可能发生在 onCancel 先于本闭包执行的竞态窗口里，这里补一次判定。
                if cancelledIDs.remove(id) != nil {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                waiters.append(Waiter(id: id, lane: lane, continuation: continuation))
            }
        } onCancel: {
            Task { await self.markCancelled(id) }
        }
    }

    /// 归还许可。两条路径：同通道有等待者就直传（不经过 available，避免「归还-再取」窗口被插队），
    /// 否则写回额度——**写回必须钳到 permits 上限**，超额说明有重复 release，只记日志、不放大配额。
    func release(_ lane: Lane) {
        if let index = waiters.firstIndex(where: { $0.lane == lane }) {
            let waiter = waiters.remove(at: index)
            waiter.continuation.resume()
            return
        }

        let cap = permits[lane] ?? 0
        let current = available[lane] ?? 0
        if current + 1 > cap {
            // 不 assertFailure：超额归还是调度层的 bug，不该把用户的批量任务当场崩掉。
            // 这条日志是排查「并发数莫名变大」的唯一线索，别删。
            #if DEBUG
            print("[ConcurrencyLimiter] 超额归还 lane=\(lane) available=\(current) cap=\(cap)"
                  + " —— 检查是否有一处 defer 重复触发，或 release 未与 acquire 配对")
            #endif
            available[lane] = cap
            return
        }
        available[lane] = current + 1
    }

    /// 取许可 → 执行 → 保证归还（throw 也归还）。BatchQueue 的每个任务都用它包住。
    func withPermit<T: Sendable>(_ lane: Lane,
                                 _ body: @Sendable () async throws -> T) async throws -> T {
        try await acquire(lane)
        do {
            let value = try await body()
            release(lane)
            return value
        } catch {
            release(lane)
            throw error
        }
    }

    // MARK: - 取消

    private func markCancelled(_ id: UInt64) {
        if let index = waiters.firstIndex(where: { $0.id == id }) {
            let waiter = waiters.remove(at: index)
            waiter.continuation.resume(throwing: CancellationError())
        } else {
            // 还没入队：记下来，等入队闭包执行时自我了断。
            cancelledIDs.insert(id)
            if cancelledIDs.count > 256 { cancelledIDs.removeAll() }
        }
    }

    // MARK: - 调试面板数据源

    var debugSnapshot: [String: Int] {
        [
            "photoFree": available[.photo] ?? 0,
            "videoFree": available[.video] ?? 0,
            "waiting": waiters.count
        ]
    }
}
