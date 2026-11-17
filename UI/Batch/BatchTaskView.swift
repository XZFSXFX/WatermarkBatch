//
//  BatchTaskView.swift
//  WatermarkBatch（水印工坊 BatchMark）
//
//  块C · Tab3 批量任务（PRD P-03 / F-16 / F-27，交付物 C）
//  - 导出前二次确认：N 个素材、类型分布、预估耗时（BatchEstimator）、RAW 告知、原片只读声明；
//  - 逐任务进度条 + 成功/失败/取消计数 + 总进度 + 取消（已完成保留）；
//  - 失败清单（文件名/原因/阶段）导出为文本，勾选失败项单独重跑；
//  - 处理中不阻塞 UI：所有进度来自 BatchQueue 的 AsyncStream，可随时切页。
//

import SwiftUI

struct BatchTaskView: View {

    @Environment(AppModel.self) private var model

    @State private var showConfirm = false
    @State private var showCancelConfirm = false
    @State private var showFailureExporter = false
    @State private var failureDocument: TextFileDocument?
    @State private var selectedFailures: Set<String> = []

    private var batch: BatchController { model.batch }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if batch.items.isEmpty {
                    emptyContent
                } else {
                    statusCard
                    if batch.isRunning || batch.isExporting {
                        progressList
                    } else {
                        resultSection
                    }
                }
                if model.settings.debugPanelUnlocked {
                    DebugMetricsView(batch: batch)
                }
            }
            .padding(16)
        }
        .navigationTitle("批量任务")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    model.showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
            }
        }
        .sheet(isPresented: $showConfirm) {
            BatchConfirmSheet(
                assets: model.tasksExcludingWatermarked().tasks,
                skippedCount: model.tasksExcludingWatermarked().skipped,
                estimate: BatchEstimator.estimate(
                    assets: model.tasksExcludingWatermarked().tasks,
                    policy: model.policy
                ),
                policy: model.policy
            ) { excludingRaw in
                showConfirm = false
                model.startBatch(rawConsent: true, excludingRaw: excludingRaw)
            } onCancel: {
                showConfirm = false
            }
        }
        .alert("取消批量任务？", isPresented: $showCancelConfirm) {
            Button("继续处理", role: .cancel) {}
            Button("取消任务", role: .destructive) { batch.cancel() }
        } message: {
            Text("已完成的 \(batch.succeededCount) 项会保留在相册与记录中，未处理的不再继续。原片始终不会被修改。")
        }
        .fileExporter(
            isPresented: $showFailureExporter,
            document: failureDocument,
            contentType: .plainText,
            defaultFilename: "失败清单.txt"
        ) { _ in
            failureDocument = nil
        }
    }

    // MARK: - 空态（未开始）

    private var emptyContent: some View {
        let prepared = model.tasksExcludingWatermarked()
        let estimate = BatchEstimator.estimate(assets: prepared.tasks, policy: model.policy)

        return VStack(alignment: .leading, spacing: 14) {
            if model.selectionCount == 0 {
                EmptyStateView(
                    systemImage: "square.stack.3d.down.right",
                    title: "还没有待处理的素材",
                    message: "在「相册」页勾选素材，再回到「水印」页配置水印，最后来这里批量导出。",
                    actionTitle: "去相册选择",
                    action: { model.selectedTab = .library }
                )
                .frame(minHeight: 320)
            } else {
                SectionCard(title: "准备就绪") {
                    Text("已选 \(model.selectionCount) 项")
                        .font(.title3.weight(.semibold))
                    Text(estimate.distributionText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if prepared.skipped > 0 {
                        Label("将跳过 \(prepared.skipped) 个已加水印素材", systemImage: "forward.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 6) {
                        Image(systemName: "clock")
                        Text("预估 \(estimate.durationText)（±20%，按数量与类型估算）")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    Label("处理策略：\(model.policy.modeTitle)（码率 \(ProcessingPolicy.format(model.policy.videoBitrateCoefficient))× · JPEG \(ProcessingPolicy.format(model.policy.jpegCompressionQuality)) · 并发 \(model.policy.photoConcurrency)/\(model.policy.videoConcurrency)）",
                          systemImage: "slider.horizontal.3")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Button {
                        showConfirm = true
                    } label: {
                        Label("批量套用并导出", systemImage: "square.stack.3d.down.right")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(prepared.tasks.isEmpty)
                }

                Text("导出会在相册新增副本，原片不修改、不删除；中途取消已完成项保留。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }
        }
    }

    // MARK: - 状态卡

    private var statusCard: some View {
        SectionCard(title: nil) {
            HStack(alignment: .firstTextBaseline) {
                Text(statusTitle)
                    .font(.headline)
                Spacer()
                Text("\(Int(batch.overallFraction * 100))%")
                    .font(.title3.monospacedDigit().weight(.semibold))
            }

            ProgressView(value: batch.overallFraction)
                .tint(.accentColor)

            HStack(spacing: 14) {
                countBadge(title: "成功", value: batch.succeededCount, color: .green)
                countBadge(title: "失败", value: batch.failedCount, color: .red)
                if batch.cancelledCount > 0 {
                    countBadge(title: "取消", value: batch.cancelledCount, color: .secondary)
                }
                Spacer()
                Text(batch.progressText)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if batch.isRunning || batch.isExporting {
                HStack {
                    if batch.isExporting {
                        Label("正在写入相册…", systemImage: "square.and.arrow.down")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Button(role: .destructive) {
                            showCancelConfirm = true
                        } label: {
                            Label("取消任务", systemImage: "stop.circle")
                                .font(.caption.weight(.medium))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    Spacer()
                    if let started = batch.startedAt {
                        Text("已用时 \(Format.durationText(Date().timeIntervalSince(started)))")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var statusTitle: String {
        if batch.isExporting { return "正在写入相册" }
        if batch.isRunning { return "正在处理" }
        if batch.failedCount == 0 && batch.cancelledCount == 0 { return "全部完成" }
        return "处理结束"
    }

    private func countBadge(title: String, value: Int, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text("\(title) \(value)")
                .font(.caption.monospacedDigit())
        }
    }

    // MARK: - 进行中列表

    private var progressList: some View {
        SectionCard(title: "任务明细（\(batch.items.count)）") {
            LazyVStack(spacing: 10) {
                ForEach(batch.items) { item in
                    BatchItemRow(item: item)
                }
            }
        }
    }

    // MARK: - 结果

    private var resultSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionCard(title: "批次结果") {
                HStack {
                    Text(batch.completedRecord?.countSummary ?? "—")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("耗时 \(Format.durationText(batch.totalDuration))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if let error = batch.exportErrorMessage {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if !batch.rawConversionNotes.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("RAW 转换说明")
                            .font(.caption.weight(.semibold))
                        ForEach(batch.rawConversionNotes, id: \.self) { note in
                            Text("· \(note)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                HStack(spacing: 10) {
                    Button {
                        model.selectedTab = .records
                    } label: {
                        Label("查看导出记录", systemImage: "clock.arrow.circlepath")
                            .font(.caption.weight(.medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button {
                        model.openPhotosApp()
                    } label: {
                        Label("打开相册", systemImage: "photo.on.rectangle")
                            .font(.caption.weight(.medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    Spacer()
                }
            }

            if batch.failedCount > 0 {
                failureSection
            }

            if !batch.isRunning {
                Button {
                    showConfirm = true
                } label: {
                    Label("重新开始一批（当前选中素材）", systemImage: "arrow.clockwise")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private var failureSection: some View {
        SectionCard(title: "失败清单（\(batch.failedCount)）") {
            Text("勾选后可单独重跑；导出文本含文件名、阶段与原因，便于排查。")
                .font(.caption2)
                .foregroundStyle(.secondary)

            LazyVStack(spacing: 8) {
                ForEach(batch.failedItems) { item in
                    Button {
                        toggleFailureSelection(item.assetID)
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: selectedFailures.contains(item.assetID)
                                  ? "checkmark.square.fill" : "square")
                                .font(.system(size: 16))
                                .foregroundStyle(selectedFailures.contains(item.assetID) ? Color.accentColor : .secondary)

                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(item.filename)
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    Text(kindLabel(item.kind))
                                        .font(.system(size: 9, weight: .semibold))
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 1)
                                        .background(Color(.tertiarySystemFill), in: Capsule())
                                        .foregroundStyle(.secondary)
                                }
                                if let stage = item.stageText {
                                    Text("阶段：\(stage)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Text(item.errorText ?? "未知原因")
                                    .font(.caption2)
                                    .foregroundStyle(.red.opacity(0.85))
                                    .lineLimit(2)
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack(spacing: 10) {
                Button(selectedFailures.count == batch.failedCount ? "取消全选" : "全选失败项") {
                    if selectedFailures.count == batch.failedCount {
                        selectedFailures.removeAll()
                    } else {
                        selectedFailures = Set(batch.failedItems.map(\.assetID))
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    let ids = selectedFailures.isEmpty
                        ? Set(batch.failedItems.map(\.assetID))
                        : selectedFailures
                    batch.retry(assetIdentifiers: ids)
                    selectedFailures.removeAll()
                    model.selectedTab = .batch
                } label: {
                    Label(selectedFailures.isEmpty ? "重跑全部失败项" : "重跑所选（\(selectedFailures.count)）",
                          systemImage: "arrow.clockwise.circle")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button {
                    failureDocument = TextFileDocument(text: batch.failureListText)
                    showFailureExporter = true
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel("导出失败清单")
            }
        }
    }

    private func toggleFailureSelection(_ assetID: String) {
        if selectedFailures.contains(assetID) {
            selectedFailures.remove(assetID)
        } else {
            selectedFailures.insert(assetID)
        }
    }

    private func kindLabel(_ kind: MediaKind) -> String {
        switch kind {
        case .photo: return "照片"
        case .livePhoto: return "LIVE"
        case .animated: return "GIF"
        case .video: return "视频"
        case .raw: return "RAW"
        }
    }
}

// MARK: - 单任务行

struct BatchItemRow: View {

    let item: BatchItemState

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                statusIcon
                Text(item.filename)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Spacer()
                if let duration = item.duration {
                    Text(Format.milliseconds(duration))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text(statusText)
                    .font(.caption2)
                    .foregroundStyle(statusColor)
            }

            ProgressView(value: displayFraction)
                .tint(statusColor)
                .scaleEffect(x: 1, y: 0.7, anchor: .center)

            if let stage = item.stageText, item.status == .failed {
                Text("\(stage) · \(item.errorText ?? "")")
                    .font(.caption2)
                    .foregroundStyle(.red.opacity(0.85))
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }

    private var displayFraction: Double {
        switch item.status {
        case .succeeded: return 1
        case .failed, .cancelled, .pending: return item.fraction
        case .running: return max(item.fraction, 0.02)
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch item.status {
        case .pending:
            Image(systemName: "clock").foregroundStyle(.secondary)
        case .running:
            ProgressView().controlSize(.mini)
        case .succeeded:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        case .cancelled:
            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
        }
    }

    private var statusText: String {
        switch item.status {
        case .pending: return "排队中"
        case .running: return "\(Int(item.fraction * 100))%"
        case .succeeded: return "成功"
        case .failed: return "失败"
        case .cancelled: return "已取消"
        }
    }

    private var statusColor: Color {
        switch item.status {
        case .succeeded: return .green
        case .failed: return .red
        case .cancelled: return .secondary
        case .pending, .running: return .accentColor
        }
    }
}

// MARK: - 二次确认（含预估耗时 / RAW 告知 / 原片只读）

struct BatchConfirmSheet: View {

    let assets: [LibraryAsset]
    let skippedCount: Int
    let estimate: BatchEstimate
    let policy: ProcessingPolicy
    let onConfirm: (_ excludingRaw: Bool) -> Void
    let onCancel: () -> Void

    private var rawCount: Int { assets.filter { $0.kind == .raw }.count }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("即将处理 \(assets.count) 个素材")
                            .font(.title3.weight(.semibold))
                        Text(estimate.distributionText)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    SectionCard(title: "预估耗时") {
                        Text(estimate.durationText)
                            .font(.title2.weight(.semibold).monospacedDigit())
                        Text("按素材数量与类型估算（照片像素、视频时长与分辨率加权），误差目标 ±20%。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text("处理策略：\(policy.modeTitle) · 码率 \(ProcessingPolicy.format(policy.videoBitrateCoefficient))× · JPEG \(ProcessingPolicy.format(policy.jpegCompressionQuality)) · 并发 \(policy.photoConcurrency) 照片 / \(policy.videoConcurrency) 视频")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    if skippedCount > 0 {
                        Label("按「跳过已加水印」设置，将跳过 \(skippedCount) 个素材", systemImage: "forward.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if rawCount > 0 {
                        SectionCard(title: "RAW / DNG 告知（\(rawCount) 个）") {
                            Text("iOS 无法以原 RAW 格式写回加过水印的版本。这些素材将以 HEIC（最高质量）保存为新副本，原 RAW 文件保持不变。")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }

                    SectionCard(title: "写入方式") {
                        Text("将在相册新增处理后的副本，原片不会被修改或删除；完成后归入「已加水印」相簿（可在设置中关闭）。")
                            .font(.caption)
                        Text("中途取消：已完成的素材保留，未处理的不再继续。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(16)
            }
            .navigationTitle("确认批量导出")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消", role: .cancel) { onCancel() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    Button {
                        onConfirm(false)
                    } label: {
                        Text("确认导出（\(assets.count) 项）")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)

                    if rawCount > 0 {
                        Button {
                            onConfirm(true)
                        } label: {
                            Text("从本批移除 RAW 文件后导出")
                                .font(.caption)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
                .padding(.top, 8)
                .background(.ultraThinMaterial)
            }
        }
        .presentationDetents([.medium, .large])
    }
}
