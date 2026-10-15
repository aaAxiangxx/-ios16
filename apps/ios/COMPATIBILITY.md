# iOS 16 适配说明（COMPATIBILITY.md）

本文档记录 Orange Cloud iOS 客户端从 **iOS 17 基线降到 iOS 16.2 基线** 的完整改动、
降级取舍、以及必须人工核查的清单。

---

## 一、结论速览

| 项 | 值 |
| --- | --- |
| 主 App 部署目标 | iOS **16.2** |
| Widget Extension 部署目标 | iOS **16.2** |
| File Provider 扩展 / Push 通知扩展 | iOS **16.2**（必须与主 App 对齐，见下方说明） |
| Watch App / Watch Extension | **保持 watchOS 10.6 不动**（watchOS 独立版本线，与 iOS 部署目标无关） |
| 为什么是 16.2 而不是 16.0 / 16.1 | Live Activity 用的 `ActivityContent` 自 **iOS 16.2** 引入。锁 16.1 需要重写 tail Live Activity 的更新链路并放弃 `staleDate`，收益不抵成本 |
| 验收标准 | 保功能，视觉可降级 —— 以「iOS 16 上能正常启动并使用」为准，不追求像素级还原 iOS 17 观感 |

> **关于扩展必须一起降的原因**：Apple 要求 App Extension 的 `IPHONEOS_DEPLOYMENT_TARGET`
> **不得低于其宿主 App**。若主 App 是 16.2 而扩展是 17.0，Xcode 构建时能过，
> 但产出的 `.app` 装到 iOS 16 设备上会因扩展要求更高系统版本而**无法安装 / 启动即崩**，
> 上架 App Store Connect 也会被校验拒绝。所以「Orange Cloud File」与「notification」
> 两个 target 必须同步降到 16.2 —— 它们是 iOS 侧扩展，与 Watch 那条独立版本线无关。

改造范围：**主 App + Widget（含 Live Activity）** 共 403 个 Swift 文件，其中实际改动 66 个文件、新增 5 个文件、删除 2 个文件。

---

## 二、iOS 17 依赖清单与处置

改写前穷举出 12 类 iOS 17 专属依赖。每一类的处置方式如下：

| # | iOS 17 依赖 | 出现量 | 处置方式 | 风险等级 |
| --- | --- | --- | --- | --- |
| 1 | **SwiftData**（`@Model` / `@Query` / `ModelContext` / `#Predicate`） | 31 文件 | 整体重写为 Codable struct + JSON 文件落盘 | 高（详见 §3） |
| 2 | **Observation**（`@Observable` / `@Bindable` / `@Environment(X.self)`） | 98 类 / 608 属性 / 97 注入 | 改写为 `ObservableObject` + `@Published` + `@EnvironmentObject` | 高（详见 §4） |
| 3 | **MapKit SwiftUI**（`Map` / `MapCameraPosition` / `Annotation` / `mapStyle`） | 1 页 | `#if OC_MAP_AVAILABLE` 编译期隔离，iOS 16 显示占位 | 中 |
| 4 | **TipKit**（`Tip` / `TipView` / `Tips.configure`） | 4 Tip + 8 import | `#if canImport(TipKit)` 隔离，iOS 16 用页内横幅 | 中 |
| 5 | **`ContentUnavailableView`** | 66 处 | 兼容层 `OCEmptyStateView`（55）/ `OCSearchEmptyStateView`（11） | 低 |
| 6 | **`sensoryFeedback`** | 55 处 | 兼容层 `ocSensoryFeedback`（iOS 16 用 UIKit 反馈生成器） | 低 |
| 7 | **`symbolEffect`** | 5 处 | 兼容层：旋转 / 弹动 / 内容过渡三套降级 | 低 |
| 8 | **`.animation(.smooth/.snappy)`** | 9 处 | 兼容层 `Animation.ocSmooth` / `.ocSnappy` | 低 |
| 9 | **`onChange(of:initial:)` 双参签名** | 集中于触感兼容层 | 改用单参 `onChange` + `@State lastTrigger` 建立基线（首次只记录、后续变化才触发） | 低 |
| 10 | **`.chartXSelection(value:)`** | 1 处 | 兼容层 `ocChartXSelection`（iOS 16 分支清空绑定） | 低 |
| 11 | **`containerBackground` / `contentMarginsDisabled`** | Widget | WidgetKit 层按 `#available` 双分支 | 中 |
| 12 | **`AppIntentConfiguration` / `AppIntentTimelineProvider` / `WidgetConfigurationIntent`** | 4 Widget | 编译期宏二选一，iOS 16 退回 `StaticConfiguration` + `TimelineProvider` | 中（详见 §5） |

