import SwiftUI
import AppKit

/// 结审记录的编辑窗口：独立的 NSWindow，可以拖动、缩放、最小化
/// （SwiftUI 的 .sheet 在 macOS 上既不能拖也不能改大小，所以这里自己开窗口）。同一条记录只开一个，再点会把已有的窗口提到前面。
@MainActor
final class SjzEditorWindows: NSObject, NSWindowDelegate {
    static let shared = SjzEditorWindows()
    private var wins: [String: NSWindow] = [:]

    func isEditorWindow(_ w: NSWindow?) -> Bool {
        guard let w else { return false }
        return wins.values.contains { $0 === w }
    }

    func open(model: AppModel, project: String, capture: SjzCapture) {
        let key = "\(project)|\(capture.id)"
        if let w = wins[key] {
            if w.isMiniaturized { w.deminiaturize(nil) }
            w.makeKeyAndOrderFront(nil)
            return
        }
        let root = SjzCaptureEditor(project: project, capture: capture,
                                    onDone: { NotificationCenter.default.post(name: .sjzCapturesChanged, object: nil) },
                                    onClose: { [weak self] in self?.close(key) })
            .ignoresSafeArea(.container, edges: .top)
            .environmentObject(model)
        let host = NSHostingController(rootView: root)
        host.sizingOptions = []
        let w = NSWindow(contentViewController: host)
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        w.title = "\(capture.kindLabel) · \(capture.id)"
        // 标题栏透明、不显示文字，内容铺到最上面，和红黄绿按钮同一层；空白处可以拖动
        w.styleMask.insert(.fullSizeContentView)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        w.contentMinSize = NSSize(width: 600, height: 460)
        w.setContentSize(NSSize(width: 720, height: 700))
        w.delegate = self
        // 已经开着别的编辑窗口时错开一点，避免完全叠在一起
        if let last = wins.values.first(where: { $0.isVisible }) {
            w.setFrameTopLeftPoint(NSPoint(x: last.frame.minX + 26, y: last.frame.maxY - 26))
        } else if let main = NSApp.mainWindow ?? NSApp.keyWindow {
            let f = main.frame
            w.setFrameOrigin(NSPoint(x: f.midX - w.frame.width / 2, y: max(40, f.midY - w.frame.height / 2)))
        } else {
            w.center()
        }
        wins[key] = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close(_ key: String) {
        guard let w = wins[key] else { return }
        w.close()
    }

    func windowWillClose(_ notification: Notification) {
        guard let w = notification.object as? NSWindow, let k = wins.first(where: { $0.value === w })?.key else { return }
        wins[k] = nil
    }
}

/// 垫在标题条后面的拖动区：按住就拖动整个窗口，双击放大 / 还原（按钮盖在它上面，各管各的）
struct WindowDragArea: NSViewRepresentable {
    private final class V: NSView {
        override var mouseDownCanMoveWindow: Bool { false }
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 { window?.performZoom(nil) } else { window?.performDrag(with: event) }
        }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }
    func makeNSView(context: Context) -> NSView { V() }
    func updateNSView(_ v: NSView, context: Context) {}
}

/// 拿到所在的 NSWindow（用来在打开并排预览时把窗口拉宽）
struct WinGrab: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { if let w = v.window { onWindow(w) } }
        return v
    }
    func updateNSView(_ v: NSView, context: Context) {
        if let w = v.window { DispatchQueue.main.async { onWindow(w) } }
    }
}

/// 快速预览窗口：独立窗口，可拖动、缩放；空格 / Esc 关闭，回车转到编辑。同一条记录只开一个，再按空格就关掉
@MainActor
final class SjzPreviewWindows: NSObject, NSWindowDelegate {
    static let shared = SjzPreviewWindows()
    private var wins: [String: NSWindow] = [:]
    private var items: [String: (project: String, capture: SjzCapture)] = [:]
    private var monitor: Any?
    private weak var model: AppModel?

    func isPreviewWindow(_ w: NSWindow?) -> Bool { w.map { x in wins.values.contains { $0 === x } } ?? false }

