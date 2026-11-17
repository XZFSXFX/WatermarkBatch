//
//  WatermarkTemplateStore.swift
//  WatermarkBatch（水印工坊 BatchMark）
//
//  块A · 水印模板本地持久化（PRD F-09）
//  存储：Documents 目录 JSON（随 iCloud 备份，§一 持久化选型）；数据量极小，不引入数据库。
//  线程模型：@unchecked Sendable + NSLock 保护（模板读改写均在锁内完成，持久化为原子写）。
//

import Foundation

/// 水印模板仓库：内存快照 + Documents JSON 原子落盘。
/// 支持增（新建）、改（按 id upsert）、删（按 id）、查（全量/按 id）。
final class WatermarkTemplateStore: @unchecked Sendable {

    private let fileURL: URL
    private let lock = NSLock()
    private var templates: [WatermarkTemplate]
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    // MARK: - 生命周期

    /// - Parameters:
    ///   - directory: 存储目录。默认 Documents（测试可注入临时目录）。
    ///     文件损坏时不致命：以空库启动并在下次写入时原子替换，避免阻塞核心流程。
    init(directory: URL? = nil) {
        let dir = directory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        fileURL = dir.appendingPathComponent("WatermarkTemplates.json", isDirectory: false)
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: fileURL),
           let loaded = try? decoder.decode([WatermarkTemplate].self, from: data) {
            templates = loaded
        } else {
            templates = []
        }
    }

    // MARK: - 查询

    /// 全部模板，按创建时间倒序（最新的排在前面）。
    func all() -> [WatermarkTemplate] {
        lock.lock(); defer { lock.unlock() }
        return templates.sorted { $0.createdAt > $1.createdAt }
    }

    /// 按 id 查询。
    func template(id: UUID) -> WatermarkTemplate? {
        lock.lock(); defer { lock.unlock() }
        return templates.first { $0.id == id }
    }

    // MARK: - 写操作（内存修改 + 原子落盘，二选一不出现半写状态）

    /// 新建或按 id 更新模板（upsert）。落盘失败抛 `WatermarkError.writeFailed`，内存保持修改前状态。
    @discardableResult
    func save(_ template: WatermarkTemplate) throws -> WatermarkTemplate {
        lock.lock()
        var next = templates
        if let idx = next.firstIndex(where: { $0.id == template.id }) {
            next[idx] = template
        } else {
            next.append(template)
        }
        do {
            try persist(next)
        } catch {
            lock.unlock()
            throw WatermarkError.writeFailed("模板保存失败：\(error.localizedDescription)")
        }
        templates = next
        lock.unlock()
        return template
    }

    /// 按 id 删除模板；id 不存在时静默成功（幂等）。
    func delete(id: UUID) throws {
        lock.lock()
        let next = templates.filter { $0.id != id }
        guard next.count != templates.count else {
            lock.unlock()
            return
        }
        do {
            try persist(next)
        } catch {
            lock.unlock()
            throw WatermarkError.writeFailed("模板删除失败：\(error.localizedDescription)")
        }
        templates = next
        lock.unlock()
    }

    // MARK: - 私有

    /// 原子写盘：`.atomic` 保证中断不产生半写文件；写成功后才替换内存快照。
    private func persist(_ next: [WatermarkTemplate]) throws {
        let data = try encoder.encode(next)
        try data.write(to: fileURL, options: .atomic)
    }
}
