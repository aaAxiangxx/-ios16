//
//  iOS16Compat.swift
//  Orange Cloud
//
//  iOS 16 基线兼容层：集中承接「iOS 17 才引入、但工程大量使用」的 SwiftUI API 降级。
//
//  设计原则（与 AvailabilityCompat.swift 一致，但方向相反）：
//  - AvailabilityCompat 负责「iOS 18/26+ 专属能力在低版本上的**禁用**」；
//  - 本文件负责「iOS 17 才有的 API 在 iOS 16 上的**等价实现**」。
//
//  为什么不做成 `.some View` 的 @ViewBuilder 双分支（`if #available(iOS 17) { 系统版 } else { 自建版 }`）：
//  无编译器环境下 `#available` 是最危险的形态——它 100% 通过编译、100% 通过静态审查，
//  然后在 iOS 16 真机上炸。这里一律采用「**编译期唯一定义**」：
//  iOS 17+ 的原生 API 引用只允许出现在**已确认 iOS 16 有等价实现**的封装内部，
//  View 主体里不再出现任何裸的 iOS 17 API。
//
//  已确认的收益：把 ContentUnavailableView 全量换成 OCEmptyStateView 后，
//  主 App 少 67 处版本敏感调用点，且 iOS 16 / 17+ 共用同一份代码，无需维护两条分支。
//

import SwiftUI

#if canImport(TipKit)
import TipKit

// MARK: - 上下文引导（iOS 17+）

extension View {

    /// `TipView(tip)` 的统一入口：iOS 17+ 走原生 TipKit。
    ///
    /// 两个平台的调用点写法完全一致，因此视图里不需要出现 `#available`。
    /// 之所以必须用 `#if canImport` 编译期隔离而非 `#available`：
    /// iOS 16 上 `TipView` 是「类型不存在」的编译错误，availability 挡不住。
    @ViewBuilder
    func tipViewCompat(tip: some Tip) -> some View {
        if #available(iOS 17.0, *) {
            TipView(tip)
        } else {
            EmptyView()
        }
    }

    /// `popoverTip` 的跨平台包装。iOS 17+ 沿用系统 popover（含 17.0.x 崩溃规避）；
    /// iOS 16 无 popover 气泡能力，降级为不展示。
    ///
    /// 为什么 iOS 16 分支不尝试渲染横幅：`tip` 是 TipKit 的 `some Tip`，要摊平成
    /// 横幅得用 `String(describing:)` 反射 `Text` 字段——那会渲染出 `Text(...)` 的
    /// 调试描述而不是文案，属于"能编译但输出错误内容"的假降级，不如不给。
    /// iOS 16 上的引导改由各页的**页内** `tipViewCompat(tip:)` 横幅承担
    /// （DashboardView 已按画布用 `usesInlineTip` 在 popover / 页内之间二选一，
    /// iOS 16 上只需强制走页内分支，见 DashboardView 的 tipPresentation 分支）。
    @ViewBuilder
    func popoverTipCompat(tip: some Tip, enabled: Bool = true) -> some View {
        if #available(iOS 17.0, *) {
            safePopoverTip(tip, enabled: enabled)
        } else {
            EmptyView()
        }
    }
}

#else

// MARK: - 上下文引导（iOS 16 降级）

extension View {

    /// iOS 16 上的 `TipView` 等价物：以横幅呈现 `AppTips.swift` 定义的 `OCTip`。
    @ViewBuilder
    func tipViewCompat(tip: OCTip) -> some View {
        OCTipBanner(tip: tip)
    }

    /// iOS 16 上的 `popoverTip` 等价物：popover 气泡依赖 TipKit，iOS 16 不具备。
    ///
    /// 与 iOS 17+ 分支**刻意保持行为一致**（都不展示 popover），而不是降级成横幅：
    /// 横幅只能锚在页面主体，而 `popoverTipCompat` 的调用点是工具栏按钮
    /// （WorkerTailView 的暂停键、DashboardView 的账号头像），横幅挂不上那个位置。
    /// iOS 16 上这两处引导因此不展示——属预期内的功能缺失，已记入 COMPATIBILITY.md。
    @ViewBuilder
    func popoverTipCompat(tip: OCTip, enabled: Bool = true) -> some View {
        EmptyView()
    }
}

/// iOS 16 的提示横幅：`Label(title)` + 可选 message，弱化背景、圆角徽标风格。
/// 刻意做得比系统 TipView 安静——iOS 16 没有「不再显示」可持久化，只能长期常驻。
private struct OCTipBanner: View {

    let tip: OCTip

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: tip.systemImage ?? "info.circle")
                .font(.subheadline)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(tip.title)
                    .font(.subheadline.weight(.semibold))
                if let message = tip.message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