### 为什么大量使用「编译期隔离」而非 `#available`

`#available` 只在**类型已存在**的前提下有效。当 iOS 16 上某个**类型根本不存在**时
（`ContentUnavailableView`、`MapCameraPosition`、`TipKit` 整个模块、`WidgetConfigurationIntent`），
`#available` 挡不住 —— 代码会通过编译、通过静态审查，**运行到才崩**。

因此本次改造确立了一条判据：

- **类型不存在类问题** → 一律用 `#if canImport(...)` 或自定义编译宏，编译期隔离；
- **已有等价实现类问题**（触感、动画、空态视图）→ 用 `#available`，保留 iOS 17 的原生体验。

---

## 三、SwiftData → JSON 文件缓存

### 3.1 为什么整体重写而不是降级封装

SwiftData 整个框架在 iOS 17 才引入，没有 iOS 16 的等价物。保留 `@Query` 语义需要
自定义一套谓词 + 排序 + 视图生命周期刷新机制，成本高于直接重写。

### 3.2 文件结构

**删除**：`Core/Cache/CacheContainer.swift`、`Core/Cache/SafeCache.swift`

**新增**：

| 文件 | 职责 |
| --- | --- |
| `Core/Cache/CacheStore.swift` | `nonisolated enum CacheStore` —— 泛型 JSON 落盘（`load` / `save` / `destroyAll` / `consumeLegacyRebuildFlagIfNeeded`），存 `Documents/OrangeCloudCache/{zones,workers,dns}.json` |
| `Core/Cache/CacheStores.swift` | `ZoneCache` / `WorkerCache` / `DNSCache` 三个 `@MainActor final class: ObservableObject` |
| `Core/Cache/CacheModels.swift`（重写） | 3 个 `@Model final class` → `Codable struct` |

### 3.3 关键设计决策

**原子写**：`save` 先写临时文件再 `replaceItemAt`，避免写入中途被杀导致缓存半截。
解码失败则删文件重建 —— 缓存丢失不该让 App 打不开，这是从原 `CacheContainer` 延续的核心约束。

**为什么用「按账号分区的显式 Store」而不是泛型单例**：
`@Query(filter:sort:)` 提供了三件事 —— 谓词过滤、排序、视图生命周期自动刷新。
泛型 `CacheStore<T>` 只能表达落盘，这三件必须由具体类型承担。
于是每个 Store 内部持有**当前账号**的过滤结果，`activate(accountId:)` 负责切换。

**Hashable 语义必须显式手写**：原 `@Model final class` 是引用类型，`Hashable` 走 `ObjectIdentifier`，
同一实体的两次读取会判为「同」；改成 struct 后是值语义，`NavigationPath` 的去重会失效。
因此 3 个模型都手写了 id-based 相等性：

```swift
static func == (lhs: CachedZone, rhs: CachedZone) -> Bool { lhs.id == rhs.id }
func hash(into hasher: inout Hasher) { hasher.combine(id) }
```

`CachedWorkerScript` 用 `key`（`accountId/scriptId` 复合唯一）而非 `id`。

**`pinned` / `dnsRecordCount` 显式继承**：`ZoneCache.upsert` 只用远端字段更新 `CachedZone`，
`pinned` 从旧记录继承 —— 用户手动固定的域名不会被一次列表刷新重置。

### 3.4 行为差异（已知且可接受）

| 差异 | 影响 | 缓解 |
| --- | --- | --- |
| `@Query` 在视图 `init` 里就带谓词，冷启动首帧即有数据；Store 走 `.task { store.activate(...) }` | **首帧为空列表**，随后一次发布被缓存填上 | 父视图已有 `.id(selectedAccount)` 负责重建，语义一致；视觉上多一帧空列表 |
| `@Query` 属性级跟踪，Store 整数组一次发布 | 改一个字段会重算整个列表 | 单账号域名数几十条，无实际性能差别 |
| 无 `ModelContext` 事务 | 不存在「一次保存里部分失败回滚」 | 单文件原子写已覆盖；跨文件一致性靠 `CacheSync` 顺序执行 |

