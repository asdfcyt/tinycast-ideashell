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
            CheapMeasureLayout {
                MainWindowHost().environmentObject(model)
            }
            .frame(minWidth: 900, maxWidth: .infinity, minHeight: 600, maxHeight: .infinity)
            .task { model.start() }
        }
        .defaultSize(width: 1120, height: 720)
        .commands { AppCommands(model: model) }

        // 设置：独立的弹出窗口（⌘,），左边分类导航、右边内容
        Window("设置", id: "settings") {
            SettingsRoot().environmentObject(model)
        }
        .defaultSize(width: 880, height: 620)

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
            .onAppear {
                MainWindow.opener = { openWindow(id: "main") }
                SettingsWindow.opener = { openWindow(id: "settings") }
            }
    }
}

/// 主窗口的 NSHostingView 会在每个布局周期里重新测量「最小 / 最大 / 理想尺寸」（NSHostingView.minSize → sizeThatFits）：
/// 默认的容器要把整棵页面树（含 ScrollView 里的全部内容、ViewThatFits 的两套排版）再量一遍，
/// 页面里任何一处刷新（每秒的专注计时、悬停、数据回来）都会触发 —— 这是 CPU 忽高忽低的主因。
/// 这个容器报告尺寸时直接用上面给的提议，不去量里面的内容；真正排版（放置子视图）时才用提议的大小布局。
private struct CheapMeasureLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        // 「无限」的提议（量最大尺寸时）换成一个足够大的有限值：窗口等于不设上限
        func pick(_ v: CGFloat?) -> CGFloat { guard let v else { return 0 }; return v.isFinite ? v : 100_000 }
        return CGSize(width: pick(proposal.width), height: pick(proposal.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for v in subviews {
            v.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
        }
    }
}
