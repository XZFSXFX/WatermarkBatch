//
//  AssetCachingManager.swift
//  WatermarkBatch（水印工坊 BatchMark）
//
//  块A · 列表预缓存与缩略图（PRD F-03）
//  红线：缩略图【仅】用于相册列表 UI 滚动与预览基图（预览基图允许 ≤屏幕 2 倍像素降采样，
//  §六.5）；导出链路一律使用原图数据，严禁用缩略图替代原图（F-02：不静默降级）。
//

import CoreGraphics
import Foundation
import Photos

final class AssetCachingManager: @unchecked Sendable {

    /// NSCache 需要类类型装 CGImage（CGImage 不可作泛型键值）；@unchecked Sendable：
    /// CGImage 不可变，跨线程读取安全。
    final class ThumbnailBox: @unchecked Sendable {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    private let cachingManager = PHCachingImageManager()
    private let lock = NSLock()
    private var cachingIdentifiers: Set<String> = []
    private let thumbnailCache = NSCache<NSString, ThumbnailBox>()

    init() {
        cachingManager.allowsCachingHighQualityImages = true
        thumbnailCache.countLimit = 600   // 列表规模上限（200 素材 × 3 种 cell 复用尺寸）
    }

    // MARK: - 预缓存

    /// 为一批素材启动 PHCachingImageManager 预缓存（切换批次时自动停掉上一批）。
    /// targetSize 为像素单位（PHCachingImageManager 契约）；由 PhotoLibraryService 原样透传。
    func startCaching(assetIdentifiers: [String], targetSize: CGSize) {
        let previous = swapCachingSet(assetIdentifiers)
        if !previous.isEmpty {
            let old = Self.phAssets(for: Array(previous))
            if !old.isEmpty {
                cachingManager.stopCachingImages(for: old, targetSize: targetSize,
                                                 contentMode: .aspectFill, options: nil)
            }
        }
        let assets = Self.phAssets(for: assetIdentifiers)
        guard !assets.isEmpty else { return }
        cachingManager.startCachingImages(for: assets, targetSize: targetSize,
                                          contentMode: .aspectFill, options: nil)
    }

    /// 停止全部预缓存并清空登记表。
    func stopCaching() {
        let current = swapCachingSet([])
        _ = current
        cachingManager.stopCachingImagesForAllAssets()
    }

    private func swapCachingSet(_ identifiers: [String]) -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        let previous = cachingIdentifiers
        cachingIdentifiers = Set(identifiers)
        return previous
    }

    // MARK: - 缩略图（仅 UI 列表/预览基图使用）

    /// 取缩略图：NSCache 命中优先；未命中走 PHImageManager（缩略图允许走网络，
    /// 因为只用于 UI 显示——导出链路绝不调用本方法）。
    /// deliveryMode = .highQualityFormat 保证回调恰好一次（continuation 单次恢复）。
    func thumbnail(for assetIdentifier: String, targetSize: CGSize) async -> CGImage? {
        let key = "\(assetIdentifier)#\(Int(targetSize.width))x\(Int(targetSize.height))"
        if let hit = thumbnailCache.object(forKey: key as NSString) {
            return hit.image
        }
        guard let phAsset = Self.phAssets(for: [assetIdentifier]).first else { return nil }
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isSynchronous = false
        options.isNetworkAccessAllowed = true   // 仅为显示缩略图联网，不违反纯本地原则（原图数据仍本地处理）
        let image: CGImage? = await withCheckedContinuation { continuation in
            let phAsset = phAsset
            cachingManager.requestImage(
                for: phAsset,
                targetSize: targetSize,
                contentMode: .aspectFill,
                options: options
            ) { image, _ in
                continuation.resume(returning: image?.cgImage)
            }
        }
        if let image {
            thumbnailCache.setObject(ThumbnailBox(image), forKey: key as NSString)
        }
        return image
    }

    // MARK: - 私有

    private static func phAssets(for identifiers: [String]) -> [PHAsset] {
        guard !identifiers.isEmpty else { return [] }
        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        var result: [PHAsset] = []
        result.reserveCapacity(fetch.count)
        fetch.enumerateObjects { asset, _, _ in
            result.append(asset)
        }
        return result
    }
}