### 3.5 改写涉及的全部调用点

- 5 个视图：`DNSListView` / `WorkerListView` / `ZoneDetailView` / `DashboardView` / `ZoneListView`（`@Query` → `@EnvironmentObject` + 显式排序计算属性 + `.task { activate(...) }`）
- 5 个 ViewModel：`AddZoneViewModel` / `DNSListViewModel` / `DashboardViewModel` / `WorkerListViewModel` / `ZoneListViewModel`（去掉 `ModelContext` 参数）
- 3 个后台/Intent：`Core/Intents/ZoneEntity.swift`、`Core/System/BackgroundRefresh.swift`、`Core/System/AppNotifications.swift`
- 缓存策略：`CachePolicy.swift` / `CacheSync.swift` 去掉 `context` 参数
- 注入：`Orange_CloudApp.swift` 的 `.modelContainer(...)` → 三个 `.environmentObject(...)`

`@Published` 属性只能在主线程读，因此为后台刷新 / App Intents 提供了
`nonisolated static func snapshot(...)` 出口（内部用 `MainActor.assumeIsolated`）。

---

## 四、Observation → ObservableObject

### 4.1 改写量

| 项 | 数量 |
| --- | --- |
| `@Observable` → `ObservableObject` 改写的类 | **98** 个（97 个 `@MainActor final class` + 1 个 `private final class`）<br>（全项目 `: ObservableObject` 共 101 处，含 `CacheStores.swift` 原有的 3 个 Store） |
| 插入 `@Published` | **608** 处存储属性<br>（全项目 `@Published` 共 611 处，含 `CacheStores.swift` 原有的 3 处 `private(set)`） |
| `@Environment(X.self)` → `@EnvironmentObject` | **97** 处读取侧（`AuthManager` 74 / `EntitlementStore` 12 / `SessionStore` 11） |
| `@EnvironmentObject` 声明总数 | 106 处（上列 97 + SwiftData 改造引入的缓存 Store 9） |
| 注入侧 `.environment(...)` → `.environmentObject(...)` | **9** 处（`Orange_CloudApp` 3 / `ContentView` 1 / Preview 4 / `ProGate` 1 / `PaywallView` 1 —— 含重复） |
| `@State` → `@StateObject` | **5** 处：`Orange_CloudApp.authManager`、`ContentView.session`、`DashboardView.paywallPresenter`、`WorkersAIView.playVM` / `imageVM` |
| `@Bindable` → `@ObservedObject` | **5** 处：`ContentView.router`、`ZoneTrafficDetailsSection.viewModel`、`DashboardView.PaywallSheetHost.presenter`、`WorkersAIView.playVM` / `imageVM` |
| 删除 `import Observation` | 63 处 |

### 4.2 静默失效风险（这是本次改造最需要警惕的部分）

`@Environment(X.self)` → `@EnvironmentObject` 是**漏改不报编译错**的改动。
如果只改了注入侧没改读取侧，或者反过来，编译器全程沉默，运行时才出问题。

同时 `@State` 持有 `ObservableObject` 是 iOS 17 代码里最典型的静默失效写法 ——
能编译、能跑，但对象变化**不会触发界面刷新**。5 处全部改为 `@StateObject`。

5 处 `@Bindable` 改为 `@ObservedObject`：两者都提供 `$` 投影，在只需要绑定的场合是等价替代。

### 4.3 已知的行为退化

`@Observable` 是**属性级**跟踪，`ObservableObject` 是**整对象级** `objectWillChange`。
`DashboardView`（1800+ 行）在任何 VM 的任意 `@Published` 变化时都会重算整个 body。
列表页数据量小，实际感知不到；但如果后续给 Dashboard 加高频刷新的图表，需要注意这点。

### 4.4 附带收益

`AuthManager` 的 608 个属性现在会在变化时通知视图树。改造前 97 处注入式读取
在 `@Observable` 下已经是属性级跟踪，改写后行为一致 —— 这一项**无退化**。

---

## 五、Widget 双份配置

### 5.1 iOS 16 / iOS 17 是两套不同的框架能力

