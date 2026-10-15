//
//  OrangeCloudControlWidget.swift
//  OrangeCloudWidgets
//
//  控制中心按钮（iOS 18 ControlWidget）：一键打开 Orange Cloud。
//
//  iOS 16 基线适配：整份实现保持 `@available(iOS 18.0, *)` 门控 + Bundle 内
//  `if #available(iOS 18.0, *)` 分支注册，iOS 16 上整个类型不参与运行。
//  编译期也无碍：`ControlWidget` / `StaticControlConfiguration` / `ControlWidgetButton`
//  全是 iOS 18 才有的符号，但 `@available` 会让编译器把它们在低版本 target 下的
//  使用降级为「不可用」而非报错——因为该类型的引用点本身也被同一注解保护。
//  底下的 `LaunchOrangeCloudIntent` 则是 iOS 16 就有的 `AppIntent`，无需门控，
//  Bundle 里也只有 ControlWidget 引用它。
//

import WidgetKit
import SwiftUI
import AppIntents

@available(iOS 18.0, *)
struct OrangeCloudControlWidget: ControlWidget {

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "OrangeCloudControlWidget") {
            ControlWidgetButton(action: LaunchOrangeCloudIntent()) {
                Label("Orange Cloud", systemImage: "cloud.fill")
            }
        }
        .displayName("打开 Orange Cloud")
        .description("快速打开 Cloudflare 管理")
    }
}

/// 从控制中心启动主 App
nonisolated struct LaunchOrangeCloudIntent: AppIntent {
    static let title: LocalizedStringResource = "打开 Orange Cloud"
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        .result()
    }
}
