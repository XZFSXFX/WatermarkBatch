//
//  SettingsView.swift
//  WatermarkBatch（水印工坊 BatchMark）
//
//  块C · 设置页 + 自用增强（交付物 B）
//  - 处理策略「优先画质 / 优先速度」二选一（默认画质优先），切到速度档弹二次确认并逐项说明变化；
//  - 「跳过已加水印素材」开关（文件名 + 像素尺寸 + 修改时间判定）、输出 PNG 无损、归入相册、完成通知；
//  - 日志导出（纯本地文本）；长按标题 2 秒解锁隐藏调试面板
//    （单任务耗时 / 批量总耗时 / 内存峰值 / 视频编码参数 / 当前并发数，可截图）。
//

import SwiftUI
import UIKit

struct SettingsView: View {

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var showSpeedConfirm = false
    @State private var showLogExporter = false
    @State private var logDocument: TextFileDocument?
    @State private var justUnlocked = false

    var body: some View {
        NavigationStack {
            Form {
                policySection
                switchesSection
                maintenanceSection
                if model.settings.debugPanelUnlocked {
                    Section {
                        DebugMetricsView(batch: model.batch)
                    } header: {
                        Text("隐藏调试面板")
                    } footer: {
                        Text("数据来自本机运行统计，可直接截图。长按标题 2 秒可再次收起（关闭开关后重新长按可再次解锁）。")
                    }
                }
                aboutSection
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("设置")
                        .font(.headline)
                        .onLongPressGesture(minimumDuration: 2.0) {
                            unlockDebugPanel()
                        }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .alert("开启「优先速度」会牺牲部分画质", isPresented: $showSpeedConfirm) {
                Button("取消", role: .cancel) {}
                Button("仍然开启", role: .destructive) {
                    var next = model.policy
                    next.tier = .preferSpeed
                    model.updatePolicy(next)
                }
            } message: {
                Text(speedExplanation)
            }
            .fileExporter(
                isPresented: $showLogExporter,
                document: logDocument,
                contentType: .plainText,
                defaultFilename: "水印工坊日志.txt"
            ) { _ in
                logDocument = nil
            }
        }
    }

    // MARK: - 处理策略

    private var policySection: some View {
        Section {
            Picker("处理策略", selection: Binding(
                get: { model.policy.tier },
                set: { newTier in handleModeChange(newTier) }
            )) {
                ForEach(ProcessingTier.allCases, id: \.self) { tier in
                    Text(tier.title).tag(tier)
                }
            }
            .pickerStyle(.segmented)

            LabeledContent("视频码率系数", value: "× \(ProcessingPolicy.format(model.policy.videoBitrateCoefficient))")
            LabeledContent("JPEG / HEIC 质量", value: ProcessingPolicy.format(model.policy.jpegCompressionQuality))
            LabeledContent("照片并发上限", value: "\(model.policy.photoConcurrency)")
            LabeledContent("视频并发上限", value: "\(model.policy.videoConcurrency)")

            Text(model.policy.modeSubtitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
        } header: {
            Text("处理策略")
        } footer: {
            Text("默认「优先画质」：码率 1.3×、JPEG 1.0、并发 2 照片 / 1 视频，宁慢勿损。以上展示值与块B 编码器/队列实际取值读同一份 ProcessingSettings 常量。")
        }
    }

    private var speedExplanation: String {
        ProcessingPolicy(tier: .preferSpeed, outputLosslessPNG: model.policy.outputLosslessPNG)
            .speedDowngradeExplanation
    }

    private func handleModeChange(_ newTier: ProcessingTier) {
        if newTier == .preferSpeed && model.policy.tier == .qualityFirst {
            showSpeedConfirm = true
            return
        }
        var next = model.policy
        next.tier = newTier
        model.updatePolicy(next)
    }

    // MARK: - 开关

    private var switchesSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { model.settings.skipWatermarked },
                set: { value in model.updateSettings { $0.skipWatermarked = value } }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("跳过已加水印素材")
                    Text("判定：\(ProcessingPolicy.skipDetectionDimensions)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Toggle(isOn: Binding(
                get: { model.policy.outputLosslessPNG },
                set: { value in
                    var next = model.policy
                    next.outputLosslessPNG = value
                    model.updatePolicy(next)
                }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("输出 PNG 无损")
                    Text("仅 HEIC/HEIF 静态照片：容器由 HEIC 改为 PNG（无损、保 alpha、位深不降）。代价：12MP 约 25-35MB/张（HEIC 约 3-5MB，增大 6-10 倍）；部分 EXIF/GPS 字段可能无法承载（缺失项写入日志与导出记录）；内存压力下照片并发自动降到 1，批次更慢。RAW / GIF / WebP / Live Photo 静帧不受影响。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Toggle(isOn: Binding(
                get: { model.settings.autoAlbum },
                set: { value in model.updateSettings { $0.autoAlbum = value } }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("归入「\(AlbumWriter.defaultAlbumName)」相簿")
                    Text("导出后自动归类，便于在相册中查找")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Toggle(isOn: Binding(
                get: { model.settings.notifyOnFinish },
                set: { value in
                    model.updateSettings { $0.notifyOnFinish = value }
                    if value { Task { _ = await NotificationManager.requestAuthorizationIfNeeded() } }
                }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("完成时本地通知")
                    Text("点按通知跳到「导出记录」，可一键打开相册")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("批处理")
        } footer: {
            Text("「跳过已加水印」依据：同名文件 + 同像素尺寸 + 存在更晚创建时间的副本 → 视为已处理；无法判定时一律不跳过（宁重复不漏处理）。")
        }
    }

    // MARK: - 日志与调试

    private var maintenanceSection: some View {
        Section {
            Button {
                logDocument = TextFileDocument(text: model.logText())
                showLogExporter = true
            } label: {
                Label("导出日志（文本）", systemImage: "doc.text")
            }

            if !model.settings.debugPanelUnlocked {
                HStack {
                    Label("隐藏调试面板", systemImage: "ladybug")
                    Spacer()
                    Text("长按标题 2 秒").font(.caption2).foregroundStyle(.secondary)
                }
            } else if justUnlocked {
                Label("调试面板已解锁（见下方）", systemImage: "checkmark.seal")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else {
                Button(role: .destructive) {
                    model.updateSettings { $0.debugPanelUnlocked = false }
                } label: {
                    Label("收起调试面板", systemImage: "eye.slash")
                }
            }
        } header: {
            Text("日志与调试")
        } footer: {
            Text("日志包含设备型号、策略参数、最近 10 批记录与失败明细；不含账号、位置或网络信息。")
        }
    }

    private func unlockDebugPanel() {
        model.updateSettings { $0.debugPanelUnlocked = true }
        justUnlocked = true
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    // MARK: - 关于

    private var aboutSection: some View {
        Section {
            LabeledContent("版本", value: appVersion)
            LabeledContent("数据存储", value: "本机 Documents")
            Text("纯本地运行：无账号、无网络请求、无第三方 SDK；原片只读，导出仅新增副本。")
                .font(.caption2)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text("已知边界")
                    .font(.caption.weight(.semibold))
                Text("· RAW/DNG 无法内嵌水印，输出 HEIC 并显式告知")
                Text("· 视频为视觉无损（PSNR ≥42dB / SSIM ≥0.98），非数学无损")
                Text("· HEIC 二次编码存在轻微损失，可选「输出 PNG 无损」")
                Text("· GIF 调色板 ≤256 色，量化可能产生轻微色带")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        } header: {
            Text("关于")
        }
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}

// MARK: - 调试面板（设置页与批量页共用）

struct DebugMetricsView: View {

    let batch: BatchController
    @Environment(AppModel.self) private var model

    private var durations: [TimeInterval] {
        batch.items.compactMap(\.duration).filter { $0 > 0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            metricRow("单任务耗时", value: taskDurationText)
            metricRow("批量总耗时", value: batch.totalDuration > 0 ? Format.durationText(batch.totalDuration) : "—")
            metricRow("内存峰值", value: String(format: "%.0f MB", batch.memoryPeakMB))
            metricRow("当前并发数", value: concurrencyText)
            metricRow("任务计数", value: "\(batch.totalCount) 项 · 成功 \(batch.succeededCount) · 失败 \(batch.failedCount) · 取消 \(batch.cancelledCount)")
            metricRow("视频编码参数", value: encodingText, multiline: true)
            Text("数据为本机运行统计，可直接截图；导出性能以 Mac + Xcode 16 真机实测为准。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
        }
        .font(.caption)
    }

    private func metricRow(_ title: String, value: String, multiline: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 88, alignment: .leading)
            Text(value)
                .font(.caption.monospacedDigit())
                .lineLimit(multiline ? 4 : 1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var taskDurationText: String {
        guard !durations.isEmpty else { return "—" }
        let average = durations.reduce(0, +) / Double(durations.count)
        let longest = durations.max() ?? 0
        return "平均 \(Format.milliseconds(average)) · 最长 \(Format.milliseconds(longest))"
    }

    private var concurrencyText: String {
        let cap = "上限 \(model.policy.photoConcurrency) 照片 / \(model.policy.videoConcurrency) 视频"
        if batch.isRunning {
            return "运行中 \(batch.activeTaskCount) · \(cap)"
        }
        return cap
    }

    /// 视频编码参数：系数来自 ProcessingPolicy；编码器/profile 跟随源轨（块B VideoWriterConfig 实现）。
    private var encodingText: String {
        "码率 max(源 × \(ProcessingPolicy.format(model.policy.videoBitrateCoefficient)), 平台推荐) · " +
        "编码器跟随源（hvc1→HEVC Main10 / avc1→H.264）· profile/level ≥ 源 · 音频直通"
    }
}
