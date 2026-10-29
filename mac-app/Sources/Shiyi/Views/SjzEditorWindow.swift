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
            .environmentObject(model)
        let host = NSHostingController(rootView: root)
        host.sizingOptions = []
        let w = NSWindow(contentViewController: host)
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        w.title = "\(capture.kindLabel) · \(capture.id)"
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

extension AppModel {
    /// 在可拖动、可缩放的独立窗口里编辑一条结审记录
    func openSjzEditor(project: String, capture: SjzCapture) {
        sjzQuick = nil
        SjzEditorWindows.shared.open(model: self, project: project, capture: capture)
    }
}
