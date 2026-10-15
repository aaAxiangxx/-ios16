//
//  ZoneEntity.swift
//  Orange Cloud
//
//  Zone 的 App Intents 实体：数据来自本地缓存（ZoneCache），Siri/快捷指令可离线查询。
//

import Foundation
import AppIntents

nonisolated struct ZoneEntity: AppEntity, Identifiable {

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "域名"
    static let defaultQuery = ZoneEntityQuery()

    let id:       String
    let name:     String
    let status:   String
    let planName: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: "\(status) · \(planName)"
        )
    }

    @MainActor
    init(from cached: CachedZone) {
        self.id       = cached.id
        self.name     = cached.name
        self.status   = cached.status
        self.planName = cached.planName
    }
}

nonisolated struct ZoneEntityQuery: EntityQuery {

    // 读缓存走 `ZoneCache` 的快照出口。原先这里用 SwiftData 的
    // `ModelContext` + `SafeCache.fetch` 兜 CoreData 的 NSException（系统在冷启动
    // 就可能来查实体，异常按无缓存处理）。换成 JSON 缓存后失败模式退化为普通 Swift
    // 错误，快照读不到就返回空数组——同样「绝不让 Intents 查询崩掉 App」，且不再需要垫片。

    func entities(for identifiers: [ZoneEntity.ID]) async throws -> [ZoneEntity] {
        await MainActor.run {
            // 系统可能只带了 id 而没有账号上下文，故按 id 全表过滤而非按账号取。
            let all = ZoneCache.snapshotAll()
            return all
                .filter { identifiers.contains($0.id) }
                .map(ZoneEntity.init(from:))
        }
    }

    func suggestedEntities() async throws -> [ZoneEntity] {
        await MainActor.run {
            ZoneCache.snapshotAll()
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                .map(ZoneEntity.init(from:))
        }
    }
}
