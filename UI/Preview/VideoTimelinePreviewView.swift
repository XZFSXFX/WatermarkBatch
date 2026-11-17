//
//  VideoTimelinePreviewView.swift
//  WatermarkBatch（水印工坊 BatchMark）
//
//  块C · 视频时间轴预览（PRD F-12/F-13，红线：禁止「大概示意」）
//
//  实现：AVPlayer + AVMutableVideoComposition(applyingCIFiltersWithHandler:)
//  每帧在回调里调 `WatermarkCompositor.compositedFrame(seconds: compositionTime)` ——
//  预览与 VideoProcessor 导出同一入口、同一归一化几何，水印时间段的显隐也由同一函数判定。
//
//  性能：
//  - 合成分辨率降到长边 ≤1280（"降采样解码"，归一化几何不受影响，§六.5 允许预览降采样）；
//  - 拖动时间轴时 seek 以 33ms（≈30fps）节流，连续拖动只保留最后一次；
//  - 配置快照放线程安全盒子里逐帧读取，手势调整水印不会重建 composition。
//

import AVFoundation
import SwiftUI
import UIKit

// MARK: - 配置快照盒

/// 逐帧读取的水印配置快照（避免每次手势变更重建视频合成）。
final class PreviewConfigBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: WatermarkConfig

    init(_ value: WatermarkConfig) {
        self.value = value
    }

    var config: WatermarkConfig {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func update(_ newValue: WatermarkConfig) {
        lock.lock(); value = newValue; lock.unlock()
    }
}

/// 仅做 CGImage ↔ CIImage 转换（不绘制水印；水印一律由 compositor 负责）。
nonisolated(unsafe) private let previewCIContext: CIContext = CIContext(options: [.cacheIntermediates: false])

// MARK: - 视频预览

struct VideoTimelinePreviewView: View {

    let asset: LibraryAsset
    @Environment(AppModel.self) private var model

    /// 预览合成长边上限（降采样解码，导出仍是原分辨率）。
    static let previewMaxLongSide: CGFloat = 1280

    @State private var player: AVPlayer?
    @State private var configBox: PreviewConfigBox?
    @State private var duration: Double = 0
    @State private var currentTime: Double = 0
    @State private var isPlaying = false
    @State private var videoURL: URL?
    @State private var filmstrip: [CGImage] = []
    @State private var state: PreviewLoadState = .loading(progress: nil)
    /// 视频显示尺寸（preferredTransform 烘焙后），仅用于手势层 aspect-fit 换算。
    @State private var displayPixelSize: CGSize = .zero

    @State private var timeObserver: Any?
    @State private var seekTask: Task<Void, Never>?
    @State private var filmstripTask: Task<Void, Never>?

    var body: some View {
        @Bindable var model = model

        VStack(spacing: 0) {
            ZStack {
                Color.black
                if let player {
                    PlayerLayerContainer(player: player)
                        .overlay(alignment: .center) {
                            if !isPlaying {
                                Image(systemName: "play.circle.fill")
                                    .font(.system(size: 46))
                                    .foregroundStyle(.white.opacity(0.85))
                                    .shadow(radius: 4)
                                    .allowsHitTesting(false)
                            }
                        }
                }
                // 手势层：拖动/缩放/旋转水印（几何与导出同一归一化坐标）
                if configBox != nil, displayPixelSize.width > 0 {
                    PlacementGestureView(
                        imagePixelSize: displayPixelSize,
                        placement: $model.config.placement,
                        safeMarginNormalized: model.config.safeMarginNormalized
                    )
                }
                if state != .ready {
                    PreviewStatusView(state: state) {
                        Task { await load() }
                    }
                }
            }
            .frame(maxHeight: .infinity)

            timelinePanel
                .background(.black.opacity(0.35))
            timeRangeEditor
        }
        .task(id: asset.id) {
            await load()
        }
        .onChange(of: model.config) { _, newValue in
            configBox?.update(newValue)
            if !isPlaying { refreshPausedFrame() }
        }
        .onDisappear {
            teardown()
        }
    }

    // MARK: 时间轴

