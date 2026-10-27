import AppKit
import SwiftUI

/// 设置窗口里的「猛犸麦克风」页:动画发射器 + 完整的按键映射,直接嵌在设置窗口里,随窗口大小自适应。
struct MicSettingsPane: View {
    @ObservedObject private var engine = MicEngine.shared
    @ObservedObject private var settings = MicSettingsStore.shared
    @StateObject private var ui = MicUIModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                MicHeroPanel(compact: true)
                    .frame(height: 250)
                MicConfigPane()
            }
            .padding(24)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .environmentObject(engine)
        .environmentObject(settings)
        .environmentObject(ui)
        .onAppear {
            // 手势卡片的入场动画;每次进入这一页都重放
            ui.appeared = false
            DispatchQueue.main.async { ui.appeared = true }
        }
        .onChange(of: engine.lastGesture) { _, g in
            if let g { ui.flash(g.kind) }
        }
    }
}
