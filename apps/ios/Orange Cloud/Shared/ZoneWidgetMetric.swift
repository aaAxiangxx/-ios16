//
//  ZoneWidgetMetric.swift
//  Orange Cloud（主 App 与 Widget Extension 共享）
//
//  域名 Widget 的指标枚举（展示文案 + 取数口径）。
//
//  iOS 16 基线适配：本文件从 `WidgetConfigIntents.swift` 独立出来的原因——
//  `ZoneWidgetMetric` 本身是**纯 Swift enum，不依赖 AppIntents**，但它原先被
//  和 `WidgetConfigurationIntent`（iOS 17+ 的协议）放在同一个文件里。
//  iOS 16 上整个 `WidgetConfigIntents.swift` 会被条件编译隔离掉，
//  于是这个两个 target 都要用的 enum 会跟着消失，ZoneWidgets 就编不过。
//  凡是被视图层直接消费的模型，一律放在不参与条件编译的文件里。
//

import Foundation

nonisolated enum ZoneWidgetMetric: String {
    case requests
    case bandwidth
    case threats
    case visitors

    var label: String {
        switch self {
        case .requests:  String(localized: "请求 · 24h")
        case .bandwidth: String(localized: "带宽 · 24h")
        case .threats:   String(localized: "已拦截威胁 · 24h")
        case .visitors:  String(localized: "独立访客 · 24h")
        }
    }

    var displayName: String {
        switch self {
        case .requests:  String(localized: "请求")
        case .bandwidth: String(localized: "带宽")
        case .threats:   String(localized: "拦截威胁")
        case .visitors:  String(localized: "独立访客")
        }
    }

    /// SF Symbol（锁屏 inline / Watch complication 用）
    var symbol: String {
        switch self {
        case .requests:  "chart.bar.fill"
        case .bandwidth: "arrow.down.circle.fill"
        case .threats:   "shield.lefthalf.filled"
        case .visitors:  "person.2.fill"
        }
    }

    func valueText(_ zone: WidgetZoneMetrics) -> String {
        switch self {
        case .requests:  zone.requests.formatted(.number.notation(.compactName))
        case .bandwidth: Int64(zone.bytes).ocBytes
        case .threats:   zone.threats.formatted(.number.notation(.compactName))
        case .visitors:  zone.uniques.formatted(.number.notation(.compactName))
        }
    }

    func series(_ zone: WidgetZoneMetrics) -> [Int] {
        switch self {
        case .bandwidth: zone.bytesSeries
        default:         zone.requestsSeries
        }
    }
}
