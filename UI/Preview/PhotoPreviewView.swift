//
//  PhotoPreviewView.swift
//  WatermarkBatch（水印工坊 BatchMark）
//
//  块C · 照片实时预览（PRD F-11，红线：所见即所得）
//  底图 = 原图（仅 UI 展示降采样，≤屏幕 2 倍像素）；合成【必须】调
//  WatermarkCompositor.compositedFrame(base:config:outputPixelSize:seconds:)，禁止 UI 自绘水印。
//  归一化坐标相对输出像素，预览传入的 outputPixelSize 即降采样底图尺寸，
//  与导出链路共用同一公式 → 几何完全一致。
//

import SwiftUI

// MARK: - 预览加载状态

enum PreviewLoadState: Equatable {
    case loading(progress: Double?)
    case ready
    case failed(message: String)
}

/// 预览区状态遮罩（加载/下载进度/失败重试，失败不静默降级）。
struct PreviewStatusView: View {
    let state: PreviewLoadState
    var retry: (() -> Void)?

    var body: some View {
        switch state {
        case .loading(let progress):
            VStack(spacing: 10) {
                ProgressView()
                    .tint(.white)
                if let progress {
                    Text("正在下载原图 \(Int(progress * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.8))
                } else {
                    Text("正在读取原图…")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.8))
                }
            }
            .padding(18)
            .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        case .ready:
            EmptyView()
        case .failed(let message):
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.title3)
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
                if let retry {
                    Button("重试") { retry() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
            }
            .padding(18)
            .frame(maxWidth: 300)
            .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}

// MARK: - 预览画布（图片 + 手势层）

struct WatermarkPreviewCanvas: View {

    let image: CGImage
    @Binding var placement: WatermarkPlacement
    var safeMargin: CGFloat = 0.03

    var body: some View {
        Image(decorative: image, scale: 1)
            .resizable()
            .scaledToFit()
            .overlay {
                PlacementGestureView(
                    imagePixelSize: CGSize(width: image.width, height: image.height),
                    placement: $placement,
                    safeMarginNormalized: safeMargin
                )
            }
            .accessibilityLabel("水印预览画布")
    }
}

// MARK: - 预览合成入口（与导出同一管线）

/// 预览统一调用 `WatermarkCompositor.compositedFrame`（禁止任何 UI 自绘水印）。
/// 合成在后台线程执行（GPU 合成可跨线程），返回装箱 CGImage 供主线程展示。
enum PreviewCompositor {
    static func render(base: CGImage,
                       config: WatermarkConfig,
                       seconds: TimeInterval?) async -> Result<SendableImage, WatermarkError> {
        let boxed = SendableImage(image: base)
        let size = CGSize(width: base.width, height: base.height)
        return await Task.detached(priority: .userInitiated) {
            do {
                let output = try WatermarkCompositor.shared.compositedFrame(
                    base: boxed.image,
                    config: config,
                    outputPixelSize: size,
                    seconds: seconds
                )
                return .success(SendableImage(image: output))
            } catch let error as WatermarkError {
                return .failure(error)
            } catch {
                return .failure(.renderFailed(error.localizedDescription))
            }
        }.value
    }
}

// MARK: - 照片预览

struct PhotoPreviewView: View {

    let asset: LibraryAsset
    @Environment(AppModel.self) private var model

    /// 预览底图最大像素（≤ 屏幕 2 倍像素；iPhone 15 Pro Max 430pt × 3 ≈ 1290px，取 1600 留余量）。
    static let previewMaxPixelSize: CGFloat = 1600

    @State private var baseImage: CGImage?
    @State private var outputImage: CGImage?
    @State private var state: PreviewLoadState = .loading(progress: nil)
    @State private var renderTask: Task<Void, Never>?

    var body: some View {
        @Bindable var model = model

        ZStack {
            Color.black

            if let outputImage {
                WatermarkPreviewCanvas(
                    image: outputImage,
                    placement: $model.config.placement,
                    safeMargin: model.config.safeMarginNormalized
                )
                .padding(6)
            }

            if state != .ready {
                PreviewStatusView(state: state) {
                    Task { await load() }
                }
            }
        }
        .task(id: asset.id) {
            await load()
        }
        .onChange(of: model.config) { _, _ in
            scheduleRender()
        }
        .onDisappear {
            renderTask?.cancel()
        }
    }

    // MARK: 加载

    private func load() async {
        state = .loading(progress: nil)
        outputImage = nil
        do {
            let data = try await model.library.originalImageData(for: asset) { fraction in
                Task { @MainActor [weak self] in
                    guard let self, case .loading = self.state else { return }
                    self.state = .loading(progress: fraction)
                }
            }
            guard let base = PreviewImageDecoder.downsampled(data, maxPixelSize: Self.previewMaxPixelSize) else {
                throw WatermarkError.renderFailed("原图解码失败")
            }
            baseImage = base
            state = .ready
            await render(base: base, config: model.config)
        } catch {
            let message = (error as? WatermarkError)?.userReadableDescription
                ?? "读取原图失败：\(error.localizedDescription)"
            state = .failed(message: message)
        }
    }

    // MARK: 渲染（同管线 compositedFrame）

    private func scheduleRender() {
        guard let baseImage else { return }
        renderTask?.cancel()
        let config = model.config
        renderTask = Task {
            // 16ms 节流：手势高频变更时合并为下一帧渲染
            try? await Task.sleep(nanoseconds: 16_000_000)
            guard !Task.isCancelled else { return }
            await render(base: baseImage, config: config)
        }
    }

    private func render(base: CGImage, config: WatermarkConfig) async {
        let result = await PreviewCompositor.render(base: base, config: config, seconds: nil)
        switch result {
        case .success(let boxedOutput):
            outputImage = boxedOutput.image
        case .failure(let error):
            state = .failed(message: error.userReadableDescription)
        }
    }
}
