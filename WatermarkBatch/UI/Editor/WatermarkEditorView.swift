//
//  WatermarkEditorView.swift
//  WatermarkBatch（水印工坊 BatchMark）
//
//  块C · Tab2 水印编辑（PRD P-02 / F-04~F-15）
//  结构：预览画布（照片 / 视频时间轴 / Live 双预览位 / GIF 首帧+中间帧）
//        + 内容面板（文字 8 参数 / 图片 Logo）
//        + 位置与尺寸（九宫格 + 手绘手势 + 数值微调）
//        + 平铺 + 模板 / 参数 JSON。
//
//  红线：预览必须调 WatermarkCompositor.compositedFrame（见各 Preview 视图），本层不画水印。
//

import SwiftUI
import UniformTypeIdentifiers

struct WatermarkEditorView: View {

    @Environment(AppModel.self) private var model

    @State private var showTemplates = false
    @State private var showExporter = false
    @State private var showImporter = false
    @State private var showLogoImporter = false
    @State private var exportDocument: WatermarkConfigDocument?
    @State private var alertText: String?

    var body: some View {
        Group {
            if model.selectedAssets.isEmpty {
                EmptyStateView(
                    systemImage: "photo.badge.plus",
                    title: "还没有选择素材",
                    message: "先在「相册」页勾选要加水印的照片、Live Photo、动图或视频，再回来编辑。",
                    actionTitle: "去相册选择",
                    action: { model.selectedTab = .library }
                )
            } else {
                editorContent
            }
        }
        .navigationTitle("水印编辑")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("模板与参数…", systemImage: "square.stack.3d.up") { showTemplates = true }
                    Button("导出参数 JSON…", systemImage: "square.and.arrow.up") { exportConfig() }
                    Button("导入参数 JSON…", systemImage: "square.and.arrow.down") { showImporter = true }
                    Divider()
                    Button("设置…", systemImage: "gearshape") { model.showSettings = true }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showTemplates) {
            TemplatePanel()
        }
        .fileExporter(
            isPresented: $showExporter,
            document: exportDocument,
            contentType: .json,
            defaultFilename: "水印参数.json"
        ) { result in
            if case .failure(let error) = result {
                alertText = "导出失败：\(error.localizedDescription)"
            }
            exportDocument = nil
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            handleConfigImport(result)
        }
        .alert("提示", isPresented: Binding(
            get: { alertText != nil },
            set: { if !$0 { alertText = nil } }
        )) {
            Button("好", role: .cancel) { alertText = nil }
        } message: {
            Text(alertText ?? "")
        }
    }

    // MARK: - 主体

    private var editorContent: some View {
        @Bindable var model = model

        return VStack(spacing: 0) {
            previewArea(model: model)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    contentKindPicker
                    if model.isImageWatermark {
                        ImageWatermarkPicker()
                    } else {
                        TextConfigPanel(config: textConfigBinding)
                    }

                    SectionCard(title: "位置与尺寸") {
                        NumericAdjustView(
                            placement: $model.config.placement,
                            outputPixelSize: model.previewAsset?.pixelSize ?? CGSize(width: 390, height: 390)
                        )
                    }

                    TilingPanel(tiling: $model.config.tiling)

                    Text("预览与导出共用 WatermarkCompositor.compositedFrame 同一入口，归一化坐标相对输出像素；预览仅做显示降采样，不改变几何比例。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(16)
            }
        }
        .safeAreaInset(edge: .bottom) {
            bottomBar
        }
    }

    // MARK: - 预览

    @ViewBuilder
    private func previewArea(model: AppModel) -> some View {
        VStack(spacing: 0) {
            previewHeader
            Group {
                if let asset = model.previewAsset {
                    switch asset.kind {
                    case .photo, .raw:
                        PhotoPreviewView(asset: asset)
                    case .livePhoto:
                        LivePhotoPreviewView(asset: asset)
                    case .animated:
                        AnimatedPreviewView(asset: asset)
                    case .video:
                        VideoTimelinePreviewView(asset: asset)
                    }
                } else {
                    Color.black
                }
            }
            .frame(height: (model.previewAsset?.kind == .video) ? 380 : 290)
        }
        .background(Color.black)
    }

    private var previewHeader: some View {
        @Bindable var model = model

        return HStack(spacing: 8) {
            if let asset = model.previewAsset {
                Text(kindLabel(asset.kind))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.white.opacity(0.18), in: Capsule())

                Text(asset.originalFilename ?? "未命名")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)

                Text("\(Int(asset.pixelSize.width))×\(Int(asset.pixelSize.height))")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.55))
            }
            Spacer()
            Text("已选 \(model.selectionCount) 项")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.6))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.black.opacity(0.85))
    }

    // MARK: - 内容类型

    private var contentKindPicker: some View {
        @Bindable var model = model

        return Picker("水印类型", selection: Binding(
            get: { model.isImageWatermark ? 1 : 0 },
            set: { newValue in
                if newValue == 1 {
                    if model.imageWatermark != nil {
                        model.switchToImageWatermark()
                    } else {
                        showLogoImporter = true
                    }
                } else {
                    model.switchToTextWatermark()
                }
            }
        )) {
            Text("文字水印").tag(0)
            Text("图片水印").tag(1)
        }
        .pickerStyle(.segmented)
        .fileImporter(
            isPresented: $showLogoImporter,
            allowedContentTypes: [.png],
            allowsMultipleSelection: false
        ) { result in
            handleLogoImport(result)
        }
    }

    private var textConfigBinding: Binding<WatermarkTextConfig> {
        Binding(
            get: {
                if case .text(let config) = model.config.content { return config }
                return .standard(text: "水印工坊")
            },
            set: { model.config.content = .text($0) }
        )
    }

    // MARK: - 底栏

    private var bottomBar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.selectionDistributionText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(model.settings.skipWatermarked
                     ? "将跳过已加水印素材（\(ProcessingPolicy.skipDetectionDimensions)）"
                     : "共 \(model.selectionCount) 项待处理")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            Button {
                model.selectedTab = .batch
            } label: {
                Label("批量套用", systemImage: "square.stack.3d.down.right")
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) { Divider() }
    }

    // MARK: - 动作

    private func exportConfig() {
        do {
            exportDocument = try WatermarkConfigDocument(config: model.config)
            showExporter = true
        } catch {
            alertText = "生成参数 JSON 失败：\(error.localizedDescription)"
        }
    }

    private func handleConfigImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            alertText = "导入失败：\(error.localizedDescription)"
        case .success(let urls):
            guard let url = urls.first else { return }
            let didAccess = url.startAccessingSecurityScopedResource()
            defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                model.applyImportedConfig(try WatermarkConfigCodec.decode(data))
                model.toast = ToastMessage(text: "水印参数已导入")
            } catch {
                alertText = "该文件不是有效的水印参数 JSON：\(error.localizedDescription)"
            }
        }
    }

    private func handleLogoImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            alertText = "导入失败：\(error.localizedDescription)"
        case .success(let urls):
            guard let url = urls.first else { return }
            do {
                model.setImageWatermark(try ImageWatermarkImporter.load(from: url))
            } catch let error as WatermarkError {
                alertText = error.userReadableDescription
            } catch {
                alertText = "导入失败：\(error.localizedDescription)"
            }
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
