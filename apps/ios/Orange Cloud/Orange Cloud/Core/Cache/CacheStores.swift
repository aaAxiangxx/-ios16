//
//  CacheStores.swift
//  Orange Cloud
//
//  iOS 16 基线适配：三个 `ObservableObject` Store 取代了 SwiftData 的 `@Query`。
//
//  为什么是「按账号分区的显式 Store」而不是泛型单例：
//  `@Query(filter:sort:)` 提供了三件事——谓词过滤（accountId / zoneId）、排序、视图生命周期自动刷新。
//  泛型 `CacheStore<T>` 只能表达落盘，这三件必须由具体类型承担。
//  于是每个 Store 内部持有**当前账号**的过滤结果，`activate(accountId:)` 负责切换账号。
//
//  与 `@Query` 的行为差异（已在 COMPATIBILITY.md 记录）：
//  - `@Query` 在视图 `init` 里就带谓词，冷启动首帧即有数据；
//    Store 走 `.task { store.activate(...) }`，**首帧为空、随后一次发布**。
//    因此首屏会多一帧空列表再被缓存填上（父视图已有 `.id(selectedAccount)` 负责重建，语义一致）。
//  - `@Query` 是属性级粒度、Store 是整数组一次发布；列表页数据量小（单账号几十条），无实际差别。
//

import Foundation
import SwiftUI
import WidgetKit

// MARK: - Zone 缓存

/// 域名缓存。按当前账号过滤 + 按 name 排序，供列表页与 Dashboard 读取。
@MainActor
final class ZoneCache: ObservableObject {

    /// 当前账号的域名，已按 `name` 升序（对齐原 `#Predicate` + `sort: \.name`）。
    @Published private(set) var zones: [CachedZone] = []

    /// 全量落盘数据（含其它账号）。视图只读 `zones`，但切账号需要从这里取回对应条目。
    private var all: [CachedZone] = []

    /// 当前生效的账号。空串表示尚未激活。
    private(set) var accountId: String = ""

    static let shared = ZoneCache()

    /// 启动预热：把磁盘数据读进内存（不发布，视图尚未挂载）。
    nonisolated static func bootstrap() {
        let loaded = CacheStore.load(CachedZone.self, from: CacheStoreName.zones)
        shared.replaceAll(loaded)
    }

    /// 切账号：重新过滤 + 排序 + 一次发布。
    ///
    /// 视图侧在 `.task` 里调用；`accountId` 未变时直接返回，避免切 Tab 反复发布空 diff。
    func activate(accountId: String) {
        guard accountId != self.accountId else { return }
        self.accountId = accountId
        publish()
    }

    private func replaceAll(_ items: [CachedZone]) {
        all = items
    }

