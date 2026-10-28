import AppKit
import SwiftUI

/// 设置窗口里的「猛犸麦克风」页:动画发射器 + 完整的按键映射。
/// 版式和其他设置页一致(系统原生分组表单),顶部的发射器展示卡保持原样。
struct MicSettingsPane: View {
    @ObservedObject private var engine = MicEngine.shared
    @ObservedObject private var settings = MicSettingsStore.shared
    @StateObject private var ui = MicUIModel()

    var body: some View {
        Form {
            MicConfigPane()
        }
        .formStyle(.grouped)
        .environmentObject(engine)
        .environmentObject(settings)
        .environmentObject(ui)
        .onChange(of: engine.lastGesture) { _, g in
            if let g { ui.flash(g.kind) }
        }
    }
}
