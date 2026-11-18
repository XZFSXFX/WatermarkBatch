//
//  LivePhotoPreviewView.swift
//  WatermarkBatch（水印工坊 BatchMark）
//
//  块C · Live Photo 双预览位（PRD F-14）
//  静帧位：still 数据 → compositedFrame(seconds: nil)；
//  动段位：配对 MOV 抽 0.35s 帧 → compositedFrame(seconds: 0.35)（timeRange 生效）。
//  两处共用同一 WatermarkConfig，位置/缩放一致性由同一归一化坐标保证。
//

import AVFoundation
import SwiftUI

struct LivePhotoPreviewView: View {

    let asset: LibraryAsset
    @Environment(AppModel.self) private var model

    /// 动段预览取帧时间（Live Photo 动段通常 1.5~3s，取 0.35s 避开起始抖动）。
    static let videoSegmentTime: Double = 0.35

    @State private var stillImage: CGImage?
    @State private var videoFrame: CGImage?
    @State private var outputImage: CGImage?
    @State private var showsVideoSegment = false
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
                    Picker("预览位", selection: $showsVideoSegment) {
                        Text("静帧").tag(false)
                        Text("动段").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 150)
                    .disabled(videoFrame == nil)
                    .onChange(of: showsVideoSegment) { _, _ in scheduleRender() }

                    Text(showsVideoSegment
                         ? String(format: "动段 %.2fs", Self.videoSegmentTime)
                         : "静帧")
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

    // MARK: 加载（静帧 + 动段抽帧）

    private func load() async {
        state = .loading(progress: nil)
        outputImage = nil
        stillImage = nil
        videoFrame = nil

        do {
            let pair = try await model.library.livePhotoPair(for: asset) { fraction in
                Task { @MainActor in
                    guard case .loading = self.state else { return }
                    self.state = .loading(progress: fraction)
                }
            }

            guard let still = PreviewImageDecoder.downsampled(
                pair.stillData,
                maxPixelSize: PhotoPreviewView.previewMaxPixelSize
            ) else {
                throw WatermarkError.renderFailed("Live Photo 静帧解码失败")
            }
            stillImage = still

            // 动段抽帧：preferredTransform 烘焙（与视频导出视觉方向一致）
            let avAsset = AVURLAsset(url: pair.videoURL)
            let generator = AVAssetImageGenerator(asset: avAsset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: PhotoPreviewView.previewMaxPixelSize,
                                           height: PhotoPreviewView.previewMaxPixelSize)
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 30)
            do {
                let (frame, _) = try await generator.image(
                    at: CMTime(seconds: Self.videoSegmentTime, preferredTimescale: 600)
                )
                videoFrame = frame
            } catch {
                // 动段抽帧失败不阻断静帧预览，但明确告知（不静默）
                videoFrame = nil
                model.toast = ToastMessage(text: "动段预览不可用：\(error.localizedDescription)")
            }
            PhotoLibraryService.removeTemporaryFile(at: pair.videoURL)

            state = .ready
            await render(base: still, seconds: nil)
        } catch {
            let message = (error as? WatermarkError)?.userReadableDescription
                ?? "读取 Live Photo 失败：\(error.localizedDescription)"
            state = .failed(message: message)
        }
    }

    // MARK: 渲染

    private func scheduleRender() {
        let base = showsVideoSegment ? videoFrame : stillImage
        guard let base else { return }
        renderTask?.cancel()
        let config = model.config
        let seconds: TimeInterval? = showsVideoSegment ? Self.videoSegmentTime : nil
        renderTask = Task {
            try? await Task.sleep(nanoseconds: 16_000_000)
            guard !Task.isCancelled else { return }
            await render(base: base, seconds: seconds, config: config)
        }
    }

    private func render(base: CGImage, seconds: TimeInterval?) async {
        await render(base: base, seconds: seconds, config: model.config)
    }

    private func render(base: CGImage, seconds: TimeInterval?, config: WatermarkConfig) async {
        let result = await PreviewCompositor.render(base: base, config: config, seconds: seconds)
        switch result {
        case .success(let boxed):
            outputImage = boxed.image
        case .failure(let error):
            state = .failed(message: error.userReadableDescription)
        }
    }
}