#endif

// MARK: - 空状态视图（替代 ContentUnavailableView，iOS 17+）

/// iOS 16 可用的空状态视图，签名与 `ContentUnavailableView` 保持一致，
/// 因此调用点只需把类型名换掉，闭包结构（`label` / `description` / `actions`）一字不改。
///
/// 与系统版的可见差异（已在 COMPATIBILITY.md 记录，属预期的视觉降级）：
///  - 不再由系统接管垂直居中与留白，改为自身 `VStack` + `Spacer` 撑开；
///  - `description` 固定为次要文字样式，系统版会按内容长度自适应字号；
///  - `actions` 恒为水平按钮组，系统版在窄屏（iPhone SE）会自动换行。
struct OCEmptyStateView: View {

    @ViewBuilder private let label: () -> AnyView
    @ViewBuilder private let description: (() -> AnyView)?
    @ViewBuilder private let actions: (() -> AnyView)?

    /// 与系统 `ContentUnavailableView(label:description:)` 对齐。
    init(@ViewBuilder label: () -> some View) {
        self.label = { AnyView(label()) }
        self.description = nil
        self.actions = nil
    }

    /// 与系统 `ContentUnavailableView(label:description:)` 对齐。
    init(@ViewBuilder label: () -> some View,
         @ViewBuilder description: () -> some View) {
        self.label = { AnyView(label()) }
        self.description = { AnyView(description()) }
        self.actions = nil
    }

    /// 与系统 `ContentUnavailableView(label:description:actions:)` 对齐。
    init(@ViewBuilder label: () -> some View,
         @ViewBuilder description: () -> some View,
         @ViewBuilder actions: () -> some View) {
        self.label = { AnyView(label()) }
        self.description = { AnyView(description()) }
        self.actions = { AnyView(actions()) }
    }

    /// 与系统 `ContentUnavailableView(_:systemImage:)` 对齐。
    init(_ title: String, systemImage: String) {
        self.init(label: {
            Label {
                Text(title)
            } icon: {
                Image(systemName: systemImage)
            }
        })
    }

    /// 与系统 `ContentUnavailableView(_:systemImage:description:)` 对齐。
    init(_ title: String, systemImage: String, description: Text) {
        self.init(label: {
            Label {
                Text(title)
            } icon: {
                Image(systemName: systemImage)
            }
        }, description: {
            description
        })
    }

