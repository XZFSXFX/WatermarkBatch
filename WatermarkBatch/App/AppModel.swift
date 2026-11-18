//
//  AppModel.swift
//  WatermarkBatch（水印工坊 BatchMark）
//
//  块C · 应用级状态（@MainActor @Observable，单一数据源）
//
//  分层约束：UI 只与本类交互；本类调用块A（PhotoLibraryService / WatermarkCompositor /
//  WatermarkTemplateStore）与块B（BatchQueue / ExportService）的公开契约 API，不反向侵入。
//

import CoreGraphics
import Observation
import SwiftUI
import UIKit

// MARK: - 页签

enum AppTab: Hashable {
    case library, editor, batch, records
}

// MARK: - 用户设置

struct AppSettings: Codable, Sendable, Equatable {
    /// 跳过已加水印素材（文件名 + 像素尺寸 + 修改时间判定）。
    var skipWatermarked: Bool = false
    /// 完成后本地通知。
    var notifyOnFinish: Bool = true
    /// 导出后归入「已加水印」相簿（块A AlbumWriter 的幂等相簿）。
    var autoAlbum: Bool = true
    /// 隐藏调试面板是否已解锁（长按设置页标题 2 秒）。
    var debugPanelUnlocked: Bool = false

    static let standard = AppSettings()
}

enum AppSettingsStore {
    private static let key = "batchmark.settings.v1"