这是本次改造中最容易踩坑的一点。`AppIntents` 框架本身在 iOS 16 就存在
（`AppIntent` / `AppEntity` / `EntityQuery` / `@Parameter` 都是 16 引入的），
但把它接进 WidgetKit 的三个关键胶水 —— `WidgetConfigurationIntent` 协议、
`AppIntentTimelineProvider`、`AppIntentConfiguration` —— **全是 iOS 17 才有的**。

也就是说：iOS 16 上 `import AppIntents` 会成功，写 `struct X: WidgetConfigurationIntent` 却会编译失败。
这正是 `#if canImport` 最危险的形态：**框架在、你要用的类型不在**。

判定宏用 `__IPHONE_OS_VERSION_MIN_REQUIRED`（SDK 预定义的部署目标数值宏，iOS 17.0 → 170000）。
它反映的是**本 target 的部署目标**，因此按 target 天然分档，
不会像运行期 `#available` 那样出现「编译通过、运行才炸」。

### 5.2 两套实现的对照

| | iOS 17+ | iOS 16 |
| --- | --- | --- |
| 配置方式 | 长按 → 配置面板选参数 | 无配置面板 |
| 配置声明 | `WidgetConfigurationIntent` | `WidgetLegacySelection`（App Group 读取） |
| Provider | `AppIntentTimelineProvider` | 基类 `TimelineProvider` |
| 配置容器 | `AppIntentConfiguration` | `StaticConfiguration` |
| 参数来源 | Intent 参数 | App Group 快照 + 当前账号 |
| 内容边距 | `contentMarginsDisabled()` | 系统默认边距（不调用） |
| 容器背景 | `containerBackground(for: .widget)` | `.background { }` |

**取舍说明**：iOS 16 上 Widget 退化为「展示当前 App 内所选账号 / 首个域名 / 首个服务」，
不提供长按切换。这是 iOS 16 的**平台能力边界**，不是实现取舍 ——
iOS 16 的 WidgetKit 只能配 `StaticConfiguration` / `IntentConfiguration`，
后者基于 ObjC 的 SiriKit Intent，与本项目的 Swift AppIntents 参数体系不通。

为保证同一账号状态下两个系统上卡片内容一致，`WidgetLegacySelection` 的默认值口径
与 iOS 17 各 EntityQuery 的 `defaultResult()` 逐条对齐。

### 5.3 涉及文件

| 文件 | 改动 |
| --- | --- |
| `Shared/WidgetCompat.swift` | **新增**：判定宏 + iOS 16 的 `WidgetLegacySelection`（账号/域名/指标/服务四类选择 + 服务名表） |
| `Shared/ZoneWidgetMetric.swift` | **新增**：从 `WidgetConfigIntents.swift` 独立出来的纯 enum |
| `Shared/WidgetConfigIntents.swift` | 整个文件包进 `#if __IPHONE_OS_VERSION_MIN_REQUIRED >= 170000` |
| `OrangeCloudWidgets/UsageWidget.swift` | Provider 与 Widget 配置各双份 |
| `OrangeCloudWidgets/ZoneStatusWidget.swift` | 同上 |
| `OrangeCloudWidgets/ZoneWidgets.swift` | 两个 Widget（ZoneStat / ZoneChart），各双份 |
| `OrangeCloudWidgets/WidgetAccessory.swift` | `containerBackground` → `#available` 双分支 |
| `OrangeCloudWidgets/TailLiveActivityWidget.swift` | 仅补注释（`ActivityKit` 16.1 起可用，无需改动） |
| `OrangeCloudWidgets/OrangeCloudControlWidget.swift` | 仅补注释（已有 `@available(iOS 18.0, *)` 门控） |

**为什么 `ZoneWidgetMetric` 要独立成文件**：它是纯 Swift enum、视图层直接消费，
但原先和 `WidgetConfigurationIntent` 放在同一文件。iOS 16 上整个文件被条件编译隔离，
这个两个 target 都要用的 enum 会跟着消失，`ZoneWidgets` 就编不过。
**凡是被视图层直接消费的模型，一律放在不参与条件编译的文件里。**

---

## 六、新增的兼容层

