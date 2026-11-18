//
//  NotificationManager.swift
//  WatermarkBatch（水印工坊 BatchMark）
//
//  块C · 完成本地通知（PRD F-28 / 交付物 D）
//  批量结束（前台或后台）发一条本地通知；点按后由 App 切到「导出记录」并给出「在相册中查看」入口，
//  再跳系统相册。纯本地 UNUserNotificationCenter，无推送证书、无网络。
//

import Foundation
// UNNotificationSettings 等类型在 Swift 6 严格并发下未标注 Sendable，
// 按编译器建议用 @preconcurrency 把跨 actor 传递的错误降级为警告。
@preconcurrency import UserNotifications

@MainActor
final class NotificationManager: NSObject {

    static let shared = NotificationManager()

    /// 通知被点按时的回调（参数为 userInfo["action"]，当前仅 "batchFinished"）。
    var onTap: (@MainActor (String) -> Void)?

    private let center = UNUserNotificationCenter.current()
    private let batchCategoryID = "BATCH_FINISHED"
    private var hasRequestedAuthorization = false

    private override init() {
        super.init()
    }

    /// 注册代理与通知类别（App 启动时调用一次）。
    func register() {
        center.delegate = self
        let open = UNNotificationAction(identifier: "OPEN_RECORDS", title: "查看记录", options: [.foreground])
        let category = UNNotificationCategory(
            identifier: batchCategoryID,
            actions: [open],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([category])
    }

    /// 首次需要时申请授权（批量开始前调用；用户拒绝则静默跳过通知，不影响导出）。
    @discardableResult
    func requestAuthorizationIfNeeded() async -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied:
            return false
        case .notDetermined:
            guard !hasRequestedAuthorization else { return false }
            hasRequestedAuthorization = true
            return (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        @unknown default:
            return false
        }
    }

    /// 批量完成通知。`succeeded/failed` 为计数，文案与导出记录页口径一致。
    func notifyBatchFinished(succeeded: Int, failed: Int) {
        let content = UNMutableNotificationContent()
        content.title = failed == 0 ? "批量加水印完成" : "批量完成，有 \(failed) 项失败"
        content.body = "成功 \(succeeded) 项" + (failed == 0 ? "，已保存到相册。" : "，失败项可在「导出记录」查看原因并重跑。")
        content.sound = .default
        content.categoryIdentifier = batchCategoryID
        content.userInfo = ["action": "batchFinished"]

        let request = UNNotificationRequest(
            identifier: "batch-finished-\(UUID().uuidString)",
            content: content,
            trigger: nil   // nil = 立即投递
        )
        center.add(request)
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension NotificationManager: UNUserNotificationCenterDelegate {

    /// 前台也展示横幅（否则用户切页时看不到完成提示）。
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    /// 点按通知：切到「导出记录」页（由 RootTabView 消费 pendingShowRecords）。
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let action = response.notification.request.content.userInfo["action"] as? String ?? "batchFinished"
        await MainActor.run {
            NotificationManager.shared.onTap?(action)
        }
    }
}
