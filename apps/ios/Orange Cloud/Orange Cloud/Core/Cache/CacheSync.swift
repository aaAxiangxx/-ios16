//
//  CacheSync.swift
//  Orange Cloud
//
//  Zone / Worker 列表 → 本地缓存的共享同步逻辑。
//  Dashboard 首屏与各列表页都会拉取同一份数据，这里收口避免两份 upsert 代码。
//
//  iOS 16 基线适配：upsert 的实现已下沉到 `ZoneCache` / `WorkerCache`（内部完成
//  「按账号剔除远端已删条目 + 保留 pinned + 落盘」），本文件只保留跨切面的副作用：
//  Widget 快照刷新与 Spotlight 索引。
//

import Foundation
import SwiftUI
import WidgetKit

@MainActor
enum CacheSync {

    /// Zone 列表 upsert 进缓存（删掉远端已不存在的条目），
    /// 并同步主屏 Widget 快照与 Spotlight 索引。
    static func syncZones(_ zones: [Zone], accountId: String, accountName: String) {
        ZoneCache.shared.upsert(zones, accountId: accountId)

        WidgetSnapshot(
            accountId: accountId,
            accountName: accountName,
            totalZones: zones.count,
            activeZones: zones.filter { $0.status == "active" }.count,
            updatedAt: Date()
        ).save()
        WidgetCenter.shared.reloadTimelines(ofKind: "ZoneStatusWidget")

        SpotlightIndexer.indexZones(zones)
    }

    /// Worker 脚本列表 upsert 进缓存（仅限当前账号）。
    static func syncWorkers(_ scripts: [WorkerScript], accountId: String) {
        WorkerCache.shared.upsert(scripts, accountId: accountId)
    }
}
