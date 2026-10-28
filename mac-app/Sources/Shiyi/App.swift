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
            .frame(minWidth: 760, maxWidth: .infinity, minHeight: 600, maxHeight: .infinity)
            .task { model.start() }
            .onOpenURL { model.handleDeepLink($0) }
        }
        .defaultSize(width: 1120, height: 720)
        .commands { AppCommands(model: model) }

        // 设置：独立的弹出窗口（⌘,），左边分类导航、右边内容
        Window("设置", id: "settings") {
            SettingsRoot().environmentObject(model)
        }
        .defaultSize(width: SettingsRoot.fixedWidth, height: 620)
        .windowResizability(.contentSize)

        // 灵动岛模式下不插入菜单栏图标；灵动岛由 IslandController 在 model.start() 里按设置启停
        // set 故意留空：MenuBarExtra 会把状态项的可见性回写进来，写回 AppStorage 会和 body 重算形成死循环
        MenuBarExtra(isInserted: Binding(
            get: { displayMode == .menuBar },
            set: { _ in }
        )) {
            MenuBarView().environmentObject(model).tint(Brand.orange)
        } label: {
            MenuBarLabel().environmentObject(model)
        }
        .menuBarExtraStyle(.window)
    }
}

/// 主窗口内容；顺便把 openWindow 交给 MainWindow，灵动岛 / 菜单栏弹窗都能用它重新打开主窗口。
/// 窗口关掉（或最小化）后整棵页面树卸掉：后台只剩计时和灵动岛时，每秒一次的专注计时、开始 / 结束专注都不该去重算看不见的页面
/// （以前关着窗口也会重算整个「今天」页，点灵动岛的「开始专注」时正好压在展开动画上，是卡顿的主因）。
private struct MainWindowHost: View {
    @Environment(\.openWindow) private var openWindow
    @State private var shown = true

    var body: some View {
        Group {
            if shown {
                RootView().tint(Brand.orange)
            } else {
                Color(nsColor: .windowBackgroundColor)
            }
        }
        .background(WindowShownProbe(shown: $shown))
        .onAppear {
            MainWindow.opener = { openWindow(id: "main") }
            SettingsWindow.opener = { openWindow(id: "settings") }
        }
    }
}

/// 盯着所在窗口：关闭 / 最小化时 shown = false，重新显示时 shown = true
private struct WindowShownProbe: NSViewRepresentable {
    @Binding var shown: Bool

    func makeNSView(context: Context) -> Probe {
        let p = Probe()
        p.onChange = { v in if shown != v { shown = v } }
        return p
    }

    func updateNSView(_ nsView: Probe, context: Context) {
        nsView.onChange = { v in if shown != v { shown = v } }
    }

    final class Probe: NSView {
        var onChange: ((Bool) -> Void)?
        private var tokens: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            tokens.forEach(NotificationCenter.default.removeObserver)
            tokens = []
            guard let w = window else { return }
            let nc = NotificationCenter.default
            func on(_ n: Notification.Name, _ v: Bool) {
                tokens.append(nc.addObserver(forName: n, object: w, queue: .main) { [weak self] _ in self?.onChange?(v) })
            }
            on(NSWindow.willCloseNotification, false)
            on(NSWindow.didMiniaturizeNotification, false)
            on(NSWindow.didDeminiaturizeNotification, true)
            on(NSWindow.didBecomeKeyNotification, true)
            on(NSWindow.didBecomeMainNotification, true)
        }

        deinit { tokens.forEach(NotificationCenter.default.removeObserver) }
    }
}

/// 主窗口的 NSHostingView 会在每个布局周期里重新测量「最小 / 最大 / 理想尺寸」（NSHostingView.minSize → sizeThatFits）：
/// 默认的容器要把整棵页面树（含 ScrollView 里的全部内容、ViewThatFits 的两套排版）再量一遍，
/// 页面里任何一处刷新（每秒的专注计时、悬停、数据回来）都会触发 —— 这是 CPU 忽高忽低的主因。
/// 这个容器报告尺寸时直接用上面给的提议，不去量里面的内容；真正排版（放置子视图）时才用提议的大小布局。
struct CheapMeasureLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        // 「无限」的提议（量最大尺寸时）换成一个足够大的有限值：窗口等于不设上限
        func pick(_ v: CGFloat?) -> CGFloat { guard let v else { return 0 }; return v.isFinite ? v : 100_000 }
        return CGSize(width: pick(proposal.width), height: pick(proposal.height))
    }

    /// 默认的 explicitAlignment 会为了找对齐线把子视图整个布局一遍（量最小尺寸时每次都来），这里直接说「没有」
    func explicitAlignment(of guide: HorizontalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGFloat? { nil }
    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGFloat? { nil }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for v in subviews {
            v.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
        }
    }
}