    static func load() -> AppSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return .standard
        }
        return decoded
    }

    static func save(_ settings: AppSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

// MARK: - iCloud 状态

enum CloudState: Equatable, Sendable {
    case probing            // 正在探测是否在 iCloud
    case local              // 本地已有原图
    case inCloud            // 仅在 iCloud（显示云朵角标与下载入口）
    case downloading(Double)
    case failed(String)     // 下载失败（可重试，绝不静默降级缩略图）

    var isDownloading: Bool {
        if case .downloading = self { return true }
        return false
    }
}

// MARK: - 轻提示

struct ToastMessage: Identifiable, Equatable {
    let id = UUID()
    let text: String
}

// MARK: - 应用状态

@MainActor
@Observable
final class AppModel {

    // MARK: 块A 依赖

    let library = PhotoLibraryService()
    let compositor = WatermarkCompositor.shared
    let templateStore = WatermarkTemplateStore()

    // MARK: 块C 子状态

    let batch = BatchController()

    // MARK: 相册

    var accessLevel: PhotoAccessLevel = .denied
    var assets: [LibraryAsset] = []
    var groups: [AssetDayGroup] = []
    var isLoadingLibrary = false
    var libraryLoadFailed = false
    /// 首次取数是否完成（决定显示骨架屏还是权限引导，避免启动瞬间误判为「被拒绝」）。
    var hasLoadedOnce = false
    var selection: Set<String> = []
    var cloudStates: [String: CloudState] = [:]

    // MARK: 编辑

    var selectedTab: AppTab = .library
    var config: WatermarkConfig = .standard(content: .text(.standard(text: "水印工坊")))
    var templates: [WatermarkTemplate] = []
    var previewAssetIdentifier: String?

    // MARK: 策略与设置

    var policy: ProcessingPolicy = .current
    var settings: AppSettings = AppSettingsStore.load()
    var showSettings = false
    var pendingShowRecords = false
    var toast: ToastMessage?

    // MARK: 记录

    var history: [BatchHistoryRecord] = []

    // MARK: 预览画布像素基准（缩略图/预览基图目标尺寸，仅 UI 用）

    /// 缩略图目标像素（PHCachingImageManager 契约单位为像素）。3 列网格 × 屏宽 2 倍余量。
    static let thumbnailTargetPixels: CGFloat = 512

    // 上一次使用的图片水印（在文字/图片内容间切换时保留 Logo 数据）
    private var lastImageWatermark: ImageWatermark?

    // MARK: - 初始化

    init() {
        history = BatchHistoryStore.load()
        templates = templateStore.all()
        NotificationManager.shared.register()
        // BGProcessingTask 注册必须早于 didFinishLaunching 结束（AppModel 在 @main 构造）
        BGTaskCoordinator.shared.register()
        NotificationManager.shared.onTap = { [weak self] _ in
            self?.pendingShowRecords = true
            self?.selectedTab = .records
        }
        batch.onBatchFinished = { [weak self] record in
            guard let self else { return }
            self.history.insert(record, at: 0)
            self.history = Array(self.history.prefix(50))
            BatchHistoryStore.save(self.history)
            // 前台批次已收尾：清理后台续跑待办
            BGTaskCoordinator.shared.clearPending()
        }
        batch.onNotify = { [weak self] succeeded, failed in
            guard let self, self.settings.notifyOnFinish else { return }
            NotificationManager.shared.notifyBatchFinished(succeeded: succeeded, failed: failed)
        }
    }

    // MARK: - 启动

    func bootstrap() async {
        // 块B 存储裁剪（记录 30 天 / 日志 30 天）
        ExportRecordStore.shared.prune()
        BatchLogStore.shared.purgeLogs()
        await refreshLibrary()
    }

    func refreshLibrary() async {
        isLoadingLibrary = true
        libraryLoadFailed = false
        defer { isLoadingLibrary = false }

        let level = await library.requestAccess()
        accessLevel = level
        hasLoadedOnce = true
        guard level == .full else {
            assets = []
            groups = []
            library.stopCaching()
            return
        }

        let fetched = await library.fetchAllAssets()
        assets = fetched
        groups = library.groupByDay(fetched)
        libraryLoadFailed = fetched.isEmpty

        // 选中态与刷新后的素材求交（避免已删除素材残留）
        let validIDs = Set(fetched.map(\.assetIdentifier))
        selection = selection.intersection(validIDs)

        library.startCaching(fetched, targetSize: CGSize(
            width: Self.thumbnailTargetPixels,
            height: Self.thumbnailTargetPixels
        ))
    }

    // MARK: - 选择

    var selectedAssets: [LibraryAsset] {
        assets.filter { selection.contains($0.assetIdentifier) }
    }

    var selectionCount: Int { selection.count }

    /// 已选素材的类型分布（底栏与确认框共用）。
    func typeDistribution(of assets: [LibraryAsset]) -> (photos: Int, lives: Int, gifs: Int, videos: Int, raws: Int) {
        var photos = 0, lives = 0, gifs = 0, videos = 0, raws = 0
        for asset in assets {
            switch asset.kind {
            case .photo: photos += 1
            case .livePhoto: lives += 1
            case .animated: gifs += 1
            case .video: videos += 1
            case .raw: raws += 1
            }
        }
        return (photos, lives, gifs, videos, raws)
    }

    var selectionDistributionText: String {
        let distribution = typeDistribution(of: selectedAssets)
        var parts: [String] = []
        if distribution.photos > 0 { parts.append("照片 \(distribution.photos)") }
        if distribution.lives > 0 { parts.append("Live \(distribution.lives)") }
        if distribution.gifs > 0 { parts.append("动图 \(distribution.gifs)") }
        if distribution.videos > 0 { parts.append("视频 \(distribution.videos)") }
        if distribution.raws > 0 { parts.append("RAW \(distribution.raws)") }
        return parts.isEmpty ? "未选择素材" : parts.joined(separator: " · ")
    }

    func isSelected(_ asset: LibraryAsset) -> Bool {
        selection.contains(asset.assetIdentifier)
    }

    func toggleSelection(_ asset: LibraryAsset) {
        if selection.contains(asset.assetIdentifier) {
            selection.remove(asset.assetIdentifier)
        } else {
            selection.insert(asset.assetIdentifier)
        }
    }

    func selectAll() {
        selection = Set(assets.map(\.assetIdentifier))
    }

    func invertSelection() {
        selection = Set(assets.map(\.assetIdentifier)).subtracting(selection)
    }

    func clearSelection() {
        selection.removeAll()
    }

    /// 「开始编辑」：选中即跳到编辑页；未选则提示。
    func beginEditing() {
        guard !selectedAssets.isEmpty else {
            toast = ToastMessage(text: "请先勾选至少 1 个素材")
            return
        }
        if previewAssetIdentifier == nil || !selection.contains(previewAssetIdentifier ?? "") {
            previewAssetIdentifier = selectedAssets.first?.assetIdentifier
        }
        selectedTab = .editor
    }

    /// 编辑页当前预览素材（默认第一张选中素材）。
    var previewAsset: LibraryAsset? {
        if let id = previewAssetIdentifier,
           let asset = selectedAssets.first(where: { $0.assetIdentifier == id }) {
            return asset
        }
        return selectedAssets.first
    }

    // MARK: - iCloud 状态与下载

    func cloudState(for asset: LibraryAsset) -> CloudState {
        cloudStates[asset.assetIdentifier] ?? .probing
    }

    /// 惰性探测「是否仅在 iCloud」（照片/RAW/动图支持；视频/ Live 由真实下载进度暴露）。
    func probeCloudIfNeeded(_ asset: LibraryAsset) {
        guard cloudStates[asset.assetIdentifier] == nil else { return }
        guard asset.kind == .photo || asset.kind == .raw || asset.kind == .animated else { return }
        cloudStates[asset.assetIdentifier] = .probing
        Task { [weak self] in
            guard let self else { return }
            let inCloud = await self.library.isOriginalInICloud(asset)
            guard case .probing = self.cloudStates[asset.assetIdentifier] ?? .local else { return }
            self.cloudStates[asset.assetIdentifier] = inCloud ? .inCloud : .local
        }
    }

    /// 主动下载原图（列表云端角标点击、失败重试入口）。
    /// 下载完成后原图进入 PhotoLibraryService 的原图缓存，编辑/批处理不再重复下载。
    /// 视频与 Live 配对 MOV 仅在「验证本地可用」后删除临时文件（正式处理时由块B 再取一次）。
    func downloadOriginal(_ asset: LibraryAsset) {
        if case .downloading = cloudStates[asset.assetIdentifier] { return }
        cloudStates[asset.assetIdentifier] = .downloading(0)

        let identifier = asset.assetIdentifier
        Task { [weak self] in
            guard let self else { return }
            do {
                switch asset.kind {
                case .photo, .raw, .animated:
                    _ = try await self.library.originalImageData(for: asset) { fraction in
                        Task { @MainActor [weak self] in
                            self?.applyDownloadProgress(identifier: identifier, fraction: fraction)
                        }
                    }
                case .livePhoto:
                    let pair = try await self.library.livePhotoPair(for: asset) { fraction in
                        Task { @MainActor [weak self] in
                            self?.applyDownloadProgress(identifier: identifier, fraction: fraction)
                        }
                    }
                    PhotoLibraryService.removeTemporaryFile(at: pair.videoURL)
                case .video:
                    let url = try await self.library.originalVideoURL(for: asset) { fraction in
                        Task { @MainActor [weak self] in
                            self?.applyDownloadProgress(identifier: identifier, fraction: fraction)
                        }
                    }
                    PhotoLibraryService.removeTemporaryFile(at: url)
                }
                self.cloudStates[identifier] = .local
            } catch {
                let message = (error as? WatermarkError)?.userReadableDescription
                    ?? "原图下载失败：\(error.localizedDescription)"
                self.cloudStates[identifier] = .failed(message)
            }
        }
    }

    private func applyDownloadProgress(identifier: String, fraction: Double) {
        guard case .downloading(let current) = cloudStates[identifier] ?? .local else { return }
        // 进度节流：回调可能高频，仅当变化 ≥1% 才刷新 UI
        guard fraction - current >= 0.01 || fraction >= 0.999 else { return }
        cloudStates[identifier] = .downloading(min(max(fraction, 0), 1))
    }

    // MARK: - 水印内容切换

    var isImageWatermark: Bool {
        if case .image = config.content { return true }
        return false
    }

    func switchToTextWatermark() {
        if case .text = config.content { return }
        config.content = .text(.standard(text: "水印工坊"))
    }

    func switchToImageWatermark() {
        if case .image = config.content { return }
        if let existing = lastImageWatermark {
            config.content = .image(existing)
        }
        // 无 Logo 时保持文字内容，由 ImageWatermarkPicker 引导导入
    }

    func setImageWatermark(_ watermark: ImageWatermark) {
        lastImageWatermark = watermark
        config.content = .image(watermark)
    }

    /// 移除 Logo（回到文字水印；同时清空缓存的图片水印）。
    func clearImageWatermark() {
        lastImageWatermark = nil
        config.content = .text(.standard(text: "水印工坊"))
    }

    var imageWatermark: ImageWatermark? {
        if case .image(let watermark) = config.content { return watermark }
        return lastImageWatermark
    }

    // MARK: - 模板

    func refreshTemplates() {
        templates = templateStore.all()
    }

    func saveTemplate(named name: String) throws {
        let template = WatermarkTemplate(
            id: UUID(),
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            config: config,
            createdAt: Date()
        )
        _ = try templateStore.save(template)
        refreshTemplates()
    }

    func deleteTemplate(id: UUID) throws {
        try templateStore.delete(id: id)
        refreshTemplates()
    }

    func applyTemplate(_ template: WatermarkTemplate) {
        config = template.config
        if case .image(let watermark) = template.config.content {
            lastImageWatermark = watermark
        }
        toast = ToastMessage(text: "已应用模板「\(template.name)」")
    }

    /// 应用从「文件」导入的 JSON 参数（含图片水印时同步缓存 Logo）。
    func applyImportedConfig(_ imported: WatermarkConfig) {
        config = imported
        if case .image(let watermark) = imported.content {
            lastImageWatermark = watermark
        }
    }

    // MARK: - 批量

    /// 全选素材的预估（确认框与任务页顶部共用同一函数）。
    func estimateForSelection() -> BatchEstimate {
        BatchEstimator.estimate(assets: selectedAssets, policy: policy)
    }

    /// 过滤「已加水印」素材（文件名 + 像素尺寸 + 修改时间判定，豁免开关关闭时原样返回）。
    func tasksExcludingWatermarked() -> (tasks: [LibraryAsset], skipped: Int) {
        let selected = selectedAssets
        guard settings.skipWatermarked, !selected.isEmpty else { return (selected, 0) }

        var index: [String: [LibraryAsset]] = [:]
        for asset in assets {
            guard let key = Self.watermarkKey(for: asset) else { continue }
            index[key, default: []].append(asset)
        }

        var kept: [LibraryAsset] = []
        var skipped = 0
        for asset in selected {
            guard let key = Self.watermarkKey(for: asset) else {
                kept.append(asset)   // 无文件名无法判定 → 不跳过（宁可重复，不可漏处理）
                continue
            }
            let sourceDate = asset.creationDate ?? .distantPast
            let hasNewerCopy = (index[key] ?? []).contains { other in
                other.assetIdentifier != asset.assetIdentifier
                    && (other.creationDate ?? .distantPast).timeIntervalSince(sourceDate) > 1
            }
            if hasNewerCopy { skipped += 1 } else { kept.append(asset) }
        }
        return (kept, skipped)
    }

    private static func watermarkKey(for asset: LibraryAsset) -> String? {
        guard let filename = asset.originalFilename, !filename.isEmpty else { return nil }
        return "\(filename)|\(Int(asset.pixelSize.width))x\(Int(asset.pixelSize.height))"
    }

    /// 启动批量（调用前已由 UI 完成二次确认 / RAW 告知）。
    /// - Parameters:
    ///   - rawConsent: 用户是否已确认「RAW 将转 HEIC」
    ///   - excludingRaw: 用户选择「从本批移除 RAW 文件」
    func startBatch(rawConsent: Bool, excludingRaw: Bool = false) {
        let prepared = tasksExcludingWatermarked()
        var tasks = prepared.tasks
        if excludingRaw {
            tasks = tasks.filter { $0.kind != .raw }
        }
        guard !tasks.isEmpty else {
            toast = ToastMessage(
                text: prepared.skipped > 0
                    ? "选中素材均已有加水印副本，已按「跳过已加水印」设置全部跳过"
                    : "没有可处理的素材"
            )
            return
        }
        if prepared.skipped > 0 {
            toast = ToastMessage(text: "已跳过 \(prepared.skipped) 个已加水印素材")
        }

        batch.start(
            tasks: tasks,
            config: config,
            rawConsent: rawConsent,
            policy: policy,
            albumName: settings.autoAlbum ? AlbumWriter.defaultAlbumName : nil,
            library: library,
            compositor: compositor
        )

        if settings.notifyOnFinish {
            Task { await NotificationManager.shared.requestAuthorizationIfNeeded() }
        }

        // 后台续跑：落盘待办 + 申请 BGProcessingTask 时间片（模拟器提交失败不影响前台）
        BGTaskCoordinator.shared.submit(
            assetIdentifiers: tasks.map(\.assetIdentifier),
            config: config,
            rawConsent: rawConsent,
            tier: policy.tier
        )

        selectedTab = .batch
    }

    // MARK: - 策略与设置

    func updatePolicy(_ newValue: ProcessingPolicy) {
        policy = newValue
        ProcessingPolicy.current = newValue
    }

    func updateSettings(_ mutate: (inout AppSettings) -> Void) {
        var copy = settings
        mutate(&copy)
        settings = copy
        AppSettingsStore.save(copy)
    }

    // MARK: - 日志

    /// 日志文本（设置页「导出日志」）：设备/策略/设置/最近批次/失败明细。
    func logText() -> String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        var lines: [String] = []
        lines.append("水印工坊 BatchMark 日志")
        lines.append("导出时间：\(BatchController.dateText(Date()))")
        lines.append("App 版本：\(version) (\(build))")
        lines.append("设备：\(UIDevice.current.model) / \(UIDevice.current.systemName) \(UIDevice.current.systemVersion)")
        lines.append("物理内存：\(Format.bytes(Int(ProcessInfo.processInfo.physicalMemory)))")
        lines.append("")
        lines.append("[处理策略]")
        lines.append("档位：\(policy.modeTitle)")
        lines.append("视频码率系数：\(ProcessingPolicy.format(policy.videoBitrateCoefficient))")
        lines.append("JPEG/HEIC 质量：\(ProcessingPolicy.format(policy.jpegCompressionQuality))")
        lines.append("并发：照片 \(policy.photoConcurrency) / 视频 \(policy.videoConcurrency)")
        lines.append("输出 PNG 无损：\(policy.outputLosslessPNG ? "开" : "关")")
        lines.append("")
        lines.append("[设置]")
        lines.append("跳过已加水印：\(settings.skipWatermarked ? "开" : "关")（\(ProcessingPolicy.skipDetectionDimensions)）")
        lines.append("归入「已加水印」相簿：\(settings.autoAlbum ? "开" : "关")")
        lines.append("完成通知：\(settings.notifyOnFinish ? "开" : "关")")
        lines.append("")
        lines.append("[最近批次]（最多 10 条）")
        for record in history.prefix(10) {
            lines.append("\(BatchController.dateText(record.startedAt))  共 \(record.assetCount)  " +
                         "\(record.countSummary)  耗时 \(Format.durationText(record.duration))")
        }
        if let latest = history.first {
            let failures = latest.items.filter { $0.status == .failed }
            if !failures.isEmpty {
                lines.append("")
                lines.append("[最近批次失败明细]")
                for item in failures {
                    lines.append("\(item.filename)\t\(item.stageText ?? "-")\t\(item.errorText ?? "-")")
                }
            }
        }
        // 块B 批处理日志（Documents/Logs/*.log）：附最近一份的前 80 行，便于排查
        if let logURL = BatchLogStore.shared.latestLogFile(),
           let content = try? String(contentsOf: logURL, encoding: .utf8) {
            let head = content.split(separator: "\n").prefix(80)
            lines.append("")
            lines.append("[块B 批处理日志（\(logURL.lastPathComponent)，前 80 行）]")
            lines.append(contentsOf: head.map(String.init))
        }
        lines.append("")
        lines.append("（本 App 纯本地运行，日志不含任何账号、位置或网络信息。）")
        return lines.joined(separator: "\n")
    }

    // MARK: - 相册跳转

    func openPhotosApp() {
        PhotoAppLink.openPhotosApp()
    }
}
