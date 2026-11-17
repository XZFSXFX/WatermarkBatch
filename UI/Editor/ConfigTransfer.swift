//
//  ConfigTransfer.swift
//  WatermarkBatch（水印工坊 BatchMark）
//
//  块C · 水印参数 JSON 导出/导入（交付物 B：Codable 完整往返）
//  信封里带 schemaVersion，便于未来兼容；WatermarkConfig 本身由块A 定义（含图片水印 Data，
//  JSONEncoder 默认 base64，透明 Logo 一并在内）。
//

import SwiftUI
import UniformTypeIdentifiers

/// 导出文件结构：版本号 + 导出时间 + 完整配置。
struct WatermarkConfigEnvelope: Codable, Sendable {
    var schemaVersion: Int = 1
    var app: String = "BatchMark"
    var exportedAt: Date
    var config: WatermarkConfig
}

enum WatermarkConfigCodec {

    static let currentSchemaVersion = 1

    static func encode(_ config: WatermarkConfig) throws -> Data {
        let envelope = WatermarkConfigEnvelope(exportedAt: Date(), config: config)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(envelope)
    }

    static func decode(_ data: Data) throws -> WatermarkConfig {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // 兼容两种输入：带信封的导出文件 / 裸 WatermarkConfig
        if let envelope = try? decoder.decode(WatermarkConfigEnvelope.self, from: data) {
            return envelope.config
        }
        return try decoder.decode(WatermarkConfig.self, from: data)
    }
}

/// FileDocument 包装：`fileExporter` 导出到「文件」App。
struct WatermarkConfigDocument: FileDocument {

    static var readableContentTypes: [UTType] { [.json] }

    var data: Data

    init(config: WatermarkConfig) throws {
        data = try WatermarkConfigCodec.encode(config)
    }

    init(configuration: ReadConfiguration) throws {
        guard let contents = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        data = contents
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
