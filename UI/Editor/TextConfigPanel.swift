//
//  TextConfigPanel.swift
//  WatermarkBatch（水印工坊 BatchMark）
//
//  块C · 文字水印面板（PRD F-04 八参数：内容 / 字体 / 字号 / 颜色 / 描边 / 阴影 / 不透明度 / 字间距）
//  所有参数直改 WatermarkTextConfig（块A 值类型），字号与描边/阴影单位均为 pt，
//  pt→px 由 WatermarkCompositor.pixelsPerPoint(for:) 统一换算——UI 不自造第二套基准。
//

import SwiftUI
import UIKit

struct TextConfigPanel: View {

    @Binding var config: WatermarkTextConfig

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {

            // 内容
            VStack(alignment: .leading, spacing: 6) {
                Text("水印文字")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("输入水印文字（支持多行）", text: $config.text, axis: .vertical)
                    .lineLimit(1...3)
                    .textFieldStyle(.plain)
                    .padding(9)
                    .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            // 字体
            HStack {
                Text("字体")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Menu {
                    ForEach(Self.availableFonts, id: \.postScriptName) { font in
                        Button {
                            config.fontName = font.postScriptName
                        } label: {
                            if config.fontName == font.postScriptName {
                                Label(font.displayName, systemImage: "checkmark")
                            } else {
                                Text(font.displayName)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(Self.displayName(for: config.fontName))
                            .font(.subheadline)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 10))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }

            // 字号
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("字号")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "%.0f pt", config.fontSizePt))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(value: $config.fontSizePt, in: 8...200, step: 1)
            }

            // 颜色
            HStack {
                ColorPicker("字体颜色", selection: colorBinding(for: $config.colorHex), supportsOpacity: true)
                    .font(.subheadline)
                Spacer()
                Text(config.colorHex.uppercased())
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }

            Divider()

            // 描边
            VStack(alignment: .leading, spacing: 8) {
                Toggle("描边", isOn: $config.strokeEnabled)
                    .font(.subheadline)
                if config.strokeEnabled {
                    HStack {
                        ColorPicker("描边颜色", selection: colorBinding(for: $config.strokeColorHex), supportsOpacity: true)
                            .font(.subheadline)
                        Spacer()
                        Text(String(format: "%.1f pt", config.strokeWidthPt))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $config.strokeWidthPt, in: 0...10, step: 0.5)
                }
            }

            // 阴影
            VStack(alignment: .leading, spacing: 8) {
                Toggle("阴影", isOn: $config.shadowEnabled)
                    .font(.subheadline)
                if config.shadowEnabled {
                    HStack {
                        ColorPicker("阴影颜色", selection: colorBinding(for: $config.shadowColorHex), supportsOpacity: true)
                            .font(.subheadline)
                        Spacer()
                        Text(String(format: "模糊 %.0f pt", config.shadowBlurRadiusPt))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $config.shadowBlurRadiusPt, in: 0...30, step: 1)

                    HStack(spacing: 12) {
                        shadowOffsetField(title: "X", keyPath: \.width)
                        shadowOffsetField(title: "Y", keyPath: \.height)
                    }
                }
            }

            Divider()

            // 不透明度
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("不透明度")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(Format.percent(config.opacity))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(value: $config.opacity, in: 0...1, step: 0.01)
            }

            // 字间距
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("字间距")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "%+.1f pt", config.letterSpacingPt))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(value: $config.letterSpacingPt, in: -5...20, step: 0.5)
            }
        }
    }

    // MARK: 组件

    private func shadowOffsetField(title: String, keyPath: WritableKeyPath<CGSize, CGFloat>) -> some View {
        HStack(spacing: 6) {
            Text("偏移 \(title)")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("0", value: Binding(
                get: { Double(config.shadowOffsetPt[keyPath: keyPath]) },
                set: { config.shadowOffsetPt[keyPath: keyPath] = CGFloat($0) }
            ), format: .number.precision(.fractionLength(0)))
            .textFieldStyle(.plain)
            .keyboardType(.numbersAndPunctuation)
            .multilineTextAlignment(.center)
            .font(.subheadline.monospacedDigit())
            .frame(width: 54, height: 28)
            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            Text("pt")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func colorBinding(for hex: Binding<String>) -> Binding<Color> {
        Binding(
            get: { Color(hex: hex.wrappedValue) ?? .white },
            set: { hex.wrappedValue = $0.hexRGBA }
        )
    }

    // MARK: 字体清单（运行期过滤系统实际可用项，全部为系统内置，无第三方字体）

    struct FontOption {
        let postScriptName: String
        let displayName: String
    }

    static let fontCandidates: [FontOption] = [
        .init(postScriptName: "PingFangSC-Regular", displayName: "苹方 常规"),
        .init(postScriptName: "PingFangSC-Medium", displayName: "苹方 中黑"),
        .init(postScriptName: "PingFangSC-Semibold", displayName: "苹方 半粗（默认）"),
        .init(postScriptName: "HelveticaNeue", displayName: "Helvetica Neue"),
        .init(postScriptName: "HelveticaNeue-Bold", displayName: "Helvetica Neue 粗体"),
        .init(postScriptName: "AvenirNext-Regular", displayName: "Avenir Next"),
        .init(postScriptName: "AvenirNext-Bold", displayName: "Avenir Next 粗体"),
        .init(postScriptName: "AvenirNextCondensed-Heavy", displayName: "Avenir Next 压缩黑"),
        .init(postScriptName: "Futura-Medium", displayName: "Futura"),
        .init(postScriptName: "DINAlternate-Bold", displayName: "DIN Alternate 粗体"),
        .init(postScriptName: "Georgia", displayName: "Georgia"),
        .init(postScriptName: "TimesNewRomanPSMT", displayName: "Times New Roman"),
        .init(postScriptName: "CourierNewPSMT", displayName: "Courier New"),
        .init(postScriptName: "Menlo-Regular", displayName: "Menlo"),
        .init(postScriptName: "MarkerFelt-Wide", displayName: "Marker Felt"),
        .init(postScriptName: "ChalkboardSE-Bold", displayName: "Chalkboard SE"),
        .init(postScriptName: "Copperplate", displayName: "Copperplate"),
        .init(postScriptName: "SnellRoundhand-Bold", displayName: "Snell Roundhand"),
    ]

    static var availableFonts: [FontOption] {
        fontCandidates.filter { UIFont(name: $0.postScriptName, size: 12) != nil }
    }

    static func displayName(for postScriptName: String) -> String {
        if let hit = fontCandidates.first(where: { $0.postScriptName == postScriptName }) {
            return hit.displayName
        }
        return postScriptName
    }
}
