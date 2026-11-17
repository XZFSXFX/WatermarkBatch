//
//  ConcurrencyLimiterTests.swift
//  WatermarkBatchTests（水印工坊 BatchMark）
//
//  为什么单测这个 actor：并发上限是整个项目唯一一处「靠运行时状态而不是靠代码结构」保证的硬约束。
//  配额被悄悄放大时，App 不会崩、不会报错，只会变慢或在 4K 上被 jetsam 干掉——那是最难查的一类问题。
//  这三条断言把「上限」变成会红的测试：
//    ① 正常取还后额度回到上限；
//    ② 重复 release（模拟某处 defer 触发两次）不会把额度放大；
//    ③ 视频通道任何情况下都只有 1 个许可，且与照片通道互不抢占。
//

import XCTest
@testable import WatermarkBatch

final class ConcurrencyLimiterTests: XCTestCase {

    func testAcquireReleaseRestoresPermits() async throws {
        let limiter = ConcurrencyLimiter(photoPermits: 2, videoPermits: 1)

        var snapshot = await limiter.debugSnapshot
        XCTAssertEqual(snapshot["photoFree"], 2, "初始额度应等于上限")
        XCTAssertEqual(snapshot["videoFree"], 1, "视频通道初始额度应为 1")

        try await limiter.acquire(.photo)
        snapshot = await limiter.debugSnapshot
        XCTAssertEqual(snapshot["photoFree"], 1, "取走一个许可后应剩 1")

        await limiter.release(.photo)
        snapshot = await limiter.debugSnapshot
        XCTAssertEqual(snapshot["photoFree"], 2, "归还后额度应回到上限")
    }

    func testOverReleaseIsClampedAtCap() async throws {
        let limiter = ConcurrencyLimiter(photoPermits: 2, videoPermits: 1)

        try await limiter.acquire(.photo)
        await limiter.release(.photo)
        // 模拟某处 defer 重复触发：再归还一次。没有钳制时这里会把额度抬到 3。
        await limiter.release(.photo)
        await limiter.release(.photo)

        let snapshot = await limiter.debugSnapshot
        XCTAssertEqual(snapshot["photoFree"], 2,
                       "超额归还把额度放大了：release 缺少 permits 钳制（并发会慢慢超过 2）")
    }

    func testVideoLaneNeverExceedsOneAndDoesNotStealPhotoPermits() async throws {
        let limiter = ConcurrencyLimiter(photoPermits: 2, videoPermits: 1)

        try await limiter.acquire(.video)
        var snapshot = await limiter.debugSnapshot
        XCTAssertEqual(snapshot["videoFree"], 0, "视频许可只有一个，取走后应为 0")
        XCTAssertEqual(snapshot["photoFree"], 2, "占用视频通道不得影响照片通道额度")

        // 视频通道已满，再取必须排队而不是借照片的额度。
        let waiter = Task { try await limiter.acquire(.video) }
        try await Task.sleep(nanoseconds: 80_000_000)
        snapshot = await limiter.debugSnapshot
        XCTAssertEqual(snapshot["waiting"], 1, "视频通道满后第二个请求应在排队")
        XCTAssertEqual(snapshot["photoFree"], 2, "排队不得改变照片通道额度")

        await limiter.release(.video)          // 直传给等待者
        try await waiter.value
        snapshot = await limiter.debugSnapshot
        XCTAssertEqual(snapshot["videoFree"], 0, "许可应已转交给等待者，而不是回到池里")
    }

    /// 照片通道直传分支的直接断言。
    /// 此前直传只有视频通道（videoPermits 恒 1）覆盖；而默认画质档的真实形态是照片 permits=2。
    /// 若 release 在唤醒 waiter 后还继续走写回分支，available 会被双重发放到 1，这条断言当场变红。
    func testPhotoReleaseHandsPermitDirectlyToWaiter() async throws {
        let limiter = ConcurrencyLimiter(photoPermits: 2, videoPermits: 1)

        try await limiter.acquire(.photo)      // A
        try await limiter.acquire(.photo)      // B
        var snapshot = await limiter.debugSnapshot
        XCTAssertEqual(snapshot["photoFree"], 0, "两个许可都该被占用")

        let waiter = Task { try await limiter.acquire(.photo) }   // C
        try await Task.sleep(nanoseconds: 80_000_000)
        snapshot = await limiter.debugSnapshot
        XCTAssertEqual(snapshot["waiting"], 1, "C 应在排队")
        XCTAssertEqual(snapshot["photoFree"], 0, "排队不得改变额度")

        await limiter.release(.photo)          // A 归还：必须直传给 C，不得写回池里

        // 关键断言①：写回分支会让这里变成 1——那正是双重发放的入口。
        let afterRelease = await limiter.debugSnapshot
        XCTAssertEqual(afterRelease["photoFree"], 0,
                       "release 把许可写回了池里而不是直传给 C：B、C 在跑却 available=1，下一个 D 会被立刻放行")
        // 关键断言②：C 已出队，且唯一出路就是被 release 直接 resume。
        XCTAssertEqual(afterRelease["waiting"], 0, "C 应已出队并获许可")

        // 兜底超时：若直传分支坏了，C 会永远停在队列里，直接 await 会让测试挂死而不是变红。
        let guardTask = Task {
            try await Task.sleep(nanoseconds: 2_000_000_000)
            waiter.cancel()
        }
        defer { guardTask.cancel() }
        try await waiter.value

        let final = await limiter.debugSnapshot
        XCTAssertEqual(final["photoFree"], 0, "C 持有许可，余额仍应为 0（B+C 两个实跑）")
        XCTAssertEqual(final["waiting"], 0, "队列已空")
    }

    func testCancelledWaiterDoesNotLeakPermit() async throws {
        let limiter = ConcurrencyLimiter(photoPermits: 1, videoPermits: 1)

        try await limiter.acquire(.photo)      // 占满
        let waiter = Task { try await limiter.acquire(.photo) }
        try await Task.sleep(nanoseconds: 60_000_000)
        waiter.cancel()

        var threw = false
        do { try await waiter.value } catch { threw = true }
        XCTAssertTrue(threw, "被取消的等待者应以 CancellationError 结束")

        let snapshot = await limiter.debugSnapshot
        XCTAssertEqual(snapshot["waiting"], 0, "取消的等待者不能留在队列里")
        XCTAssertEqual(snapshot["photoFree"], 0, "取消不得凭空造出许可")

        await limiter.release(.photo)
        let after = await limiter.debugSnapshot
        XCTAssertEqual(after["photoFree"], 1, "取消 + 归还后额度应准确回到 1")
    }
}