    private func publish() {
        zones = all
            .filter { $0.accountId == accountId }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - 写入

    /// Zone 列表 upsert（删掉远端已不存在的条目），并保留用户的 `pinned` / `dnsRecordCount`。
    ///
    /// 与原 SwiftData 版的关键差别：`update(from:)` 只更新远端字段，
    /// `pinned` 由这里从旧记录继承 —— 用户手动固定的域名不会被一次列表刷新重置。
    func upsert(_ incoming: [Zone], accountId: String) {
        var scoped = all.filter { $0.accountId == accountId }
        let oldByID = Dictionary(scoped.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let incomingIDs = Set(incoming.map(\.id))

        // 远端已删除的条目直接剔除；仅在当前账号范围内做，不波及其它账号的 pinned。
        scoped.removeAll { !incomingIDs.contains($0.id) }

        for zone in incoming {
            var cached: CachedZone
            if let old = oldByID[zone.id] {
                cached = old
                cached.update(from: zone)
            } else {
                cached = CachedZone(from: zone, accountId: accountId)
            }
            if let idx = scoped.firstIndex(where: { $0.id == cached.id }) {
                scoped[idx] = cached
            } else {
                scoped.append(cached)
            }
        }

        // 写回全量：先剔除该账号旧条目，再并入新集合，保持其它账号不动。
        all.removeAll { $0.accountId == accountId }
        all.append(contentsOf: scoped)

        if self.accountId == accountId { publish() }
        persist()
    }

    /// 切换固定状态（Dashboard 手动操作，写完立刻落盘）。
    func setPinned(_ pinned: Bool, zoneId: String) {
        mutate(zoneId: zoneId) { $0.pinned = pinned }
    }

    /// 回写 DNS 记录总数（Dashboard 轻量统计）。
    func setDNSRecordCount(_ count: Int, zoneId: String) {
        mutate(zoneId: zoneId) { $0.dnsRecordCount = count }
    }

    /// 回写代理暂停状态（域名设置页开关；Cloudflare 侧已改成功，只更新本地缓存）。
    func setPaused(_ paused: Bool, zoneId: String) {
        mutate(zoneId: zoneId) { $0.paused = paused }
    }

    /// 改字段的公共路径：只在改动确实落在**当前展示账号**内时才重新发布，
    /// 避免后台回写其它账号的数据时把当前列表白白重建一次。
    private func mutate(zoneId: String, _ change: (inout CachedZone) -> Void) {
        var didTouchCurrentAccount = false
        for idx in all.indices where all[idx].id == zoneId {
            change(&all[idx])
            if all[idx].accountId == accountId { didTouchCurrentAccount = true }
        }
        if didTouchCurrentAccount { publish() }
        persist()
    }

    /// 后台状态检测的批量回写（`AppNotifications.checkZoneStatusChanges` 用）。
    ///
    /// 只接受**已经比对出差异、需要落盘**的条目，调用方自行决定哪些变了；
    /// 这里按 id 覆盖全量数组，不动其它账号、不动未出现在 `refreshed` 里的条目。
    func applyBackgroundStatusUpdates(_ refreshed: [CachedZone]) {
        guard !refreshed.isEmpty else { return }
        let byID = Dictionary(refreshed.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var didTouchCurrentAccount = false
        for idx in all.indices {
            guard let new = byID[all[idx].id] else { continue }
            all[idx] = new
            if all[idx].accountId == accountId { didTouchCurrentAccount = true }
        }
        if didTouchCurrentAccount { publish() }
        persist()
    }

    /// 退出登录 / 切账号清理：删掉某账号的全部缓存条目。
    func removeAccount(_ accountId: String) {
        all.removeAll { $0.accountId == accountId }
        if self.accountId == accountId { zones = [] }
        persist()
    }

    private func persist() {
        CacheStore.save(all, to: CacheStoreName.zones)
    }

    // MARK: - 非隔离读取（后台刷新 / App Intents）

    /// 供 `BackgroundRefresh` / `ZoneEntityQuery` 等非主线程上下文使用。
    ///
    /// 这些调用点原先直接 `ModelContext(CacheContainer.shared)`，
    /// 换成 ObservableObject 后 `@Published` 属性只能在主线程读，故提供快照出口。
    nonisolated static func snapshot(accountId: String) -> [CachedZone] {
        MainActor.assumeIsolated {
            shared.all.filter { $0.accountId == accountId }
        }
    }

    /// 某账号缓存的最新写入时间（CachePolicy 判新鲜度用）。
    nonisolated static func latestUpdatedAt(accountId: String) -> Date? {
        snapshot(accountId: accountId).map(\.updatedAt).max()
    }

    /// 全量快照（不限账号）。给 App Intents 用：系统调 `entities(for:)` 时只给得出
    /// 一串 id、没有账号上下文，只能按 id 在全表里过滤。
    nonisolated static func snapshotAll() -> [CachedZone] {
        MainActor.assumeIsolated { shared.all }
    }

    /// 某账号缓存的域名（顺序不保证，供只需集合的场景）。
    nonisolated static func zoneIDs(accountId: String) -> Set<String> {
        Set(snapshot(accountId: accountId).map(\.id))
    }
}

// MARK: - Worker 缓存

/// Workers 脚本缓存。按当前账号过滤。
@MainActor
final class WorkerCache: ObservableObject {

    @Published private(set) var scripts: [CachedWorkerScript] = []

    private var all: [CachedWorkerScript] = []
    private(set) var accountId: String = ""

    static let shared = WorkerCache()

    nonisolated static func bootstrap() {
        shared.replaceAll(CacheStore.load(CachedWorkerScript.self, from: CacheStoreName.workers))
    }

    private func replaceAll(_ items: [CachedWorkerScript]) { all = items }

    func activate(accountId: String) {
        guard accountId != self.accountId else { return }
        self.accountId = accountId
        publish()
    }

    private func publish() {
        scripts = all.filter { $0.accountId == accountId }
    }

    func upsert(_ incoming: [WorkerScript], accountId: String) {
        var scoped = all.filter { $0.accountId == accountId }
        let oldByKey = Dictionary(scoped.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        let incomingKeys = Set(incoming.map { "\(accountId)/\($0.id)" })

        scoped.removeAll { !incomingKeys.contains($0.key) }

        for script in incoming {
            var cached: CachedWorkerScript
            if let old = oldByKey["\(accountId)/\(script.id)"] {
                cached = old
                cached.update(from: script)
            } else {
                cached = CachedWorkerScript(from: script, accountId: accountId)
            }
            if let idx = scoped.firstIndex(where: { $0.key == cached.key }) {
                scoped[idx] = cached
            } else {
                scoped.append(cached)
            }
        }

        all.removeAll { $0.accountId == accountId }
        all.append(contentsOf: scoped)

        if self.accountId == accountId { publish() }
        persist()
    }

    /// 删除单个脚本（删除成功后从缓存移除）。
    func remove(scriptId: String, accountId: String) {
        all.removeAll { $0.accountId == accountId && $0.id == scriptId }
        if self.accountId == accountId { publish() }
        persist()
    }

    func removeAccount(_ accountId: String) {
        all.removeAll { $0.accountId == accountId }
        if self.accountId == accountId { scripts = [] }
        persist()
    }

    private func persist() {
        CacheStore.save(all, to: CacheStoreName.workers)
    }

    nonisolated static func snapshot(accountId: String) -> [CachedWorkerScript] {
        MainActor.assumeIsolated {
            shared.all.filter { $0.accountId == accountId }
        }
    }

    nonisolated static func latestUpdatedAt(accountId: String) -> Date? {
        snapshot(accountId: accountId).map(\.updatedAt).max()
    }
}

// MARK: - DNS 缓存

/// DNS 记录缓存。按当前 **zoneId** 过滤（原 `@Query` 的谓词就是 zoneId，不是 accountId）。
@MainActor
final class DNSCache: ObservableObject {

    @Published private(set) var records: [CachedDNSRecord] = []

    private var all: [CachedDNSRecord] = []
    /// 当前生效的域名。空串表示尚未激活。
    private(set) var zoneId: String = ""

    static let shared = DNSCache()

    nonisolated static func bootstrap() {
        shared.replaceAll(CacheStore.load(CachedDNSRecord.self, from: CacheStoreName.dns))
    }

    private func replaceAll(_ items: [CachedDNSRecord]) { all = items }

    /// 切域名：重新过滤 + 一次发布。
    func activate(zoneId: String) {
        guard zoneId != self.zoneId else { return }
        self.zoneId = zoneId
        publish()
    }

    private func publish() {
        records = all.filter { $0.zoneId == zoneId }
    }

    /// 列表刷新：整份替换该域名的记录集合。
    func replaceAll(forZone zoneId: String, with incoming: [DNSRecord]) {
        var scoped = all.filter { $0.zoneId == zoneId }
        let oldByID = Dictionary(scoped.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // 远端已删除的记录剔除（只在本域名范围内，不波及其它域名）。
        let incomingIDs = Set(incoming.map(\.id))
        scoped.removeAll { !incomingIDs.contains($0.id) }

        for record in incoming {
            var cached: CachedDNSRecord
            if let old = oldByID[record.id] {
                cached = old
                cached.update(from: record, includesShadowMetadata: true)
            } else {
                cached = CachedDNSRecord(from: record, zoneId: zoneId)
            }
            if let idx = scoped.firstIndex(where: { $0.id == cached.id }) {
                scoped[idx] = cached
            } else {
                scoped.append(cached)
            }
        }

        all.removeAll { $0.zoneId == zoneId }
        all.append(contentsOf: scoped)

        if self.zoneId == zoneId { publish() }
        persist()
    }

    /// 单条增改（POST/PUT 响应不带遮蔽信息，保留已知值）。
    func upsert(_ record: DNSRecord, zoneId: String) {
        if let idx = all.firstIndex(where: { $0.id == record.id }) {
            all[idx].update(from: record)
        } else {
            all.append(CachedDNSRecord(from: record, zoneId: zoneId))
        }
        if self.zoneId == zoneId { publish() }
        persist()
    }

    /// 删除单条。
    func remove(recordId: String) {
        // 先记下被删条目所属域名：删除会改变 all 的内容，之后再判断就无从查起了。
        let ownerZone = all.first { $0.id == recordId }?.zoneId
        all.removeAll { $0.id == recordId }
        if ownerZone == zoneId { publish() }
        persist()
    }

    /// 删除整个域名的记录（域名被删 / 切走时）。
    func removeZone(_ zoneId: String) {
        all.removeAll { $0.zoneId == zoneId }
        if self.zoneId == zoneId { records = [] }
        persist()
    }

    private func persist() {
        CacheStore.save(all, to: CacheStoreName.dns)
    }

    nonisolated static func snapshot(zoneId: String) -> [CachedDNSRecord] {
        MainActor.assumeIsolated {
            shared.all.filter { $0.zoneId == zoneId }
        }
    }

    nonisolated static func latestUpdatedAt(zoneId: String) -> Date? {
        snapshot(zoneId: zoneId).map(\.updatedAt).max()
    }

    nonisolated static func recordCount(zoneId: String) -> Int {
        snapshot(zoneId: zoneId).count
    }

    /// 跨多个域名统计记录数（Dashboard 首屏资产统计用：DNS 缓存无 accountId 字段，
    /// 只能按「当前账号下的域名集合」过滤）。
    nonisolated static func recordCount(inZoneIds zoneIds: Set<String>) -> Int {
        guard !zoneIds.isEmpty else { return 0 }
        return MainActor.assumeIsolated {
            shared.all.reduce(into: 0) { total, record in
                if zoneIds.contains(record.zoneId) { total += 1 }
            }
        }
    }
}
