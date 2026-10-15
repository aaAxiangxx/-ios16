//
//  AppTips.swift
//  Orange Cloud
//
//  首次使用关键功能时的上下文引导（iOS 16 基线适配）。
//
//  TipKit 是 iOS 17 才引入的框架，整个模块在 iOS 16 上不存在（连 `import TipKit` 都会编译失败），
//  因此这里做编译期隔离：
//  - `#if canImport(TipKit)`（iOS 17+）：保留原有 4 个 `Tip` 实现；
//  - `#else`（iOS 16）：用等价的自有提示模型 `OCTip` 承载同样的「标题 / 正文 / 图标」三要素，
//    由 `OCTipView`（见 iOS16Compat.swift）以横幅形式呈现。
//
//  iOS 16 与 iOS 17+ 的可见差异（预期内）：iOS 16 无系统气泡的浮层与「不再显示」持久化，
//  改为常驻页内横幅；`#Rule` 条件规则（hasMultipleAccounts）在 iOS 16 降级为
//  由调用方自己判断是否展示（DashboardView 的 usesInlineTip 已承担该判断）。
//

import Foundation
import SwiftUI

#if canImport(TipKit)
import TipKit

// MARK: - iOS 17+：原生 TipKit 实现

/// Zone 列表：下拉刷新
nonisolated struct ZoneRefreshTip: Tip {
    var title: Text {
        Text("下拉刷新")
    }
    var message: Text? {
        Text("列表展示的是本地缓存，下拉可从 Cloudflare 拉取最新数据")
    }
    var image: Image? {
        Image(systemName: "arrow.clockwise")
    }
}

/// DNS 列表：滑动操作
nonisolated struct DNSSwipeTip: Tip {
    var title: Text {
        Text("滑动管理记录")
    }
    var message: Text? {
        Text("在记录上向左滑动可以编辑或删除")
    }
    var image: Image? {
        Image(systemName: "hand.draw")
    }
}

/// 实时日志：暂停
nonisolated struct TailPauseTip: Tip {
    var title: Text {
        Text("日志滚动太快？")
    }
    var message: Text? {
        Text("点击暂停可冻结画面，连接保持不断开")
    }
    var image: Image? {
        Image(systemName: "pause.circle")
    }
}

/// Dashboard：账号切换
nonisolated struct AccountSwitchTip: Tip {
    var title: Text {
        Text("多账号切换")
    }
    var message: Text? {
        Text("点击账号卡片可在多个 Cloudflare 账号间快速切换")
    }
    var image: Image? {
        Image(systemName: "person.2")
    }

    /// 只有多账号用户才显示
    @Parameter static var hasMultipleAccounts: Bool = false

    var rules: [Rule] {
        #Rule(Self.$hasMultipleAccounts) { $0 == true }
    }
}

#else

// MARK: - iOS 16：自有提示模型（TipKit 的等价降级）

/// iOS 16 上的提示模型，字段与 TipKit 的 `title` / `message` / `image` 一一对应，
/// 使 `OCTipView` 能对两个平台复用同一份调用点结构。
struct OCTip: Identifiable {

    let id: String
    let title: String
    let message: String?
    let systemImage: String?

    init(id: String, title: String, message: String? = nil, systemImage: String? = nil) {
        self.id = id
        self.title = title
        self.message = message
        self.systemImage = systemImage
    }
}

/// Zone 列表：下拉刷新
nonisolated let zoneRefreshTip = OCTip(
    id: "zone.refresh",
    title: "下拉刷新",
    message: "列表展示的是本地缓存，下拉可从 Cloudflare 拉取最新数据",
    systemImage: "arrow.clockwise"
)

/// DNS 列表：滑动操作
nonisolated let dnsSwipeTip = OCTip(
    id: "dns.swipe",
    title: "滑动管理记录",
    message: "在记录上向左滑动可以编辑或删除",
    systemImage: "hand.draw"
)

/// 实时日志：暂停
nonisolated let tailPauseTip = OCTip(
    id: "tail.pause",
    title: "日志滚动太快？",
    message: "点击暂停可冻结画面，连接保持不断开",
    systemImage: "pause.circle"
)

/// Dashboard：账号切换（仅多账号时展示，由调用方判断）
nonisolated let accountSwitchTip = OCTip(
    id: "dashboard.accountSwitch",
    title: "多账号切换",
    message: "点击账号卡片可在多个 Cloudflare 账号间快速切换",
    systemImage: "person.2"
)

#endif
