//
//  WatermarkBatchApp.swift
//  WatermarkBatch（水印工坊 BatchMark）
//
//  块C · @main 入口：创建全局 AppModel 并注入环境；深色优先、简体中文。
//  无网络权限、无第三方 SDK、无账号体系——纯本地工具。
//

import SwiftUI

@main
@MainActor
struct WatermarkBatchApp: App {

    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environment(model)
                .preferredColorScheme(.dark)
                .environment(\.locale, Locale(identifier: "zh_CN"))
                .tint(Color(red: 0.36, green: 0.75, blue: 0.98))
        }
    }
}
