//
//  AddZoneViewModel.swift
//  Orange Cloud
//
//  添加域名（新建 Zone）。成功后把新 Zone 单条 upsert 进缓存，
//  列表 @Query 即时可见；createdZone 非空时表单页切换到「名称服务器」结果页。
//

import Foundation
import SwiftUI   // ObservableObject（iOS 16 基线：@Observable 是 iOS 17+）

@MainActor
final class AddZoneViewModel: ObservableObject {

    @Published
    var isSaving = false
    @Published
    var error: String?
    /// 创建成功后非空——View 据此从表单切换到结果页（展示 NS + 后续步骤）
    @Published
    var createdZone: Zone?

    private let zoneService: ZoneService

    init(zoneService: ZoneService) {
        self.zoneService = zoneService
    }

    func create(name: String, accountId: String) async {
        guard !isSaving else { return }
        isSaving = true
        error = nil
        do {
            let zone = try await zoneService.createZone(name: name, accountId: accountId)
            // 只 upsert 这一条：不能用 CacheSync.syncZones（它会删除不在传入列表里的其它 zone，
            // 单条传入会清空该账号下的全部已有域名）。新 zone 一般不存在，做存在性兜底即可。
            ZoneCache.shared.upsert([zone], accountId: accountId)
            createdZone = zone
        } catch {
            self.error = error.localizedDescription
        }
        isSaving = false
    }

    // 原先这里用 SwiftData 的 FetchDescriptor + #Predicate 做单条 upsert。
    // 现直接复用 `ZoneCache.upsert(_:accountId:)`——它内部同样是
    // 「update-or-insert + 剔除远端已删」，传单条时等价于原来的存在性兜底，
    // 且不会像 CacheSync.syncZones 那样清空该账号下的其它域名。
}
