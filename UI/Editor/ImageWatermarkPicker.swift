//
//  ImageWatermarkPicker.swift
//  WatermarkBatch（水印工坊 BatchMark）
//
//  块C · 图片水印导入（PRD F-05）
//  FileImporter 导入透明 PNG：pngData 原样保存（不缩放、不重编码、alpha 完整保留），
//  pixelSize 由解码结果写入 ImageWatermark；缩放在「位置与尺寸」区统一调节。
//

import ImageIO
import SwiftUI
import UniformTypeIdentifiers

struct ImageWatermarkPicker: View {

    @Environment(AppModel.self) private var model

    @State private var showImporter = false
    @State private var errorText: String?
    @State private var isImporting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let watermark = model.imageWatermark {
                importedContent(watermark)
            } else {
                emptyContent
            }
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.png],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                importPNG(from: url)
            case .failure(let error):
                errorText = "导入失败：\(error.localizedDescription)"
            }
        }
        .alert("图片水印", isPresented: Binding(
            get: { errorText != nil },
            set: { if !$0 { errorText = nil } }
        )) {
            Button("好", role: .cancel) { errorText = nil }
        } message: {
            Text(errorText ?? "")
        }
    }

    // MARK: 已导入

    private func importedContent(_ watermark: ImageWatermark) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                ZStack {
                    CheckerboardView()
                    if let image = PreviewImageDecoder.downsampled(watermark.pngData, maxPixelSize: 160) {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .scaledToFit()
                            .padding(6)
                    }
                }
                .frame(width: 92, height: 92)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color(.separator), lineWidth: 0.5)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Logo 已载入")
                        .font(.subheadline.weight(.semibold))
                    Text("原始像素 \(Int(watermark.pixelSize.width)) × \(Int(watermark.pixelSize.height))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text("文件大小 \(Format.bytes(watermark.pngData.count))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            HStack(spacing: 10) {
                Button("更换 PNG") { showImporter = true }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Button("移除 Logo", role: .destructive) {
                    model.clearImageWatermark()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Spacer()
            }

            Text("PNG 数据原样参与合成（保留 alpha，不重编码）；缩放/位置/旋转请在下方「位置与尺寸」调节。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: 空态

    private var emptyContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                showImporter = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "square.and.arrow.down")
                    VStack(alignment: .leading, spacing: 2) {
                        Text("导入 PNG Logo")
                            .font(.subheadline.weight(.semibold))
                        Text("需为透明背景 PNG；保留 alpha，不压缩")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(12)
                .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)

            Text("提示：半透明边缘必须由 PNG 自带 alpha 表达；本版本不额外提供图片水印不透明度（避免二次 alpha 叠乘产生灰边）。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: 导入

    private func importPNG(from url: URL) {
        isImporting = true
        defer { isImporting = false }
        do {
            let watermark = try ImageWatermarkImporter.load(from: url)
            model.setImageWatermark(watermark)
        } catch let error as WatermarkError {
            errorText = error.userReadableDescription
        } catch {
            errorText = "导入失败：\(error.localizedDescription)"
        }
    }
}

// MARK: - PNG 导入（编辑器切换「图片水印」时复用同一逻辑）

enum ImageWatermarkImporter {

    /// 读取安全作用域文件 → 校验 PNG + alpha → 返回保留原始字节的 ImageWatermark。
    static func load(from url: URL) throws -> ImageWatermark {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }

        let data = try Data(contentsOf: url)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw WatermarkError.unsupportedFormat("无法解析该 PNG")
        }
        guard let uti = CGImageSourceGetType(source) as String?, uti == UTType.png.identifier else {
            throw WatermarkError.unsupportedFormat("请选择 PNG 格式的透明 Logo")
        }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw WatermarkError.unsupportedFormat("PNG 解码失败")
        }
        // alpha 校验：alphaInfo == .none 说明是不透明图，合成后会出现白底方块
        guard image.alphaInfo != .none else {
            throw WatermarkError.unsupportedFormat("该 PNG 没有透明通道，导入后会出现白底")
        }
        return ImageWatermark(
            pngData: data,
            pixelSize: CGSize(width: image.width, height: image.height)
        )
    }
}

// MARK: - 棋盘底（展示透明通道）

struct CheckerboardView: View {
    var squareSize: CGFloat = 8

    var body: some View {
        Canvas { context, size in
            let columns = Int(ceil(size.width / squareSize))
            let rows = Int(ceil(size.height / squareSize))
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.22)))
            for row in 0..<rows {
                for column in 0..<columns where (row + column) % 2 == 0 {
                    let rect = CGRect(
                        x: CGFloat(column) * squareSize,
                        y: CGFloat(row) * squareSize,
                        width: squareSize,
                        height: squareSize
                    )
                    context.fill(Path(rect), with: .color(Color(white: 0.32)))
                }
            }
        }
    }
}