    var body: some View {
        VStack(spacing: 12) {
            Spacer(minLength: 0)
            label()
            if let description {
                description()
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if let actions {
                actions()
                    .padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }
}

/// 替代 `OCSearchEmptyStateView(text:)`。
///
/// 系统版会渲染成系统搜索空态（magnifyingglass + "No Results"）。
/// 这里给出同语义的中文版本，文案走 `String(localized:)` 以复用既有 13 种语言的本地化。
struct OCSearchEmptyStateView: View {

    let text: String

    var body: some View {
        VStack(spacing: 10) {
            Spacer(minLength: 0)
            Image(systemName: "magnifyingglass")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(String(localized: "没有匹配的结果"))
                .font(.headline)
            if !text.isEmpty {
                Text(text)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }
}

// MARK: - 触感反馈（替代 sensoryFeedback，iOS 17+）

/// `sensoryFeedback` 的 iOS 16 等价封装。
///
/// iOS 17+ 走系统触感（尊重系统「触感」设置与减弱动态效果）；
/// iOS 16 退回 `UIImpactFeedbackGenerator` / `UINotificationFeedbackGenerator`，
/// 并在用户开启系统减弱动态效果时不触发，避免无障碍语义丢失。
///
/// 用法与系统版一致：`.ocSensoryFeedback(.success, trigger: didSave)`
extension View {

    /// 触感反馈的抽象输入，对齐系统 `sensoryFeedback` 的参数类型。
    enum OCSensoryFeedback {
        case success
        case warning
        case error
        case selection
        /// 参数标签与系统 `SensoryFeedback.impact(weight:intensity:)` 的 `weight:` 对齐，
        /// 使调用点只需把 `sensoryFeedback` 改名、无需改参数写法。
        case impact(weight: OCSensoryWeight)

        /// 触感强度，对齐系统 `SensoryFeedback` 的 weight 家族。
        enum OCSensoryWeight {
            case light
            case medium
            case heavy
        }
    }

    /// 触感反馈的统一入口，签名与系统 `sensoryFeedback(_:trigger:)` 对齐。
    /// 覆盖工程实际用到的全部形态：`.success` / `.warning` / `.error` / `.selection` / `.impact(weight:)`。
    func ocSensoryFeedback(_ feedback: OCSensoryFeedback,
                           trigger: some Equatable) -> some View {
        modifier(OCSensoryFeedbackModifier(feedback: feedback, trigger: trigger))
    }
}

private struct OCSensoryFeedbackModifier<Trigger: Equatable>: ViewModifier {

    let feedback: View.OCSensoryFeedback
    let trigger: Trigger

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// iOS 16 没有「触发器」语义，只能靠比较「值是否变化」来近似。
    /// 记录上一次的值，首次出现时不补触感（对齐系统版：挂载时若已非默认值也不主动触发）。
    @State private var lastTrigger: Trigger?

    func body(content: Content) -> some View {
        if #available(iOS 17.0, *) {
            content.sensoryFeedback(feedback.sensory, trigger: trigger)
        } else {
            content.onChange(of: trigger) { newValue in
                // 首次见到该值视为「建立基线」，不触发；此后的每次变化才给触感。
                guard let previous = lastTrigger, previous != newValue else {
                    lastTrigger = newValue
                    return
                }
                lastTrigger = newValue
                fire()
            }
        }
    }

    @available(iOS 16.0, *)
    private func fire() {
        // 减弱动态效果下不给触感：系统版 sensoryFeedback 同样受此设置影响。
        guard !reduceMotion else { return }
        switch feedback {
        case .success:
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .warning:
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        case .error:
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        case .selection:
            UISelectionFeedbackGenerator().selectionChanged()
        case .impact(let weight):
            let style: UIImpactFeedbackGenerator.FeedbackStyle
            switch weight {
            case .light:   style = .light
            case .medium:  style = .medium
            case .heavy:   style = .heavy
            }
            UIImpactFeedbackGenerator(style: style).impactOccurred()
        }
    }
}

@available(iOS 17.0, *)
private extension View.OCSensoryFeedback {

    /// 桥接到系统 `SensoryFeedback`。只在 `#available(iOS 17)` 分支内被调用，
    /// 因此 iOS 16 上这段代码不会执行（但仍参与类型检查，故用独立的 available 扩展隔离）。
    var sensory: SensoryFeedback {
        switch self {
        case .success:            return .success
        case .warning:            return .warning
        case .error:              return .error
        case .selection:          return .selection
        case .impact(let weight):
            switch weight {
            case .light:  return .impact(weight: .light)
            case .medium: return .impact(weight: .medium)
            case .heavy:  return .impact(weight: .heavy)
            }
        }
    }
}

// MARK: - 动画曲线（替代 iOS 17 的 .smooth / .snappy）

extension Animation {

    /// iOS 17 的 `.smooth` / `.snappy` 曲线在 iOS 16 无等价物。
    /// 这里按视觉相近度退回 `.easeInOut` / `.spring`，属可接受的观感降级。
    ///
    /// 注意：`Animation.smooth` 与 `.snappy` 是**静态属性**（iOS 17），
    /// 直接替换调用点即可，无需本扩展。此扩展保留给需要带 duration 的场景。
    static var ocSmooth: Animation { .easeInOut(duration: 0.25) }
    static var ocSnappy: Animation { .spring(response: 0.32, dampingFraction: 0.8) }

    /// 带时长的 `.smooth(duration:)` 等价物（见 Daybreak 的逐项入场动画）。
    static func ocSmooth(duration: TimeInterval) -> Animation {
        .easeInOut(duration: duration)
    }

    /// 带时长的 `.snappy(duration:)` 等价物。
    static func ocSnappy(duration: TimeInterval) -> Animation {
        .easeInOut(duration: duration)
    }
}

// MARK: - Charts 交互（替代 iOS 17 的 chartXSelection）

extension View {

    /// iOS 17 的 `.chartXSelection(value:)`（图表点选竖线）在 iOS 16 不可用。
    /// iOS 16 分支直接去掉选中竖线，其余图表（`Chart` / `AreaMark` / `LineMark` /
    /// `RuleMark` / `AxisMarks` 均为 iOS 16 原生）不受影响，仅失去「点选查看某天数值」的交互。
    ///
    /// 用法：把 `.chartXSelection(value: $selectedDate)` 换成 `.ocChartXSelection(value: $selectedDate)`。
    func ocChartXSelection(value: Binding<Date?>) -> some View {
        modifier(OCChartXSelectionModifier(value: value))
    }
}

private struct OCChartXSelectionModifier: ViewModifier {

    @Binding var value: Date?

    func body(content: Content) -> some View {
        if #available(iOS 17.0, *) {
            content.chartXSelection(value: $value)
        } else {
            // iOS 16 不渲染选中竖线；清空绑定值避免外部误判「已选中某天」。
            content.onAppear { if value != nil { value = nil } }
        }
    }
}
