//
//  NumericAdjustView.swift
//  WatermarkBatch（水印工坊 BatchMark）
//
//  块C · 位置与尺寸（PRD F-06/F-07/F-10）
//  - 九宫格快速对齐；
//  - X/Y 偏移（px，相对输出像素）、缩放（%）、旋转（°，0.1 步进）数值输入与 ± 微调；
//  - 非法输入红框提示并保留上次合法值（PRD TC-EX-009）；
//  - 平铺开关（默认关闭）+ 间距/倾角。
//

import SwiftUI

struct NumericAdjustView: View {

    @Binding var placement: WatermarkPlacement
    /// 输出像素尺寸（取预览素材的原始像素；仅用于 px ↔ 归一化的换算展示）。
    let outputPixelSize: CGSize

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            NineGridPicker(placement: $placement)

            Divider()

            NumericFieldRow(
                title: "X 偏移",
                unit: "px",
                value: Double(placement.centerXNormalized * max(outputPixelSize.width, 1)),
                range: 0...Double(max(outputPixelSize.width, 1)),
                step: 1,
                decimals: 0
            ) { newValue in
                placement.centerXNormalized = clampNormalized(newValue / Double(max(outputPixelSize.width, 1)))
            }

            NumericFieldRow(
                title: "Y 偏移",
                unit: "px",
                value: Double(placement.centerYNormalized * max(outputPixelSize.height, 1)),
                range: 0...Double(max(outputPixelSize.height, 1)),
                step: 1,
                decimals: 0
            ) { newValue in
                placement.centerYNormalized = clampNormalized(newValue / Double(max(outputPixelSize.height, 1)))
            }

            NumericFieldRow(
                title: "缩放",
                unit: "%",
                value: Double(placement.scaleNormalized * 100),
                range: 2...200,
                step: 1,
                decimals: 0
            ) { newValue in
                placement.scaleNormalized = min(max(CGFloat(newValue / 100), 0.02), 2.0)
            }

            NumericFieldRow(
                title: "旋转",
                unit: "°",
                value: Double(placement.rotationDegrees),
                range: -360...360,
                step: 0.1,
                decimals: 1
            ) { newValue in
                placement.rotationDegrees = PlacementGestureView.normalizeDegrees(CGFloat(newValue))
            }

            Text("X/Y 为水印中心相对输出像素的偏移；缩放 = 水印长边 / 输出短边。数值与画布手势双向同步，误差为 0。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func clampNormalized(_ value: Double) -> CGFloat {
        CGFloat(min(max(value, 0), 1))
    }
}

// MARK: - 九宫格

struct NineGridPicker: View {

    @Binding var placement: WatermarkPlacement

    /// 九宫格中心（等分三格的视觉中心，预留 15% 边距，避免贴边被安全区二次吸附）。
    private let fractions: [CGFloat] = [0.15, 0.5, 0.85]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("九宫格对齐")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { row in
                    HStack(spacing: 4) {
                        ForEach(0..<3, id: \.self) { column in
                            Button {
                                withAnimation(.easeOut(duration: 0.15)) {
                                    placement.centerXNormalized = fractions[column]
                                    placement.centerYNormalized = fractions[row]
                                }
                            } label: {
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(isActive(row: row, column: column)
                                          ? Color.accentColor.opacity(0.9)
                                          : Color(.tertiarySystemFill))
                                    .frame(height: 26)
                                    .overlay {
                                        Circle()
                                            .fill(isActive(row: row, column: column) ? .white : .secondary.opacity(0.6))
                                            .frame(width: 5, height: 5)
                                    }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("第 \(row + 1) 行第 \(column + 1) 列")
                        }
                    }
                }
            }
        }
    }

    private func isActive(row: Int, column: Int) -> Bool {
        abs(placement.centerXNormalized - fractions[column]) < 0.01
            && abs(placement.centerYNormalized - fractions[row]) < 0.01
    }
}

// MARK: - 数值输入行

/// 数值输入 + ± 步进。非法值 → 红框，值不更新（保留上次合法值），失焦时回显合法值。
struct NumericFieldRow: View {

    let title: String
    let unit: String
    let value: Double
    let range: ClosedRange<Double>
    let step: Double
    var decimals: Int = 1
    let onChange: (Double) -> Void

    @State private var text: String = ""
    @State private var isInvalid = false
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 58, alignment: .leading)

            stepButton(systemImage: "minus", delta: -step)

            TextField("", text: $text)
                .textFieldStyle(.plain)
                .keyboardType(.numbersAndPunctuation)
                .multilineTextAlignment(.center)
                .font(.subheadline.monospacedDigit())
                .frame(width: 70, height: 30)
                .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(isInvalid ? Color.red : Color.clear, lineWidth: 1.2)
                }
                .focused($isFocused)
                .onSubmit { commit(revertOnFailure: false) }
                .onChange(of: isFocused) { _, focused in
                    if focused {
                        text = formatted(value)
                        isInvalid = false
                    } else {
                        commit(revertOnFailure: true)
                    }
                }

            Text(unit)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 20, alignment: .leading)

            stepButton(systemImage: "plus", delta: step)
        }
        .onAppear { text = formatted(value) }
        .onChange(of: value) { _, newValue in
            guard !isFocused else { return }
            text = formatted(newValue)
            isInvalid = false
        }
    }

    private func stepButton(systemImage: String, delta: Double) -> some View {
        Button {
            apply(value + delta)
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .bold))
                .frame(width: 28, height: 28)
                .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func apply(_ newValue: Double) {
        let clamped = min(max(newValue, range.lowerBound), range.upperBound)
        let rounded = (clamped / step).rounded() * step
        onChange(rounded)
        text = formatted(rounded)
        isInvalid = false
    }

    private func commit(revertOnFailure: Bool) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let parsed = Double(trimmed), parsed.isFinite else {
            isInvalid = true
            if revertOnFailure { text = formatted(value) ; isInvalid = false }
            return
        }
        guard range.contains(parsed) else {
            isInvalid = true
            if revertOnFailure { text = formatted(value); isInvalid = false }
            return
        }
        isInvalid = false
        onChange(parsed)
        text = formatted(parsed)
    }

    private func formatted(_ newValue: Double) -> String {
        String(format: "%.\(decimals)f", newValue)
    }
}

// MARK: - 平铺

struct TilingPanel: View {

    @Binding var tiling: TilingConfig

    var body: some View {
        SectionCard(title: "平铺（防盗图，默认关闭）") {
            Toggle("开启平铺水印", isOn: $tiling.isEnabled)
                .tint(.accentColor)

            if tiling.isEnabled {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("间距").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text(String(format: "%.2f × 水印长边", tiling.spacingNormalized))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $tiling.spacingNormalized, in: 0.1...2.0)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("倾角").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text(String(format: "%.0f°", tiling.rotationDegrees))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $tiling.rotationDegrees, in: -90...90, step: 1)
                }

                Text("平铺时水印按网格重复，间距与倾角实时预览；导出与预览使用同一合成入口。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
