//
//  CacheModels.swift
//  Orange Cloud
//
//  本地缓存模型：View 从 `ZoneCache` / `WorkerCache` / `DNSCache` 读取，ViewModel 刷新 API 后写入，
//  离线可读。
//
//  iOS 16 基线适配（本文件由 SwiftData `@Model` + class 全面改写而来）：
//  - **SwiftData 整个框架是 iOS 17+ 才有的**，iOS 16 上 `import SwiftData` 即编译失败，
//    因此模型改为 `Codable struct`，落盘由 `CacheStore`（JSON 文件）承担；
//  - class → struct 带来两个必须显式处理的连带影响（都已在下面收口）：
//    1. **Hashable 语义**：SwiftData 的 class 是引用语义，struct 是值语义。
//       若用编译器合成的 Hashable，`updatedAt` 会参与哈希，导致每次刷新后
//       `.navigationDestination(for: CachedZone.self)` 认定「换了一个对象」而反复重推导航。
//       故下面为每个模型手写 `==` / `hash(into:)`，**只以 `id`（Worker 为 `key`）为准**。
//    2. **选中态比较**：调用方原本靠 `==` 判断「选中的那条还在不在列表里」，
//       struct 值拷贝会让这种比较失效。约定：涉及选中/删除目标的比较一律按 `id`。
//
//  唯一性同样由各 upsert 路径（先按 id 查找，再 update-or-replace）在代码层保证。
//

import Foundation

// MARK: - Zone

struct CachedZone: Codable, Identifiable, Hashable {

    var id: String
    var name:        String
    var status:      String
    var planName:    String
    var nameServers: [String]
    var accountId:   String
    var updatedAt:   Date
    var pinned:      Bool = false    // 固定到 Dashboard 首页（用户手动控制，刷新不重置）
    // DNS 记录总数（Dashboard 轻量 total_count 回写 / 详情页兜底拉取），nil = 尚未统计。
    var dnsRecordCount: Int?
    // 是否暂停 Cloudflare 代理。API 里与 status 正交（暂停时 status 仍是 active），
    // 展示状态一律读 displayStatus，别直接读 status。
    var paused: Bool = false

    init(from zone: Zone, accountId: String) {
        self.id          = zone.id
        self.name        = zone.name
        self.status      = zone.status
        self.planName    = zone.plan?.name ?? "—"
        self.nameServers = zone.nameServers ?? []
        self.accountId   = accountId
        self.updatedAt   = Date()
        self.paused      = zone.paused ?? false
    }

    /// 就地更新远端字段。
    ///
    /// 刻意**不碰** `pinned` 与 `dnsRecordCount`：前者是用户手动状态（刷新不得重置），
    /// 由 `ZoneCache.upsert` 从旧记录继承；后者由 Dashboard 的轻量统计单独回写。
    mutating func update(from zone: Zone) {
        name        = zone.name
        status      = zone.status
        planName    = zone.plan?.name ?? "—"
        nameServers = zone.nameServers ?? []
        paused      = zone.paused ?? false
        updatedAt   = Date()
    }

    /// 对外展示用状态：暂停优先于 status（Cloudflare 暂停时 status 仍报 active）
    var displayStatus: String { paused ? "paused" : status }

    /// 只按 `id` 判定相等——见文件头「连带影响 1」。
    static func == (lhs: CachedZone, rhs: CachedZone) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - Worker 脚本

struct CachedWorkerScript: Codable, Identifiable, Hashable {

    // 脚本名只在账号内唯一，全局唯一键用 accountId/scriptId 复合（代码层 upsert 去重）
    var key: String
    var id:         String          // 脚本名
    var accountId:  String
    var createdOn:  String?
    var modifiedOn: String?
    var usageModel: String?
    var handlers:   [String]
    var logpush:    Bool
    var updatedAt:  Date

    init(from script: WorkerScript, accountId: String) {
        self.key        = "\(accountId)/\(script.id)"
        self.id         = script.id
        self.accountId  = accountId
        self.createdOn  = script.createdOn
        self.modifiedOn = script.modifiedOn
        self.usageModel = script.usageModel
        self.handlers   = script.handlers ?? []
        self.logpush    = script.logpush ?? false
        self.updatedAt  = Date()
    }

    mutating func update(from script: WorkerScript) {
        createdOn  = script.createdOn
        modifiedOn = script.modifiedOn
        usageModel = script.usageModel
        handlers   = script.handlers ?? []
        logpush    = script.logpush ?? false
        updatedAt  = Date()
    }

    /// 唯一键是 `key`（accountId/scriptId 复合），故按 `key` 判定。
    static func == (lhs: CachedWorkerScript, rhs: CachedWorkerScript) -> Bool { lhs.key == rhs.key }
    func hash(into hasher: inout Hasher) { hasher.combine(key) }
}

// MARK: - DNS 记录

struct CachedDNSRecord: Codable, Identifiable, Hashable {

    var id: String
    var type:      String
    var name:      String
    var content:   String
    var proxied:   Bool
    var ttl:       Int
    var priority:  Int?
    var comment:   String?
    var zoneId:    String
    var updatedAt: Date
    /// 该名称已被 NS 委派遮蔽，Cloudflare 不会响应这条记录
    var isShadowed: Bool = false
    /// NS 委派记录遮蔽了多少条记录
    var shadowedRecordsCount: Int = 0

    init(from record: DNSRecord, zoneId: String) {
        self.id        = record.id
        self.type      = record.type
        self.name      = record.name
        self.content   = record.content
        self.proxied   = record.isProxied
        self.ttl       = record.ttl
        self.priority  = record.priority
        self.comment   = record.comment
        self.zoneId    = zoneId
        self.updatedAt = Date()
        self.isShadowed = record.isShadowed
        self.shadowedRecordsCount = record.shadowedRecordsCount
    }

    /// includesShadowMetadata：列表刷新（带 include_shadow_metadata）时为 true，以响应为准覆盖；
    /// 单条增改（POST/PUT 响应）不带遮蔽信息，保留已知值，等下次列表刷新再校准。
    mutating func update(from record: DNSRecord, includesShadowMetadata: Bool = false) {
        type      = record.type
        name      = record.name
        content   = record.content
        proxied   = record.isProxied
        ttl       = record.ttl
        priority  = record.priority
        comment   = record.comment
        updatedAt = Date()
        if includesShadowMetadata {
            isShadowed = record.isShadowed
            shadowedRecordsCount = record.shadowedRecordsCount
        }
    }

    /// DNS 记录 id 在账号内唯一，直接按 `id` 判定。
    static func == (lhs: CachedDNSRecord, rhs: CachedDNSRecord) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