    private func key(_ project: String, _ id: String) -> String { "\(project)|\(id)" }

    @discardableResult
    func closeIfOpen(project: String, id: String) -> Bool {
        guard let w = wins[key(project, id)] else { return false }
        w.close()
        return true
    }

    func open(model: AppModel, project: String, capture: SjzCapture) {
        self.model = model
        let k = key(project, capture.id)
        if let w = wins[k] {
            if w.isMiniaturized { w.deminiaturize(nil) }
            w.makeKeyAndOrderFront(nil)
            return
        }
        let root = SjzQuickLook(api: model.sjz, project: project, capture: capture, windowed: true,
                                onClose: { [weak self] in self?.wins[k]?.close() },
                                onEdit: { [weak self] in
                                    // 先打开编辑窗口，再（下一轮）关掉预览：不在按钮自己的点击回调里销毁它所在的窗口
                                    model.openSjzEditor(project: project, capture: capture)
                                    DispatchQueue.main.async { self?.wins[k]?.close() }
                                })
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
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        w.title = capture.isSummary ? "预览 · \(capture.title)" : "预览 · \(capture.kindLabel) \(capture.id)"
        // 去掉独立的标题栏：标题栏透明、不显示文字，内容和窗口按钮同一层，空白处可以拖动
        w.styleMask.insert(.fullSizeContentView)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        // 只有顶部那一条（WindowDragArea）可以拖动窗口，免得和标题栏里的按钮抢点击
        w.isMovableByWindowBackground = false
        // 系统的红黄绿三个按钮不要：关闭按钮由内容里自己画
        for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { w.standardWindowButton(b)?.isHidden = true }
        w.isReleasedWhenClosed = false
        w.contentMinSize = NSSize(width: 440, height: 340)
        w.setContentSize(NSSize(width: 720, height: 640))
        w.delegate = self
        if let last = wins.values.first(where: { $0.isVisible }) {
            w.setFrameTopLeftPoint(NSPoint(x: last.frame.minX + 26, y: last.frame.maxY - 26))
        } else if let main = NSApp.mainWindow ?? NSApp.keyWindow {
            let f = main.frame
            w.setFrameOrigin(NSPoint(x: f.midX - w.frame.width / 2, y: max(40, f.midY - w.frame.height / 2)))
        } else {
            w.center()
        }
        wins[k] = w
        items[k] = (project, capture)
        installMonitor()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func installMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] ev in
            guard let self, let w = ev.window, let k = self.wins.first(where: { $0.value === w })?.key,
                  ev.modifierFlags.intersection([.command, .option, .control]).isEmpty, !(w.firstResponder is NSText) else { return ev }
            switch ev.keyCode {
            case 49, 53: if !ev.isARepeat { w.close() }; return nil
            case 36, 76:
                if let it = self.items[k], !it.capture.isSummary { w.close(); self.model?.openSjzEditor(project: it.project, capture: it.capture) }
                return nil
            default: return ev
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard let w = notification.object as? NSWindow, let k = wins.first(where: { $0.value === w })?.key else { return }
        wins[k] = nil
        items[k] = nil
        if wins.isEmpty, let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }
}

extension AppModel {
    /// 快速预览：独立的访达风窗口，可拖动、缩放
    func openSjzPreview(project: String, capture: SjzCapture) {
        SjzPreviewWindows.shared.open(model: self, project: project, capture: capture)
    }

    /// 空格：已经开着就关，没开就打开
    func toggleSjzPreview(project: String, capture: SjzCapture) {
        if SjzPreviewWindows.shared.closeIfOpen(project: project, id: capture.id) { return }
        openSjzPreview(project: project, capture: capture)
    }

    /// 在可拖动、可缩放的独立窗口里编辑一条结审记录
    func openSjzEditor(project: String, capture: SjzCapture) {
        sjzQuick = nil
        SjzEditorWindows.shared.open(model: self, project: project, capture: capture)
    }
}
