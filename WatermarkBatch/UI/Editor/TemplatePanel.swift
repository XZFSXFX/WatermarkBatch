//
//  TemplatePanel.swift
//  WatermarkBatch（水印工坊 BatchMark）
//
//  块C · 模板与参数文件（PRD F-09，交付物 B）
//  - 保存当前全部参数（含图片水印 PNG）为模板，可应用 / 删除；
//  - 水印参数 JSON 导出到「文件」App，或从文件导入（Codable 完整往返）。
//

import SwiftUI
import UniformTypeIdentifiers

struct TemplatePanel: View {

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var nameDraft = ""
    @State private var errorText: String?
    @State private var pendingDelete: WatermarkTemplate?
    @State private var exportDocument: WatermarkConfigDocument?
    @State private var showExporter = false
    @State private var showImporter = false
    @State private var importSummary: String?

    var body: some View {
        NavigationStack {
            List {
                saveSection
                templateSection
                fileSection
                noteSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("模板与参数")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .alert("模板", isPresented: Binding(
                get: { errorText != nil },
                set: { if !$0 { errorText = nil } }
            )) {
                Button("好", role: .cancel) { errorText = nil }
            } message: {
                Text(errorText ?? "")
            }
            .alert("删除模板", isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            )) {
                Button("删除", role: .destructive) {
                    if let template = pendingDelete { delete(template) }
                    pendingDelete = nil
                }
                Button("取消", role: .cancel) { pendingDelete = nil }
            } message: {
                Text("删除后不可恢复：\(pendingDelete?.name ?? "")")
            }
            .fileExporter(
                isPresented: $showExporter,
                document: exportDocument,
                contentType: .json,
                defaultFilename: "水印参数-\(Self.dateStamp()).json"
            ) { result in
                switch result {
                case .success:
                    model.toast = ToastMessage(text: "参数已导出到「文件」")
                case .failure(let error):
                    errorText = "导出失败：\(error.localizedDescription)"
                }
                exportDocument = nil
            }
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: [.json],
                allowsMultipleSelection: false
            ) { result in
                handleImport(result)
            }
            .alert("导入结果", isPresented: Binding(
                get: { importSummary != nil },
                set: { if !$0 { importSummary = nil } }
            )) {
                Button("好", role: .cancel) { importSummary = nil }
            } message: {
                Text(importSummary ?? "")
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: 保存

    private var saveSection: some View {
        Section {
            HStack(spacing: 8) {
                TextField("模板名称（如：右下角版权）", text: $nameDraft)
                    .textFieldStyle(.plain)
                Button("保存") { save() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(nameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Text("保存内容：文字 8 参数 / 图片 Logo、位置、缩放、旋转、安全区、平铺、视频显示时间段。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        } header: {
            Text("保存当前参数")
        }
    }

    // MARK: 模板列表

    private var templateSection: some View {
        Section {
            if model.templates.isEmpty {
                Text("还没有模板。保存一次常用水印后，下次可一键套用。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.templates) { template in
                    Button {
                        model.applyTemplate(template)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(template.name)
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: "arrow.down.circle")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Text("\(contentLabel(template.config)) · \(BatchController.dateText(template.createdAt))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button("删除", role: .destructive) { pendingDelete = template }
                    }
                }
            }
        } header: {
            Text("我的模板（\(model.templates.count)）")
        }
    }

    // MARK: 参数文件

    private var fileSection: some View {
        Section {
            Button {
                do {
                    exportDocument = try WatermarkConfigDocument(config: model.config)
                    showExporter = true
                } catch {
                    errorText = "生成 JSON 失败：\(error.localizedDescription)"
                }
            } label: {
                Label("导出当前参数为 JSON", systemImage: "square.and.arrow.up")
            }

            Button {
                showImporter = true
            } label: {
                Label("从文件导入参数", systemImage: "square.and.arrow.down")
            }
        } header: {
            Text("参数文件（JSON）")
        } footer: {
            Text("导入会覆盖当前编辑中的水印参数（含 Logo 与位置），不影响已选素材与导出记录。")
        }
    }

    private var noteSection: some View {
        Section {
            Text("模板与参数文件均存于本机（Documents / 用户选择的文件位置），不含任何账号或网络请求。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: 动作

    private func save() {
        do {
            try model.saveTemplate(named: nameDraft)
            nameDraft = ""
            model.toast = ToastMessage(text: "模板已保存")
        } catch let error as WatermarkError {
            errorText = error.userReadableDescription
        } catch {
            errorText = "保存失败：\(error.localizedDescription)"
        }
    }

    private func delete(_ template: WatermarkTemplate) {
        do {
            try model.deleteTemplate(id: template.id)
            model.toast = ToastMessage(text: "已删除模板")
        } catch let error as WatermarkError {
            errorText = error.userReadableDescription
        } catch {
            errorText = "删除失败：\(error.localizedDescription)"
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            errorText = "导入失败：\(error.localizedDescription)"
        case .success(let urls):
            guard let url = urls.first else { return }
            let didAccess = url.startAccessingSecurityScopedResource()
            defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                let config = try WatermarkConfigCodec.decode(data)
                model.applyImportedConfig(config)
                importSummary = "已导入水印参数：\(contentLabel(config))"
            } catch {
                errorText = "该文件不是有效的水印参数 JSON：\(error.localizedDescription)"
            }
        }
    }

    private func contentLabel(_ config: WatermarkConfig) -> String {
        switch config.content {
        case .text(let text):
            let trimmed = text.text.replacingOccurrences(of: "\n", with: " ")
            return "文字「\(trimmed.prefix(12))」"
        case .image:
            return "图片 Logo"
        }
    }

    private static func dateStamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyyMMdd-HHmm"
        return formatter.string(from: Date())
    }
}
