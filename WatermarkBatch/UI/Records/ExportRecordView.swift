//
//  ExportRecordView.swift
//  WatermarkBatch（水印工坊 BatchMark）
//
//  块C · Tab4 导出记录（PRD F-29 / F-24 / F-28）
//  历史批次：时间、数量、成功/失败、耗时；失败可展开逐条看原因；可跳系统相册。
//

import SwiftUI

struct ExportRecordView: View {

    @Environment(AppModel.self) private var model

    @State private var expandedRecords: Set<UUID> = []
    @State private var showCompletionPrompt = false

    var body: some View {
        Group {
            if model.history.isEmpty {
                EmptyStateView(
                    systemImage: "clock.arrow.circlepath",
                    title: "还没有导出记录",
                    message: "完成一次批量加水印后，这里会保留最近 90 天（最多 50 批）的批次与失败原因。",
                    actionTitle: "去相册选择",
                    action: { model.selectedTab = .library }
                )
            } else {
                List {
                    Section {
                        ForEach(model.history) { record in
                            recordRow(record)
                        }
                    } footer: {
                        Text("记录仅保存在本机（Documents/BatchHistory.json），不含账号或网络信息。")
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("导出记录")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    model.openPhotosApp()
                } label: {
                    Image(systemName: "photo.on.rectangle")
                }
                .accessibilityLabel("打开相册查看")
            }
        }
        .onChange(of: model.pendingShowRecords) { _, pending in
            guard pending else { return }
            model.pendingShowRecords = false
            showCompletionPrompt = true
        }
        .alert("批处理已完成", isPresented: $showCompletionPrompt) {
            Button("去相册查看") { model.openPhotosApp() }
            Button("留在此页", role: .cancel) {}
        } message: {
            if let latest = model.history.first {
                Text("\(latest.countSummary) · 共 \(latest.assetCount) 项")
            } else {
                Text("可在相册中查看新增的带水印副本。")
            }
        }
    }

    // MARK: 单条记录

    private func recordRow(_ record: BatchHistoryRecord) -> some View {
        let failures = record.items.filter { $0.status == .failed }
        let isExpanded = expandedRecords.contains(record.id)

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(BatchController.dateText(record.startedAt))
                    .font(.subheadline.weight(.medium))
                Spacer()
                // 实际输出容器（块B ExportService 填值，块C 只映射文案，不推导）
                ForEach(containerUTIs(of: record), id: \.self) { uti in
                    Text(Self.containerLabel(for: uti))
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color(.tertiarySystemFill), in: Capsule())
                }
                Text(record.countSummary)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(record.failedCount > 0 ? .orange : .secondary)
            }

            HStack(spacing: 12) {
                Label("\(record.assetCount) 项", systemImage: "photo.stack")
                Label(Format.durationText(record.duration), systemImage: "clock")
                Spacer()
                Button("在相册中查看") {
                    model.openPhotosApp()
                }
                .font(.caption2)
                .buttonStyle(.borderless)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

            // PNG 取舍必须让用户看得见：存在 outputNote 时原样展示（块B 写入，可能含未携带的元数据分组）。
            if let note = record.items.compactMap(\.outputNote).first {
                Label(note, systemImage: "info.circle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if !failures.isEmpty {
                Button {
                    toggleExpanded(record.id)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                        Text("失败 \(failures.count) 项（点开查看原因）")
                            .font(.caption2)
                    }
                    .foregroundStyle(.red.opacity(0.85))
                }
                .buttonStyle(.plain)

                if isExpanded {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(failures) { item in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.filename)
                                    .font(.caption2.weight(.medium))
                                Text("阶段：\(item.stageText ?? "-") · \(item.errorText ?? "-")")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button {
                model.openPhotosApp()
            } label: {
                Label("相册", systemImage: "photo")
            }
            .tint(.blue)
        }
    }

    /// 记录里出现过的容器 UTI（去重、保持出现顺序）：值全部来自块B 写入的 `outputUTI`。
    /// 同一批次可能混有多种容器（例如只对 HEIC 源开了 PNG 无损，JPEG 源仍是 JPEG），
    /// 因此逐个并列显示，不做「多数派」之类的推导。
    private func containerUTIs(of record: BatchHistoryRecord) -> [String] {
        var seen: [String] = []
        for item in record.items {
            guard let uti = item.outputUTI, !seen.contains(uti) else { continue }
            seen.append(uti)
        }
        return seen
    }

    /// UTI → 用户可读容器名；未知 UTI 原样展示末段（如 `public.tiff` → `tiff`）。
    static func containerLabel(for uti: String) -> String {
        switch uti {
        case "public.png":
            return "PNG（无损）"
        case "public.heic", "public.heif":
            return "HEIC"
        case "public.jpeg":
            return "JPEG"
        default:
            return uti.split(separator: ".").last.map(String.init) ?? uti
        }
    }

    private func toggleExpanded(_ id: UUID) {
        if expandedRecords.contains(id) {
            expandedRecords.remove(id)
        } else {
            expandedRecords.insert(id)
        }
    }
}
