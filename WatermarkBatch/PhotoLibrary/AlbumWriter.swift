//
//  AlbumWriter.swift
//  WatermarkBatch（水印工坊 BatchMark）
//
//  块A ·「已加水印」相簿的幂等创建与归类（PRD F-24，§六.8）
//  用法约定（PhotoKit 生命周期要求）：
//  - `existingAlbum(named:)` 可在任意上下文调用（只读查询）；
//  - `upsertAlbum(named:)` / `add(_:to:)` 必须在 `PHPhotoLibrary.performChanges`
//    的 change block 内调用——由块B ExportService 在唯一一次 performChanges 中调用。
//

import Foundation
import Photos

final class AlbumWriter: @unchecked Sendable {

    /// 默认相簿名（PRD F-24：「已加水印」智能相簿归集）。
    static let defaultAlbumName = "已加水印"

    init() {}

    // MARK: - 幂等查找（只读，任意上下文）

    /// 按标题查找用户相簿；不存在返回 nil。
    func existingAlbum(named title: String) -> PHAssetCollection? {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "title == %@", title)
        let fetch = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: options)
        return fetch.firstObject
    }

    // MARK: - performChanges 内调用（写路径）

    /// 幂等 upsert：相簿已存在 → 返回已有相簿的 changeRequest（用于 addAssets）；
    /// 不存在 → 创建新相簿并返回其 changeRequest。
    /// ⚠️ 必须在 PHPhotoLibrary.performChanges 的 change block 内调用。
    func upsertAlbum(named title: String) -> PHAssetCollectionChangeRequest? {
        if let existing = existingAlbum(named: title) {
            return PHAssetCollectionChangeRequest(for: existing)
        }
        return PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: title)
    }

    /// 把新建资产的占位对象归入相簿。
    /// ⚠️ 必须在 PHPhotoLibrary.performChanges 的 change block 内调用；
    /// placeholders 来自 PHAssetCreationRequest 的 placeholderForCreatedAsset。
    func add(_ placeholders: [PHObjectPlaceholder], to request: PHAssetCollectionChangeRequest) {
        guard !placeholders.isEmpty else { return }
        request.addAssets(placeholders as NSArray)
    }
}
