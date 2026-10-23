import AppKit
import SwiftUI

@main
struct ShiyiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()
    /// 小组件的呈现方式：状态栏图标 / 灵动岛（在设置里切换）
    @AppStorage(DisplayMode.key) private var displayMode: DisplayMode = .menuBar

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        MainActor.assumeIsolated {
            Notifier.shared.setup()
            TicketController.registerDefaults()
        }
    }

    var body: some Scene {
        Window("拾忆", id: "main") {
            MainWindowHost()
                .environmentObject(model)
                .frame(minWidth: 900, minHeight: 600)
                .task { model.start() }
        }
        .defaultSize(width: 1120, height: 720)

        // 灵动岛模式下不插入菜单栏图标；灵动岛由 IslandController 在 model.start() 里按设置启停
        // set 故意留空：MenuBarExtra 会把状态项的可见性回写进来，写回 AppStorage 会和 body 重算形成死循环
        MenuBarExtra(isInserted: Binding(
            get: { displayMode == .menuBar },
            set: { _ in }
        )) {
            MenuBarView().environmentObject(model)
        } label: {
            MenuBarLabel().environmentObject(model)
        }
        .menuBarExtraStyle(.window)
    }
}

/// 主窗口内容；顺便把 openWindow 交给 MainWindow，灵动岛 / 菜单栏弹窗都能用它重新打开主窗口
private struct MainWindowHost: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        RootView()
            .onAppear { MainWindow.opener = { openWindow(id: "main") } }
    }
}
