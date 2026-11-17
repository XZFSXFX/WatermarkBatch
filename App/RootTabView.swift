//
//  RootTabView.swift
//  WatermarkBatch（水印工坊 BatchMark）
//
//  块C · 四页签主框架（PRD F-26）：相册选择 / 水印编辑 / 批量任务 / 导出记录。
//  处理中不阻塞 UI：批处理全部在块B 队列的并发域内，本视图只读 AppModel 的快照。
//

import SwiftUI

struct RootTabView: View {

    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var model = model

        TabView(selection: $model.selectedTab) {
            NavigationStack {
                AlbumPickerView()
            }
            .tabItem {
                Label("相册", systemImage: "photo.on.rectangle.angled")
            }
            .tag(AppTab.library)

            NavigationStack {
                WatermarkEditorView()
            }
            .tabItem {
                Label("水印", systemImage: "textformat.size")
            }
            .tag(AppTab.editor)

            NavigationStack {
                BatchTaskView()
            }
            .tabItem {
                Label("批量", systemImage: "square.stack.3d.down.right")
            }
            .tag(AppTab.batch)
            .badge(model.batch.isRunning || model.batch.isExporting ? model.batch.finishedCount : 0)

            NavigationStack {
                ExportRecordView()
            }
            .tabItem {
                Label("记录", systemImage: "clock.arrow.circlepath")
            }
            .tag(AppTab.records)
        }
        .task {
            await model.bootstrap()
        }
        .onChange(of: scenePhase) { oldPhase, newPhase in
            // 从后台/系统设置返回：权限可能已变更，静默刷新相册（首次启动由 .task 负责）
            guard newPhase == .active, oldPhase != .active else { return }
            Task { await model.refreshLibrary() }
        }
        .sheet(isPresented: $model.showSettings) {
            SettingsView()
        }
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                ToastView(text: toast.text)
                    .padding(.bottom, 72)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task(id: toast.id) {
                        try? await Task.sleep(nanoseconds: 2_200_000_000)
                        if model.toast?.id == toast.id { model.toast = nil }
                    }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.toast)
    }
}

// MARK: - 轻提示

struct ToastView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.footnote.weight(.medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.12), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
    }
}

// MARK: - 通用空态

struct EmptyStateView: View {
    let systemImage: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

// MARK: - 通用卡片

struct SectionCard<Content: View>: View {
    let title: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                Text(title)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

// MARK: - 权限引导卡片（PRD F-25，文案见 §7.1）

struct PermissionGuideView: View {
    let accessLevel: PhotoAccessLevel
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: accessLevel == .addOnly ? "plus.rectangle.on.folder" : "lock.slash")
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(.orange)

            Text(accessLevel == .addOnly ? "当前为「仅添加照片」权限" : "未获得相册访问权限")
                .font(.headline)

            Text(accessLevel == .addOnly
                 ? "仅添加权限只能把处理结果保存回相册，无法读取既有的照片与视频，因此无法批量导入。请在系统设置中改为「完全访问」后返回。"
                 : "水印工坊需要读取你选择的照片和视频才能加水印。所有处理均在本机完成，不上传、不修改原片。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            Button("打开系统设置", action: onOpenSettings)
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