    private var timelinePanel: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Button {
                    togglePlayback()
                } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 30, height: 30)
                        .background(.white.opacity(0.12), in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(player == nil)

                Text(Format.clock(currentTime))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white)

                Slider(
                    value: Binding(
                        get: { min(currentTime, max(duration, 0.01)) },
                        set: { newValue in
                            currentTime = newValue
                            seek(to: newValue)
                        }
                    ),
                    in: 0...max(duration, 0.01)
                )
                .tint(.white)
                .disabled(player == nil)

                Text(Format.clock(duration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.7))
            }

            if !filmstrip.isEmpty {
                HStack(spacing: 2) {
                    ForEach(Array(filmstrip.enumerated()), id: \.offset) { _, frame in
                        Image(decorative: frame, scale: 1)
                            .resizable()
                            .scaledToFill()
                            .frame(height: 30)
                            .clipped()
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .opacity(0.75)
            }

            Text("拖动时间轴即按真实帧渲染水印（预览静音；导出保留原音轨，音频直通不重编码）")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: 时间段

    private var timeRangeEditor: some View {
        @Bindable var model = model

        return VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding(
                get: { model.config.timeRange == nil },
                set: { isWhole in
                    if isWhole {
                        model.config.timeRange = nil
                    } else {
                        model.config.timeRange = 0...max(duration, 0.1)
                    }
                    configBox?.update(model.config)
                }
            )) {
                Text("全程显示水印")
                    .font(.caption)
            }
            .tint(.accentColor)

            if let range = model.config.timeRange {
                HStack(spacing: 10) {
                    NumericFieldRow(
                        title: "开始",
                        unit: "s",
                        value: range.lowerBound,
                        range: 0...max(duration, 0.1),
                        step: 0.1,
                        decimals: 1
                    ) { newValue in
                        let upper = max(range.upperBound, newValue + 0.1)
                        model.config.timeRange = newValue...min(upper, max(duration, newValue + 0.1))
                        configBox?.update(model.config)
                        if !isPlaying { refreshPausedFrame() }
                    }

                    NumericFieldRow(
                        title: "结束",
                        unit: "s",
                        value: range.upperBound,
                        range: 0...max(duration, 0.1),
                        step: 0.1,
                        decimals: 1
                    ) { newValue in
                        let lower = min(range.lowerBound, max(newValue - 0.1, 0))
                        model.config.timeRange = lower...max(newValue, lower + 0.1)
                        configBox?.update(model.config)
                        if !isPlaying { refreshPausedFrame() }
                    }
                }
                Text("导出时水印仅在此区间出现（误差 <1 帧）；区间外画面无水印。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
    }

    // MARK: 加载

    private func load() async {
        state = .loading(progress: nil)
        do {
            let url = try await model.library.originalVideoURL(for: asset) { fraction in
                Task { @MainActor [weak self] in
                    guard let self, case .loading = self.state else { return }
                    self.state = .loading(progress: fraction)
                }
            }
            videoURL = url

            let avAsset = AVURLAsset(url: url)
            guard let track = try await avAsset.loadTracks(withMediaType: .video).first else {
                throw WatermarkError.unsupportedFormat("视频缺少视频轨")
            }
            let naturalSize = try await track.load(.naturalSize)
            let transform = try await track.load(.preferredTransform)
            let nominalFPS = try await track.load(.nominalFrameRate)
            let assetDuration = try await avAsset.load(.duration).seconds

            let displayRect = CGRect(origin: .zero, size: naturalSize).applying(transform)
            let displaySize = CGSize(width: abs(displayRect.width), height: abs(displayRect.height))
            let renderSize = Self.renderSize(for: displaySize)
            let fps = nominalFPS >= 24 ? Double(nominalFPS) : 30.0
            displayPixelSize = displaySize

            let box = PreviewConfigBox(model.config)
            let composition = Self.makeComposition(
                asset: avAsset,
                renderSize: renderSize,
                frameRate: fps,
                configBox: box
            )

            let item = AVPlayerItem(asset: avAsset)
            item.videoComposition = composition
            let newPlayer = AVPlayer(playerItem: item)
            newPlayer.isMuted = true   // 预览静音：拖动时不产生音频噪声；导出音轨不受影响

            player = newPlayer
            configBox = box
            duration = max(assetDuration, 0.1)
            currentTime = 0
            state = .ready

            addTimeObserver(to: newPlayer)
            isPlaying = false
            loadFilmstrip(url: url, duration: duration)
        } catch {
            let message = (error as? WatermarkError)?.userReadableDescription
                ?? "读取视频失败：\(error.localizedDescription)"
            state = .failed(message: message)
        }
    }

    // MARK: 合成构建

    private static func makeComposition(asset: AVAsset,
                                        renderSize: CGSize,
                                        frameRate: Double,
                                        configBox: PreviewConfigBox) -> AVMutableVideoComposition {
        let composition = AVMutableVideoComposition(asset: asset) { request in
            let source = request.sourceImage
            let extent = source.extent
            guard extent.width > 1, extent.height > 1,
                  let cgImage = previewCIContext.createCGImage(source, from: extent) else {
                request.finish(with: source, context: nil)
                return
            }

            // 与导出同一入口：seconds = 当前帧时间 → timeRange 显隐一致
            do {
                let composited = try WatermarkCompositor.shared.compositedFrame(
                    base: cgImage,
                    config: configBox.config,
                    outputPixelSize: CGSize(width: cgImage.width, height: cgImage.height),
                    seconds: request.compositionTime.seconds
                )
                request.finish(with: CIImage(cgImage: composited), context: nil)
            } catch {
                request.finish(with: error)
            }
        }
        composition.renderSize = renderSize
        composition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(frameRate.rounded(), 24)))
        return composition
    }

    /// 预览渲染尺寸：长边 ≤1280，取偶数（编码友好的宽高约定）。
    private static func renderSize(for displaySize: CGSize) -> CGSize {
        guard displaySize.width > 0, displaySize.height > 0 else {
            return CGSize(width: 720, height: 1280)
        }
        let longSide = max(displaySize.width, displaySize.height)
        let scale = min(1, previewMaxLongSide / longSide)
        let width = max(2, (displaySize.width * scale / 2).rounded() * 2)
        let height = max(2, (displaySize.height * scale / 2).rounded() * 2)
        return CGSize(width: width, height: height)
    }

    // MARK: 播放控制

    private func addTimeObserver(to player: AVPlayer) {
        if let observer = timeObserver {
            player.removeTimeObserver(observer)
            timeObserver = nil
        }
        let interval = CMTime(value: 1, timescale: 20)   // 50ms 刷新
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            Task { @MainActor [weak self] in
                guard let self, self.isPlaying else { return }
                let seconds = time.seconds
                if seconds.isFinite { self.currentTime = min(max(seconds, 0), self.duration) }
            }
        }
    }

    private func togglePlayback() {
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            if currentTime >= duration - 0.05 {
                currentTime = 0
                player.seek(to: .zero)
            }
            player.play()
            isPlaying = true
        }
    }

    /// 拖动 seek：33ms 节流（≈30fps），只保留最后一次，避免解码队列堆积。
    private func seek(to seconds: Double) {
        seekTask?.cancel()
        let target = CMTime(seconds: seconds, preferredTimescale: 600)
        seekTask = Task {
            try? await Task.sleep(nanoseconds: 33_000_000)
            guard !Task.isCancelled, let player else { return }
            _ = await player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    /// 暂停时配置变更：seek 到当前时间（轻微 +1/600s 偏移确保重新渲染），刷新当前帧水印。
    private func refreshPausedFrame() {
        guard let player, let item = player.currentItem else { return }
        let now = item.currentTime()
        let nudged = CMTimeAdd(now, CMTime(value: 1, timescale: 600))
        let target = CMTimeCompare(nudged, CMTime(seconds: duration, preferredTimescale: 600)) < 0 ? nudged : now
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    // MARK: 胶片条

    private func loadFilmstrip(url: URL, duration: Double) {
        filmstripTask?.cancel()
        guard duration > 0 else { return }
        filmstripTask = Task {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 160, height: 160)
            generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 10)
            generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 10)

            var frames: [CGImage] = []
            for index in 0..<6 {
                if Task.isCancelled { return }
                let seconds = duration * (Double(index) + 0.5) / 6
                if let (image, _) = try? await generator.image(
                    at: CMTime(seconds: seconds, preferredTimescale: 600)
                ) {
                    frames.append(image)
                }
            }
            guard !Task.isCancelled else { return }
            filmstrip = frames
        }
    }

    // MARK: 清理

    private func teardown() {
        player?.pause()
        if let observer = timeObserver, let player {
            player.removeTimeObserver(observer)
        }
        timeObserver = nil
        seekTask?.cancel()
        filmstripTask?.cancel()
        player = nil
        if let url = videoURL {
            PhotoLibraryService.removeTemporaryFile(at: url)
        }
        videoURL = nil
    }
}

// MARK: - AVPlayerLayer 承载

struct PlayerLayerContainer: UIViewRepresentable {

    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerHostView {
        let view = PlayerHostView()
        view.backgroundColor = .black
        view.playerLayer.videoGravity = .resizeAspect
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ uiView: PlayerHostView, context: Context) {
        if uiView.playerLayer.player !== player {
            uiView.playerLayer.player = player
        }
    }
}

final class PlayerHostView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }

    var playerLayer: AVPlayerLayer {
        // layerClass 已固定为 AVPlayerLayer
        layer as! AVPlayerLayer
    }
}