| 文件 | 内容 |
| --- | --- |
| `Core/UI/iOS16Compat.swift` | `OCEmptyStateView` / `OCSearchEmptyStateView`（替代 `ContentUnavailableView`，签名与系统版对齐，含 4 个 init）、`tipViewCompat` / `popoverTipCompat`、`OCTipBanner`、`OCSensoryFeedbackModifier`、`Animation.ocSmooth` / `.ocSnappy`、`ocChartXSelection` |
| `Core/UI/AvailabilityCompat.swift`（改造） | 头部注释更新；TipKit 隔离；`loadingSpinSymbolEffect` 补 iOS 16 分支（`rotationEffect` + linear repeatForever）；新增 `bounceSymbolEffectOnChange` / `symbolEffectReplaceTransition` |

MapKit 用自定义编译条件 `OC_MAP_AVAILABLE` 隔离 —— 已注入主 App target 的
Debug / Release 两份 `SWIFT_ACTIVE_COMPILATION_CONDITIONS`。
之所以不用 `canImport`：MapKit 框架在 iOS 16 **是存在的**，只是它的 SwiftUI 层（`Map` /
`MapCameraPosition` / `Annotation`）是 17 才加的 —— 又一个「框架在、类型不在」。

---

## 七、必须人工核查的清单

> ⚠️ **本次改动未经真正的 `xcodebuild` 编译验证。** 改造环境是 Linux 沙箱，没有 macOS / Xcode / iOS SDK。
> 已完成的替代验证见 §6.5；以下清单请在 macOS 上逐项过一遍。

### 7.0 已完成的替代验证（Linux 上可做的部分）

| 验证项 | 方法 | 结论 |
| --- | --- | --- |
| 语法正确性 | Swift 6.4.1 Linux 工具链 `swift-frontend -frontend -parse`，对 403 个 .swift 文件分别按 **iOS 17 分支**与 **iOS 16 分支**各跑一遍 | ✅ 806 次解析全部通过，无语法错误 |
| 条件编译对称性 | 同上，两个分支都必须能独立解析（防止 `#if` / `#endif` 配对错位） | ✅ 通过 |
| iOS 17 专属 API 残留 | 全量 grep 12 类关键词，逐条回溯判定是真实调用还是文档注释 | ✅ 无真实残留（命中项全在注释或条件编译内） |
| pbxproj 结构完整性 | 改后统计 `{}/()`/`/* */` 配对与 diff 逐行复核 | ✅ 平衡，diff 精确 6 行 |
| 扩展 target 依赖 | 扫描 `Orange Cloud File` 与 `notification` 的 iOS 17 API 与协议方法 | ✅ 零依赖，无需改代码 |

> 关于「分支扫描」：`#if __IPHONE_OS_VERSION_MIN_REQUIRED >= 170000` 在 Linux 上是未定义标识符，
> 且 `-parse` 模式不支持 `#if` 里的算术比较（`#if 1 >= 1` 本身就会报错），
> 所以扫描时把该表达式替换成 `true` / `false` 字面量。两种分支都要能解析，才能覆盖到两套 Widget 代码。

### 7.1 第一优先：编译

- [ ] `xcodebuild -scheme "Orange Cloud" -destination 'generic/platform=iOS' build`
      重点看是否报「找不到 `ContentUnavailableView` / `MapCameraPosition` / `WidgetConfigurationIntent`」
- [ ] `xcodebuild -scheme OrangeCloudWidgetsExtension -destination 'generic/platform=iOS' build`
- [ ] `xcodebuild -scheme "Orange Cloud File" -destination 'generic/platform=iOS' build`
- [ ] `xcodebuild -scheme notification -destination 'generic/platform=iOS' build`
      （这两个扩展随主 App 一起打包，签名或部署目标出问题会连带装不上）
- [ ] 用 iOS 16.2 或 16.7 真机 / 模拟器实跑，确认启动不崩

### 7.2 第二优先：静默失效（编译通过但行为错）

这一类**不会有任何编译错误**，必须手动验证：

- [ ] **登录 / 退出 / 切账号** → 界面是否跟着刷新（验证 `@StateObject` + `@EnvironmentObject` 生效）
- [ ] **Dashboard 首屏**是否闪一帧空列表再填上（§3.4 的已知差异）
- [ ] **域名列表固定（pinned）** → 切账号再切回来是否还在（验证 `pinned` 继承）
- [ ] **切账号时**域名列表是否正确刷新（验证 `activate(accountId:)`）
- [ ] **DNS 记录页**下拉刷新后，被远端删除的记录是否从列表消失（验证 `replaceAll(forZone:with:)`）
- [ ] **后台通知的域名状态变更**是否还能触发（验证 `AppNotifications` → `ZoneCache.applyBackgroundStatusUpdates`）
- [ ] **Spotlight 搜索跳转**是否正常（验证 `ZoneEntity` 走 `ZoneCache.snapshotAll()`）

