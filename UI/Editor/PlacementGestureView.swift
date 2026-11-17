//
//  PlacementGestureView.swift
//  WatermarkBatch（水印工坊 BatchMark）
//
//  块C · 画布手势层（PRD F-06/F-08）
//  - 单指拖拽（跟手）、双指捏合缩放、双指旋转（0.1° 精度回显由数值面板负责）；
//  - 九宫格参考线（可选）+ 安全区吸附提示（阈值与合成器同一 config.safeMarginNormalized）；
//  - 所有结果写回 WatermarkPlacement 的归一化坐标（相对输出像素），
//    pt↔px 一律由 WatermarkCompositor.pixelsPerPoint / canvasReferenceWidthPoints 换算基准决定，
//    本层只用「显示矩形」做比例换算，不新建任何像素基准。
//

import SwiftUI

struct PlacementGestureView: View {

    /// 预览底图像素尺寸（仅用于 aspect-fit 计算，不代替原图尺寸做合成）。
    let imagePixelSize: CGSize
    @Binding var placement: WatermarkPlacement
    /// 安全区吸附阈值（与 WatermarkConfig.safeMarginNormalized 同源）。
    var safeMarginNormalized: CGFloat = 0.03

    @State private var guideVisible = false
    @State private var dragOrigin: CGPoint?
    @State private var pinchOrigin: CGFloat?
    @State private var rotateOrigin: CGFloat?
    @State private var snapActive = false
    @State private var hintTask: Task<Void, Never>?

    var body: some View {
        GeometryReader { proxy in
            let rect = fittedRect(imageSize: imagePixelSize,
                                  in: CGSize(width: proxy.size.width, height: proxy.size.height))
            ZStack {
                Color.clear
                    .contentShape(Rectangle())

                if guideVisible {
                    gridLines(in: rect)
                }

                if snapActive {
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
                        .frame(width: rect.width, height: rect.height)
                        .allowsHitTesting(false)
                }

                VStack {
                    Spacer()
                    Text(snapActive ? "已进入安全区，导出时自动吸附留白（\(Int(safeMarginNormalized * 100))%）"
                                    : "拖拽移动 · 双指缩放 / 旋转 · 双指点按显示参考线")
                        .font(.caption2)
                        .foregroundStyle(snapActive ? Color.accentColor : .white.opacity(0.9))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(.black.opacity(0.55), in: Capsule())
                        .padding(.bottom, 10)
                        .animation(.easeInOut(duration: 0.15), value: snapActive)
                }
                .allowsHitTesting(false)
            }
            .gesture(dragGesture(in: rect))
            .simultaneousGesture(magnifyGesture)
            .simultaneousGesture(rotateGesture)
            .simultaneousGesture(
                SpatialTapGesture(count: 2)
                    .onEnded { _ in guideVisible.toggle() }
            )
        }
    }

    // MARK: - 手势

    private func dragGesture(in rect: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                guard rect.width > 0, rect.height > 0 else { return }
                if dragOrigin == nil {
                    dragOrigin = CGPoint(x: placement.centerXNormalized, y: placement.centerYNormalized)
                }
                guard let origin = dragOrigin else { return }
                let dx = value.translation.width / rect.width
                let dy = value.translation.height / rect.height
                let raw = CGPoint(
                    x: min(max(origin.x + dx, 0), 1),
                    y: min(max(origin.y + dy, 0), 1)
                )
                let snapped = Self.snap(raw, margin: safeMarginNormalized)
                placement.centerXNormalized = snapped.point.x
                placement.centerYNormalized = snapped.point.y
                if snapped.didSnap != snapActive {
                    snapActive = snapped.didSnap
                }
            }
            .onEnded { _ in
                dragOrigin = nil
                scheduleHintDismiss()
            }
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture(minimumScaleDelta: 0.01)
            .onChanged { value in
                if pinchOrigin == nil { pinchOrigin = placement.scaleNormalized }
                guard let origin = pinchOrigin else { return }
                // 缩放范围与 PRD 5.1 一致：10% ~ 500%（按 scaleNormalized 计 0.02...2.0 更宽松，避免死区）
                placement.scaleNormalized = min(max(origin * value.magnification, 0.02), 2.0)
            }
            .onEnded { _ in pinchOrigin = nil }
    }

    private var rotateGesture: some Gesture {
        RotateGesture(minimumAngleDelta: .degrees(0.2))
            .onChanged { value in
                if rotateOrigin == nil { rotateOrigin = placement.rotationDegrees }
                guard let origin = rotateOrigin else { return }
                placement.rotationDegrees = Self.normalizeDegrees(origin + value.rotation.degrees)
            }
            .onEnded { _ in rotateOrigin = nil }
    }

    // MARK: - 参考线

    private func gridLines(in rect: CGRect) -> some View {
        Path { path in
            for index in 1...2 {
                let x = rect.minX + rect.width * CGFloat(index) / 3
                path.move(to: CGPoint(x: x, y: rect.minY))
                path.addLine(to: CGPoint(x: x, y: rect.maxY))
                let y = rect.minY + rect.height * CGFloat(index) / 3
                path.move(to: CGPoint(x: rect.minX, y: y))
                path.addLine(to: CGPoint(x: rect.maxX, y: y))
            }
        }
        .stroke(.white.opacity(0.35), style: StrokeStyle(lineWidth: 0.5, dash: [4, 4]))
        .allowsHitTesting(false)
    }

    // MARK: - 计算

    /// 中心点进入安全区边带 → 吸附到阈值边界（提示级吸附；合成器会按水印实际外接框再精确吸附一次）。
    static func snap(_ point: CGPoint, margin: CGFloat) -> (point: CGPoint, didSnap: Bool) {
        guard margin > 0, margin < 0.5 else { return (point, false) }
        var result = point
        var didSnap = false
        if point.x < margin {
            result.x = margin; didSnap = true
        } else if point.x > 1 - margin {
            result.x = 1 - margin; didSnap = true
        }
        if point.y < margin {
            result.y = margin; didSnap = true
        } else if point.y > 1 - margin {
            result.y = 1 - margin; didSnap = true
        }
        return (result, didSnap)
    }

    /// 归一化到 (-180, 180]，避免数值面板出现 720° 之类无意义视角。
    static func normalizeDegrees(_ degrees: CGFloat) -> CGFloat {
        var value = degrees.truncatingRemainder(dividingBy: 360)
        if value > 180 { value -= 360 }
        if value <= -180 { value += 360 }
        return (value * 10).rounded() / 10
    }

    private func scheduleHintDismiss() {
        hintTask?.cancel()
        hintTask = Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) { snapActive = false }
        }
    }
}
