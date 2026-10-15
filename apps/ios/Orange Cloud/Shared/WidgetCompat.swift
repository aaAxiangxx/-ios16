//
//  WidgetCompat.swift
//  Orange Cloud（主 App 与 Widget Extension 共享）
//
//  iOS 16 基线适配：Widget 配置链路在 iOS 16 / iOS 17 是两套**不同的框架能力**，
//  不是同一套 API 的新旧版本，必须编译期二选一。
//
//  为什么不能只用 `#if canImport(AppIntents)`：
//  `AppIntents` 框架本身在 iOS 16 就存在（`AppIntent` / `AppEntity` / `EntityQuery`
//  / `@Parameter` 都是 16 引入的），但把它接进 WidgetKit 的两个关键胶水
//  ——`WidgetConfigurationIntent` 协议、`AppIntentTimelineProvider`、
//    `AppIntentConfiguration` ——**全是 iOS 17 才有的**。
//  也就是说 iOS 16 上 `import AppIntents` 会成功，写 `struct X: WidgetConfigurationIntent`
//  却会编译失败。这正是 `#if canImport` 最危险的形态：框架在、你要用的类型不在。
//
//  两条路的差异：
//  ┌────────────────────┬──────────────────────────┬────────────────────────────┐
//  │                    │ iOS 17+                  │ iOS 16（本文件 #else 分支） │
//  ├────────────────────┼──────────────────────────┼────────────────────────────┤
//  │ 配置方式           │ 长按 → 配置面板选参数    │ 无配置面板                │
//  │ 配置声明           │ WidgetConfigurationIntent│ WidgetLegacySelection      │
//  │ Provider           │ AppIntentTimelineProvider│ TimelineProvider           │
//  │ 配置容器           │ AppIntentConfiguration   │ StaticConfiguration        │
//  │ 参数从哪来         │ Intent 参数              │ App Group 快照 + 当前账号  │
//  │ 内容边距           │ contentMarginsDisabled   │ 系统默认边距（不调用）      │
//  │ 容器背景           │ containerBackground      │ 直接 .background（见下）    │
//  └────────────────────┴──────────────────────────┴────────────────────────────┘
//
//  取舍：iOS 16 上 Widget 退化为「展示当前 App 内所选账号 / 首个域名 / 首个服务」，
//  不提供长按切换。这是 iOS 16 的平台能力边界，不是实现取舍——
//  iOS 16 的 WidgetKit 只能配 `StaticConfiguration` / `IntentConfiguration`
//  （后者基于 ObjC 的 SiriKit Intent，与本项目的 Swift AppIntents 参数体系不通）。
//
//  判定宏：`__IPHONE_OS_VERSION_MIN_REQUIRED` 是 SDK 预定义的部署目标数值宏
//  （iOS 17.0 → 170000）。它反映的是**本 target 的部署目标**，因此天然按 target 分档，
//  不会像运行期 `#available` 那样出现「编译通过、运行才炸」。
//

import Foundation

#if __IPHONE_OS_VERSION_MIN_REQUIRED >= 170000

/// iOS 17+：走 AppIntents 配置链路。宏为真时才有定义。
/// 单独抽一个名字，是为了让 `#if` 之外的代码也能引用同一判据（写文档/日志时用）。
nonisolated let ocWidgetUsesAppIntents = true

#else

/// iOS 16：走 App Group 快照配置链路。
nonisolated let ocWidgetUsesAppIntents = false

// MARK: - iOS 16 的 Widget 配置读取

/// iOS 16 上 Widget 的「配置」来源。
///
/// 因为没有 `WidgetConfigurationIntent` 面板，参数只能由 App 侧写入 App Group、
/// Widget 侧读取。写入点：App 内切账号 / 进入域名详情 / 选定用量服务时。
/// 这里只提供读取与默认值，语义与 iOS 17 各 EntityQuery 的 `defaultResult()` 对齐
/// ——保证同一个账号状态下两个系统上的卡片内容一致。
nonisolated enum WidgetLegacySelection {

    // 键名与 iOS 17 的 Intent 参数语义一一对应（存进 App Group 的 defaults）
    private static let accountKey = "ocWidgetSelectedAccountId"
    private static let zoneKey   = "ocWidgetSelectedZoneId"
    private static let metricKey = "ocWidgetSelectedMetricRaw"
    private static let serviceKey = "ocWidgetSelectedServiceId"

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: WidgetSnapshot.appGroupID)
    }

    // MARK: 账号

    /// 所选账号 id。未设置时回退 App 内当前账号，再回退 nil（由调用方读目录首项）。
    static var accountId: String? {
        defaults?.string(forKey: accountKey) ?? WidgetSnapshot.currentAccountId()
    }

    static func setAccountId(_ value: String?) {
        defaults?.set(value, forKey: accountKey)
    }

    // MARK: 域名

    /// 所选域名 id。未设置时回退快照里的首个域名——与 iOS 17 `WidgetZoneEntityQuery`
    /// 的 `defaultResult()` 行为一致。
    static func zoneId(preferring id: String?) -> String? {
        if let id, WidgetDataStore.loadZones().contains(where: { $0.id == id }) { return id }
        if let saved = defaults?.string(forKey: zoneKey),
           WidgetDataStore.loadZones().contains(where: { $0.id == saved }) {
            return saved
        }
        return WidgetDataStore.loadZones().first?.id
    }

    static func setZoneId(_ value: String?) {
        defaults?.set(value, forKey: zoneKey)
    }

    // MARK: 指标

    /// 所选指标。未设置时回退 `.requests`，与 iOS 17 `ZoneStatConfigIntent.resolvedMetric` 一致。
    static var metric: ZoneWidgetMetric {
        guard let raw = defaults?.string(forKey: metricKey),
              let m = ZoneWidgetMetric(rawValue: raw) else { return .requests }
        return m
    }

    static func setMetric(_ value: ZoneWidgetMetric) {
        defaults?.set(value.rawValue, forKey: metricKey)
    }

    // MARK: 服务

    /// 所选用量服务 id。未设置时回退 `"workers"`，与 iOS 17 `UsageConfigIntent.serviceId` 一致。
    static var serviceId: String {
        defaults?.string(forKey: serviceKey) ?? "workers"
    }

    static func setServiceId(_ value: String) {
        defaults?.set(value, forKey: serviceKey)
    }

    /// 服务 id → 展示名。
    ///
    /// 必须与 iOS 17 侧 `UsageServiceEntity.all` 的 id/文案严格一致，
    /// 否则同一张卡片在 iOS 16 与 iOS 17 上会显示不同的名字。
    /// （`UsageServiceEntity` 只在 iOS 17 分支存在，这里独立维护一份。）
    static func serviceName(for id: String) -> String {
        switch id {
        case "workers": String(localized: "Workers")
        case "r2":      String(localized: "R2")
        case "d1":      String(localized: "D1")
        case "kv":      String(localized: "KV")
        default:        String(localized: "Workers")
        }
    }
}

#endif