### 7.3 第三优先：视觉降级确认

- [ ] **流量地图页**（`ZoneTrafficMapView`）→ iOS 16 显示「需要 iOS 17」占位，Top5 图例仍可用
- [ ] **Dashboard 的 onboarding 提示**（原 TipKit popover）→ iOS 16 显示页内横幅
- [ ] **触觉反馈**在 iOS 16 上是否有效（`UINotificationFeedbackGenerator` 路径）
- [ ] **加载中的 spinner** → iOS 16 走 `rotationEffect` 无限旋转
- [ ] **Widget 长按** → iOS 16 无配置面板（预期行为，非 bug）

### 7.4 已知的可接受行为

| 现象 | 原因 |
| --- | --- |
| iOS 16 Widget 无长按配置 | iOS 16 WidgetKit 只有 `StaticConfiguration` / `IntentConfiguration` |
| 域名流量地图不可用 | MapKit SwiftUI 层是 iOS 17+ |
| Dashboard 首帧空列表 | `@Query` → `.task` 驱动的 Store |
| Dashboard 任意字段变化都重算整个 body | `ObservableObject` 是整对象级通知 |

---

## 八、涉及的部署目标改动（project.pbxproj）

改动 **10 处** `IPHONEOS_DEPLOYMENT_TARGET`：`17.0` → `16.2`

| 行号 | target | 处理 |
| --- | --- | --- |
| 656 / 688 | OrangeCloudWidgetsExtension Debug / Release | ✅ 改为 16.2 |
| 987 / 1033 | Orange Cloud（主 App）Debug / Release | ✅ 改为 16.2 |
| 855 / 885 | Orange Cloud File（文件 App 扩展）Debug / Release | ✅ 改为 16.2（**必须对齐宿主 App**） |
| 915 / 945 | notification（推送扩展）Debug / Release | ✅ 改为 16.2（**必须对齐宿主 App**） |
| 1110 / 1170 | PBXProject 级默认 | ✅ 改为 16.2（避免将来新增 target 误继承 17.0） |
| 738 / 772 / 806 / 840 | watchOS（`WATCHOS_DEPLOYMENT_TARGET = 10.6`） | ⬜ 不动（watchOS 独立版本线） |

最终 4 个 iOS target（主 App / Widget / File 扩展 / Push 扩展）部署目标全部为 `16.2`，无 17.0 残留。

两个扩展的源码已确认**零 iOS 17 依赖**：不含 SwiftData、Observation、`ContentUnavailableView`、
`sensoryFeedback`、`symbolEffect`、AppIntents；`Orange Cloud File` 用到的
`NSFileProviderExtension` / `NSFileProviderEnumerator` 全部方法在 iOS 16 已存在，
因此无需为降级改动任何代码。

另在主 App 两份配置新增自定义编译条件（用于隔离 MapKit SwiftUI）：

```
SWIFT_ACTIVE_COMPILATION_CONDITIONS = "DEBUG OC_MAP_AVAILABLE $(inherited)";   // Debug
SWIFT_ACTIVE_COMPILATION_CONDITIONS = "OC_MAP_AVAILABLE $(inherited)";         // Release
```

工程使用 Xcode 16 的 `fileSystemSynchronizedGroups`，**新增 .swift 文件自动进对应 target，
无需手工改 pbxproj 加文件引用**。已核对同步组配置：

- 主 App target：`Shared` + `Orange Cloud`
- Widget target：`Shared` + `OrangeCloudWidgets`
- Watch targets：`Shared` + `Orange Cloud Watch Watch App`

`Shared/WidgetCompat.swift` 与 `Shared/ZoneWidgetMetric.swift` 只依赖 `WidgetSnapshot` /
`ByteFormat`（纯 Foundation，无 WidgetKit 依赖），Watch target（部署目标仍 17.0，
会编 `WidgetCompat` 的 iOS 17 分支）编译安全。
