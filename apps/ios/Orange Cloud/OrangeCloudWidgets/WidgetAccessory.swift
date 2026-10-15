//
//  WidgetAccessory.swift
//  OrangeCloudWidgets
//
//  锁屏 accessory 家族的公共件：
//  - DaybreakBackground：系统家族铺晨昏天空，锁屏 accessory 留给系统的半透明底
//    （accessory 在锁屏走 vibrant 渲染，彩色天空不会显示，强行铺底反而糊）
//  - AccessorySparkline：单色归一化折线，vibrant 模式下用前景色描边即可见
//

import WidgetKit
import SwiftUI

// MARK: - 容器背景（按家族切换）

/// 系统家族 = 晨昏天空；accessory 家族 = 透明（交给锁屏系统底）。
/// 只列举系统家族 + default，避免在 iOS target 里直接引用 watchOS 专属的
/// `.accessoryCorner`（该 case 在 iOS 不可用，具名引用会编译失败）。
///
/// iOS 16 基线适配：`containerBackground(for: .widget)` 是 iOS 17 才有的 API，
/// 且**必须**用它承载背景——iOS 17 起 Widget 视图的 `background` 会被系统忽略。
/// iOS 16 上系统仍然尊重 `background`，所以两个分支不能共用同一个修饰符。
struct DaybreakBackground: ViewModifier {

    @Environment(\.widgetFamily) private var family
    let date: Date

    func body(content: Content) -> some View {
        if #available(iOS 17.0, *) {
            systemFamilyBackground(content)
        } else {
            legacyBackground(content)
        }
    }

    @ViewBuilder
    private func systemFamilyBackground(_ content: Content) -> some View {
        switch family {
        case .systemSmall, .systemMedium, .systemLarge, .systemExtraLarge:
            content.containerBackground(for: .widget) { WidgetSky(date: date) }
        default:
            content.containerBackground(.clear, for: .widget)
        }
    }

    /// iOS 16：系统仍读 `background`，且 Widget 自带边距，背景要往内缩一点才不被裁。
    @ViewBuilder
    private func legacyBackground(_ content: Content) -> some View {
        switch family {
        case .systemSmall, .systemMedium, .systemLarge, .systemExtraLarge:
            content.background { WidgetSky(date: date) }
        default:
            content
        }
    }
}

extension View {
    /// 容器背景：系统家族铺晨昏天空，锁屏 accessory 透明
    func daybreakContainer(date: Date) -> some View {
        modifier(DaybreakBackground(date: date))
    }
}

// MARK: - 迷你折线（accessoryRectangular）

/// 把 24h 序列归一化成一条平滑折线。锁屏 vibrant 下用 `.foreground` 描边，
/// 配合 `.widgetAccentable()` 可被用户的着色染色。
struct AccessorySparkline: View {

    var series: [Int]
    var lineWidth: CGFloat = 1.6

    var body: some View {
        GeometryReader { geo in
            let points = normalizedPoints(in: geo.size)
            if points.count > 1 {
                WidgetDial.smoothPath(points)
                    .stroke(
                        .foreground,
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
                    )
            }
        }
        .accessibilityHidden(true)
    }

    private func normalizedPoints(in size: CGSize) -> [CGPoint] {
        guard series.count > 1 else { return [] }
        let maxValue = series.max() ?? 1
        let minValue = series.min() ?? 0
        let span = CGFloat(max(maxValue - minValue, 1))
        let lastIndex = CGFloat(series.count - 1)
        let inset = lineWidth / 2
        let usableHeight = max(size.height - lineWidth, 1)
        return series.enumerated().map { index, value in
            let x = CGFloat(index) / lastIndex * size.width
            let y = inset + (1 - CGFloat(value - minValue) / span) * usableHeight
            return CGPoint(x: x, y: y)
        }
    }
}
