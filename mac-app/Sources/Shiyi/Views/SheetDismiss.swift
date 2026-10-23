import AppKit
import SwiftUI

/// 点击弹窗（sheet）以外的区域就关闭。
/// macOS 的 sheet 是「窗口级模态」：系统没有提供点外面关闭的开关（只有 popover 是点外面自动关）。
/// 这里用本地鼠标事件监听：sheet 弹出期间，点击落在它的父窗口上（被模态挡住、本来只会「咚」一声）就视为点了外面。
/// 弹窗里再弹的 popover / 菜单是独立窗口，不受影响；叠了多层 sheet 时只关最上面一层。
extension View {
    func dismissOnOutsideClick() -> some View {
        modifier(OutsideClickDismiss())
    }
}

private struct OutsideClickDismiss: ViewModifier {
    @Environment(\.dismiss) private var dismiss

    func body(content: Content) -> some View {
        content.background(OutsideClickMonitor(onOutsideClick: { dismiss() }))
    }
}

private struct OutsideClickMonitor: NSViewRepresentable {
    let onOutsideClick: () -> Void

    func makeNSView(context: Context) -> MonitorView {
        let v = MonitorView()
        v.onOutsideClick = onOutsideClick
        return v
    }

    func updateNSView(_ v: MonitorView, context: Context) {
        v.onOutsideClick = onOutsideClick
    }
}

private final class MonitorView: NSView {
    var onOutsideClick: (() -> Void)?
    private var monitor: Any?
    private var armedAt = Date.distantFuture

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeMonitor()
        guard window != nil else { return }
        // 刚弹出的一小会儿不响应，避免把打开它的那一下点击算进去
        armedAt = Date().addingTimeInterval(0.4)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] e in
            self?.handle(e)
            return e
        }
    }

    private func handle(_ e: NSEvent) {
        guard Date() >= armedAt,
              let sheet = window, let parent = sheet.sheetParent,
              e.window === parent,
              sheet.attachedSheet == nil else { return }
        DispatchQueue.main.async { [weak self] in self?.onOutsideClick?() }
    }

    private func removeMonitor() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
    }

    deinit {
        if let m = monitor { NSEvent.removeMonitor(m) }
    }
}
