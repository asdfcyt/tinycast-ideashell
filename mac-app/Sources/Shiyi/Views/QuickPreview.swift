import AppKit
import SwiftUI

/// 日历里的「预览」：和结审记录的空格预览一样的独立浮窗——半透明磨砂底、可拖动、可缩放，
/// 空格 / Esc 关闭，回车（或右上角「打开」）转到完整页面。全局只有一个：开着的时候再点别的条目，只换里面的内容。
@MainActor
final class QuickPreviewState: ObservableObject {
    @Published var page: SheetPage?
}

extension AppModel {
    /// 日历右侧时间河里单击一行：只选中；预览窗口开着就让它跟着换
    func riverSelect(_ page: SheetPage, entry: String? = nil) {
        calPane.select(page, entry: entry)
        if QuickPreviewWindow.shared.isVisible { QuickPreviewWindow.shared.show(page, model: self) }
    }

    /// 选中并弹出预览
    func riverPreview(_ page: SheetPage, entry: String? = nil) {
        calPane.select(page, entry: entry)
        QuickPreviewWindow.shared.show(page, model: self)
    }
}

@MainActor
final class QuickPreviewWindow: NSObject, NSWindowDelegate {
    static let shared = QuickPreviewWindow()

    private let state = QuickPreviewState()
    private var window: NSWindow?
    private var monitor: Any?
    private weak var model: AppModel?
    private static let frameName = "shiyi.quickPreview"

    var isVisible: Bool { window?.isVisible ?? false }
    func isPreviewWindow(_ w: NSWindow?) -> Bool { w != nil && w === window }

    /// 空格：已经在预览这一条就关掉，否则打开 / 换成这一条
    func toggle(_ page: SheetPage, model: AppModel) {
        if isVisible, state.page == page { close() } else { show(page, model: model) }
    }

    func show(_ page: SheetPage, model: AppModel) {
        self.model = model
        state.page = page
        if let w = window, w.isVisible {
            // 已经开着：只换内容，不抢键盘，选中的那一行继续接收空格
            if w.isMiniaturized { w.deminiaturize(nil) }
            w.orderFront(nil)
            return
        }
        let w = window ?? makeWindow(model: model)
        window = w
        installMonitor()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        window?.close()
    }

    /// 转到完整页面（弹出的详情页），预览关掉
    private func pop() {
        guard let page = state.page, let model else { return }
        close()
        MainWindow.show()
        model.present(page)
    }

    private func makeWindow(model: AppModel) -> NSWindow {
        let root = QuickPreviewRoot(state: state, onClose: { [weak self] in self?.close() }, onPop: { [weak self] in self?.pop() })
            .ignoresSafeArea(.container, edges: .top)
            .environmentObject(model)
        let host = NSHostingController(rootView: root)
        host.sizingOptions = []
        // 和访达的空格预览一样：半透明磨砂底，内容透出来
        let vev = NSVisualEffectView()
        vev.material = .popover
        vev.blendingMode = .behindWindow
        vev.state = .active
        let vc = NSViewController()
        vc.view = vev
        vc.addChild(host)
        host.view.frame = vev.bounds
        host.view.autoresizingMask = [.width, .height]
        vev.addSubview(host.view)

        let w = NSWindow(contentViewController: vc)
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        w.title = "预览"
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        // 只有顶部那一条（WindowDragArea）可以拖动窗口，免得和里面的按钮抢点击
        w.isMovableByWindowBackground = false
        for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { w.standardWindowButton(b)?.isHidden = true }
        w.isReleasedWhenClosed = false
        w.contentMinSize = NSSize(width: 400, height: 320)
        w.setContentSize(NSSize(width: 560, height: 640))
        w.delegate = self
        let hadFrame = UserDefaults.standard.string(forKey: "NSWindow Frame " + Self.frameName) != nil
        w.setFrameAutosaveName(Self.frameName)
        if !hadFrame {
            if let main = NSApp.mainWindow ?? NSApp.keyWindow {
                let f = main.frame
                w.setFrameOrigin(NSPoint(x: f.midX - w.frame.width / 2, y: max(40, f.midY - w.frame.height / 2)))
            } else {
                w.center()
            }
        }
        return w
    }

    private func installMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] ev in
            guard let self, let w = self.window, ev.window === w,
                  ev.modifierFlags.intersection([.command, .option, .control]).isEmpty, !(w.firstResponder is NSText) else { return ev }
            switch ev.keyCode {
            case 49, 53: if !ev.isARepeat { self.close() }; return nil
            case 36, 76: self.pop(); return nil
            default: return ev
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        // 关掉时把里面的详情页也拆掉（不留着占内存、也不在后台继续读笔记）
        state.page = nil
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }
}

private struct QuickPreviewRoot: View {
    @ObservedObject var state: QuickPreviewState
    let onClose: () -> Void
    let onPop: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if let page = state.page {
                HStack(spacing: 10) {
                    Image(systemName: icon(page)).foregroundStyle(Brand.orange)
                    Text(label(page)).font(.callout.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Button(action: onPop) { Label("打开", systemImage: "arrow.up.left.and.arrow.down.right") }
                        .buttonStyle(.borderless)
                        .help("弹出完整页面（回车）")
                    Button(action: onClose) { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                        .help("关闭（空格 / Esc）")
                }
                .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 8)
                .background(WindowDragArea())
                Divider()
                Group {
                    switch page {
                    case let .note(r): NoteDetailView(noteId: r.id, fallbackTitle: r.fallbackTitle).id(r.id)
                    case let .task(t): TaskDetailView(task: t).id(t.id)
                    }
                }
            } else {
                Color.clear
            }
        }
    }

    private func label(_ page: SheetPage) -> String {
        switch page {
        case .note: return "笔记"
        case .task: return "待办"
        }
    }

    private func icon(_ page: SheetPage) -> String {
        switch page {
        case .note: return "doc.text"
        case .task: return "checklist"
        }
    }
}
