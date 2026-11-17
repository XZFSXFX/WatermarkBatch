//
//  AnimatedPreviewView.swift
//  WatermarkBatch（水印工坊 BatchMark）
//
//  块C · GIF / 动画 WebP 预览（PRD F-15）
//  首帧 + 中间帧切换并显示总帧数；每帧经 compositedFrame（seconds: nil）合成，
//  与 AnimatedImageProcessor 逐帧导出的几何完全一致。
//

import SwiftUI

struct AnimatedPreviewView: View {

    let asset: LibraryAsset
    @Environment(AppModel.self) private var model

    @State private var firstFrame: CGImage?
    @State private var middleFrame: CGImage?
    @State private var outputImage: CGImage?
    @State private var totalFrames = 0
    @State private var showsMiddle = false
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
        .overlay(alignment: .bottom) {
            if state == .ready {
                HStack(spacing: 10) {
                    Picker("帧", selection: $showsMiddle) {
                        Text("首帧").tag(false)
                        Text("中间帧").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 160)
                    .onChange(of: showsMiddle) { _, _ in scheduleRender() }

                    Text("共 \(totalFrames) 帧")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(.black.opacity(0.5), in: Capsule())
                }
                .padding(.bottom, 14)
            }
        }
        .task(id: asset.id) {
            await load()
        }
        .onChange(of: model.config) { _, _ in
            scheduleRender()
        }
        .onDisappear { renderTask?.cancel() }
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
            let decoded = PreviewImageDecoder.firstAndMiddle(data, maxPixelSize: PhotoPreviewView.previewMaxPixelSize)
            guard let first = decoded.first else {
                throw WatermarkError.renderFailed("动图首帧解码失败")
            }
            firstFrame = first
            middleFrame = decoded.middle
            totalFrames = decoded.total
            showsMiddle = false
            state = .ready
            await render(frame: first)
        } catch {
            let message = (error as? WatermarkError)?.userReadableDescription
                ?? "读取动图失败：\(error.localizedDescription)"
            state = .failed(message: message)
        }
    }

    // MARK: 渲染

    private func scheduleRender() {
        renderTask?.cancel()
        let frame: CGImage?
        if showsMiddle, let middle = middleFrame {
            frame = middle
        } else {
            frame = firstFrame
        }
        guard let frame else { return }
        let config = model.config
        renderTask = Task {
            try? await Task.sleep(nanoseconds: 16_000_000)
            guard !Task.isCancelled else { return }
            await render(frame: frame, config: config)
        }
    }

    private func render(frame: CGImage) async {
        await render(frame: frame, config: model.config)
    }

    private func render(frame: CGImage, config: WatermarkConfig) async {
        // 动图与照片同语义：seconds 恒传 nil（无时间轴）
        let result = await PreviewCompositor.render(base: frame, config: config, seconds: nil)
        switch result {
        case .success(let boxed):
            outputImage = boxed.image
        case .failure(let error):
            state = .failed(message: error.userReadableDescription)
        }
    }
}
