//
//  AlbumPickerView.swift
//  WatermarkBatch（水印工坊 BatchMark）
//
//  块C · Tab1 相册选择（PRD P-01 / F-01 / F-02 / F-03 / F-25）
//  - 按拍摄日倒序分组、分组头吸顶；
//  - 混合多选（照片 / Live Photo / GIF·WebP / 视频 / RAW），类型角标由 AssetCellView 渲染；
//  - iCloud 下载进度与失败重试入口（失败只报错，绝不静默降级缩略图）；
//  - 全选 / 反选 / 已选计数与类型分布；「开始编辑」进入 Tab2。
//

import SwiftUI

struct AlbumPickerView: View {

    @Environment(AppModel.self) private var model

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 3), count: 3)

    var body: some View {
        Group {
            if !model.hasLoadedOnce {
                loadingView
            } else {
                switch model.accessLevel {
                case .denied, .addOnly:
                    PermissionGuideView(accessLevel: model.accessLevel) {
                        PhotoAppLink.openAppSettings()
                    }
                case .full:
                    libraryContent
                }
            }
        }
        .navigationTitle("相册")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Button("全选", systemImage: "checkmark.circle") { model.selectAll() }
                    Button("反选", systemImage: "circle.lefthalf.filled") { model.invertSelection() }
                    Button("清空选择", systemImage: "xmark.circle", role: .destructive) { model.clearSelection() }
                    Divider()
                    Button("重新读取相册", systemImage: "arrow.clockwise") {
                        Task { await model.refreshLibrary() }
                    }
                } label: {
                    Image(systemName: "checklist")
                }
                .disabled(model.accessLevel != .full)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    model.showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if model.accessLevel == .full && !model.assets.isEmpty {
                selectionBar
            }
        }
    }

    // MARK: 加载态

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("正在读取相册…")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 内容

    @ViewBuilder
    private var libraryContent: some View {
        if model.assets.isEmpty {
            EmptyStateView(
                systemImage: "photo.on.rectangle.angled",
                title: "相册里还没有素材",
                message: "请先在系统相册中添加照片或视频；若刚授予权限，可下拉重试。",
                actionTitle: "重新读取",
                action: { Task { await model.refreshLibrary() } }
            )
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10, pinnedViews: [.sectionHeaders]) {
                    ForEach(model.groups) { group in
                        Section {
                            LazyVGrid(columns: columns, spacing: 3) {
                                ForEach(group.assets) { asset in
                                    cell(for: asset)
                                }
                            }
                            .padding(.horizontal, 3)
                        } header: {
                            dayHeader(for: group)
                        }
                    }
                }
                .padding(.bottom, 12)
            }
            .refreshable {
                await model.refreshLibrary()
            }
        }
    }

    private func cell(for asset: LibraryAsset) -> some View {
        AssetCellView(
            asset: asset,
            isSelected: model.isSelected(asset),
            cloudState: model.cloudState(for: asset),
            onTap: { model.toggleSelection(asset) },
            onCloudAction: {
                if case .failed(let message) = model.cloudState(for: asset) {
                    model.toast = ToastMessage(text: "重试下载：\(message)")
                }
                model.downloadOriginal(asset)
            }
        )
    }

    private func dayHeader(for group: AssetDayGroup) -> some View {
        HStack(spacing: 6) {
            Text(Self.dayTitle(group.id))
                .font(.subheadline.weight(.semibold))
            Text("\(group.assets.count)")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Color(.tertiarySystemFill), in: Capsule())
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.bar)
    }

    // MARK: 底栏

    private var selectionBar: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.selectionCount == 0 ? "未选择素材" : "已选 \(model.selectionCount) 项")
                    .font(.subheadline.weight(.semibold))
                Text(model.selectionDistributionText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button {
                model.beginEditing()
            } label: {
                Text("开始编辑")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .disabled(model.selectionCount == 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Divider()
        }
    }

    // MARK: 日期标题

    static func dayTitle(_ date: Date) -> String {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        if calendar.isDateInToday(date) {
            formatter.dateFormat = "今天"
        } else if calendar.isDateInYesterday(date) {
            formatter.dateFormat = "昨天"
        } else if calendar.component(.year, from: date) == calendar.component(.year, from: Date()) {
            formatter.dateFormat = "M月d日 EEEE"
        } else {
            formatter.dateFormat = "yyyy年M月d日"
        }
        return formatter.string(from: date)
    }
}
