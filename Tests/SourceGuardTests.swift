//
//  SourceGuardTests.swift
//  WatermarkBatchTests（水印工坊 BatchMark）
//
//  源码守卫：把「导出链路禁止缩略图解码」从口头约定变成会红的断言。
//
//  为什么是源码扫描而不是行为测试：这个约束的破坏方式是「有人顺手多传一个 options 键」，
//  行为测试只能在特定素材上碰巧暴露（缩略图 API 在 1:1 时可能返回原尺寸，测试会误绿），
//  源码扫描则在任何素材、任何设备上都能确定性地拦住。
//
//  注意：三个处理器的头部注释里写了禁用符号本身（作为文档），所以扫描前必须剥注释，
//  否则守卫会被自己的注释判失败。剥注释后为空也判失败，防止剥离逻辑失效导致假绿。
//

import XCTest

final class SourceGuardTests: XCTestCase {

    // MARK: - 守卫规则

    /// 导出链路禁止出现的符号（缩略图解码 / 尺寸上限）。
    private static let forbiddenTokens = [
        "ThumbnailMaxPixelSize",
        "CreateThumbnailAtIndex"
    ]

    /// 走导出链路的处理器源码（块B）。
    private static let exportPathFiles = [
        "Processing/PhotoProcessor.swift",
        "Processing/AnimatedImageProcessor.swift",
        "Processing/VideoProcessor.swift",
        "Processing/LivePhotoProcessor.swift",
        "Processing/VideoWriterConfig.swift",
        "Processing/EXIFPreserver.swift"
    ]

    /// Tests/ 的上一级 = 工程源码根。
    private var sourceRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // WatermarkBatch
    }

    private func sourceCode(_ relativePath: String) throws -> String {
        let url = sourceRoot.appendingPathComponent(relativePath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "源文件缺失：\(relativePath)")
        let raw = try String(contentsOf: url, encoding: .utf8)
        let code = Self.stripComments(raw)
        XCTAssertFalse(code.isEmpty, "剥注释后为空，守卫失效：\(relativePath)")
        return code
    }

    // MARK: - 1. 禁止缩略图 API

    func testExportPathNeverUsesThumbnailDecoding() throws {
        for relativePath in Self.exportPathFiles {
            let code = try sourceCode(relativePath)
            for token in Self.forbiddenTokens {
                XCTAssertFalse(
                    code.contains(token),
                    "\(relativePath) 出现禁用符号 \(token)：导出链路只允许全分辨率解码 CGImageSourceCreateImageAtIndex"
                )
            }
        }
    }

    // MARK: - 2. 动图必须全分辨率逐帧解码

    func testAnimatedProcessorDecodesFullResolutionFrames() throws {
        let code = try sourceCode("Processing/AnimatedImageProcessor.swift")
        XCTAssertTrue(code.contains("CGImageSourceCreateImageAtIndex"), "动图处理器必须用 CreateImageAtIndex 全分辨率解码")
        XCTAssertTrue(code.contains("kCGImageSourceShouldCacheImmediately"), "逐帧解码应即时取像素，避免流式读时被重复解码")
    }

    // MARK: - 3. GIF 延时必须逐帧写

    func testAnimatedProcessorWritesPerFrameDelay() throws {
        let code = try sourceCode("Processing/AnimatedImageProcessor.swift")
        XCTAssertTrue(code.contains("kCGImagePropertyGIFDelayTime"), "缺少逐帧延时键")
        XCTAssertTrue(code.contains("kCGImagePropertyGIFUnclampedDelayTime"), "缺少不夹取延时键（会被系统钳到 0.1s）")
        // AddImage 必须带每帧 properties，而不是只在 SetProperties 里设一次。
        XCTAssertTrue(code.contains("CGImageDestinationAddImage"), "缺少写帧调用")
        XCTAssertTrue(code.range(of: "CGImageDestinationAddImage\\([^)]*properties", options: .regularExpression) != nil
                      || code.range(of: "CGImageDestinationAddImage\\(dest,[^\\n]*props", options: .regularExpression) != nil,
                      "CGImageDestinationAddImage 必须逐帧传入 properties（延时不同的动图才不会掉帧）")
    }

    // MARK: - 4. 视频禁止预设导出、必须显式码率

    func testVideoProcessorUsesExplicitWriterSettings() throws {
        let code = try sourceCode("Processing/VideoProcessor.swift")
        for token in ["AVAssetExportPreset", "AVAssetExportSession"] {
            XCTAssertFalse(code.contains(token), "视频导出禁止使用 \(token)：参数不可控")
        }
        XCTAssertTrue(code.contains("AVVideoAverageBitRateKey"), "必须显式写平均码率")
        XCTAssertTrue(code.contains("shouldOptimizeForNetworkUse"), "必须显式关掉网络优化重排（保持 GOP 结构）")
    }

    // MARK: - 5. 不允许任何缩放路径

    func testExportPathHasNoResizeKeys() throws {
        let forbidden = ["kCGImageSourceThumbnailMaxPixelSize", "maximumSize", "scaleFactor"]
        for relativePath in Self.exportPathFiles {
            let code = try sourceCode(relativePath)
            for token in forbidden where token != "scaleFactor" {
                XCTAssertFalse(code.contains(token), "\(relativePath) 出现缩放键 \(token)")
            }
        }
    }

    // MARK: - 注释剥离

    /// 去掉 `/* ... */` 与 `// ...`，保留其余字符。注释里允许出现禁用符号（作为文档说明）。
    static func stripComments(_ source: String) -> String {
        var text = source
        text = text.replacingOccurrences(of: "/\\*[\\s\\S]*?\\*/", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "//[^\n]*", with: "", options: .regularExpression)
        return text
    }
}
