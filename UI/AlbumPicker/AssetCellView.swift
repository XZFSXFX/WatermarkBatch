//
//  AssetCellView.swift
//  WatermarkBatch（水印工坊 BatchMark）
//
//  块C · 相册网格单元（PRD F-01/F-02/F-03）
//  类型角标（照片/Live/GIF/视频/RAW）+ 时长 + 选择态 + iCloud 下载/进度/失败重试。
//
//  缩略图仅用于列表显示（PhotoLibraryService.thumbnail → PHCachingImageManager + NSCache），
//  导出链路绝不使用缩略图（块A 红线）。
//

import SwiftUI

struct AssetCellView: View {

    let asset: LibraryAsset
    let isSelected: Bool
    let cloudState: CloudState
    let onTap: () -> Void
    let onCloudAction: () -> Void

    @Environment(AppModel.self) private var model
    @State private var thumbnail: CGImage?

    var body: some View {
        Button(action: onTap) {
            ZStack {
                thumbnailLayer
                gradientLayer
                typeBadge
                durationBadge
                cloudBadge
                selectionBadge
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 3)
            }
            .overlay(alignment: .center) {
                if isSelected {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.accentColor.opacity(0.18))
                }
            }
        }
        .buttonStyle(.plain)
        .task(id: asset.id) {
            model.probeCloudIfNeeded(asset)
            if thumbnail == nil {
                thumbnail = await model.library.thumbnail(
                    for: asset,
                    targetSize: CGSize(width: AppModel.thumbnailTargetPixels,
                                      height: AppModel.thumbnailTargetPixels)
                )
            }
        }
        .accessibilityLabel(accessibilityText)
    }

    // MARK: 图层

    @ViewBuilder
    private var thumbnailLayer: some View {
        if let thumbnail {
            Image(decorative: thumbnail, scale: 1)
                .resizable()
                .scaledToFill()
        } else {
            Rectangle()
                .fill(Color(.tertiarySystemFill))
                .overlay {
                    ProgressView()
                        .controlSize(.mini)
                }
        }
    }

    /// 底部渐变：保证时长/云朵角标在浅色照片上可读。
    private var gradientLayer: some View {
        VStack {
            Spacer()
            LinearGradient(
                colors: [.clear, .black.opacity(0.45)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 34)
        }
        .allowsHitTesting(false)
    }

    private var typeBadge: some View {
        VStack {
            HStack {
                Text(kindLabel)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.55), in: Capsule())
                Spacer()
            }
            .padding(5)
            Spacer()
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var durationBadge: some View {
        if let duration = asset.duration, duration > 0 {
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Text(Format.clock(duration))
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.55), in: Capsule())
                }
                .padding(5)
            }
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var cloudBadge: some View {
        switch cloudState {
        case .inCloud, .failed:
            VStack {
                Spacer()
                HStack {
                    Button(action: onCloudAction) {
                        Image(systemName: cloudState.isFailed ? "arrow.clockwise.icloud" : "icloud.and.arrow.down")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(cloudState.isFailed ? .orange : .white)
                            .padding(5)
                            .background(.black.opacity(0.55), in: Circle())
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
                .padding(5)
            }
        case .downloading(let fraction):
            VStack {
                Spacer()
                HStack {
                    ZStack {
                        Circle()
                            .stroke(.white.opacity(0.25), lineWidth: 2)
                        Circle()
                            .trim(from: 0, to: max(fraction, 0.02))
                            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        Text("\(Int(fraction * 100))")
                            .font(.system(size: 8, weight: .bold).monospacedDigit())
                            .foregroundStyle(.white)
                    }
                    .frame(width: 22, height: 22)
                    .padding(3)
                    .background(.black.opacity(0.55), in: Circle())
                    Spacer()
                }
                .padding(5)
            }
            .allowsHitTesting(false)
        case .probing, .local:
            EmptyView()
        }
    }

    private var selectionBadge: some View {
        VStack {
            HStack {
                Spacer()
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.accentColor : .white.opacity(0.85))
                    .background(
                        Circle()
                            .fill(isSelected ? Color.white : Color.black.opacity(0.35))
                            .frame(width: 17, height: 17)
                    )
                    .shadow(color: .black.opacity(0.3), radius: 2)
            }
            .padding(5)
            Spacer()
        }
        .allowsHitTesting(false)
    }

    // MARK: 文案

    private var kindLabel: String {
        switch asset.kind {
        case .photo: return "照片"
        case .livePhoto: return "LIVE"
        case .animated: return "GIF"
        case .video: return "视频"
        case .raw: return "RAW"
        }
    }

    private var accessibilityText: String {
        var text = "\(kindLabel)，\(Int(asset.pixelSize.width))×\(Int(asset.pixelSize.height))"
        if let date = asset.creationDate {
            text += "，\(BatchController.dateText(date))"
        }
        text += isSelected ? "，已选择" : "，未选择"
        if case .inCloud = cloudState { text += "，仅存于 iCloud" }
        return text
    }
}

extension CloudState {
    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}
