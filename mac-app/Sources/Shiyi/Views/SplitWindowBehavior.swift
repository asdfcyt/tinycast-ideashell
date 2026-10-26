import AppKit
import SwiftUI

/// 主窗口的侧边栏行为（和系统日历一样，不挤压右边的内容）：
/// - 窗口缩到放不下「侧边栏 + 内容最小宽度」时，自动把侧边栏收起来，内容区保持最小宽度以上；
/// - 窗口太窄时点侧边栏按钮，窗口向外（优先向左）长出一个侧边栏的宽度，内容区宽度不变；
/// - 之后再点按钮收起，窗口缩回原来的宽度。
struct SplitWindowBehavior: ViewModifier {
    @Binding var visibility: NavigationSplitViewVisibility
    /// 内容区（右边）的最小宽度
    let detailMin: CGFloat
    /// 侧边栏展开时的宽度
    let sidebarWidth: CGFloat

    @State private var window: NSWindow?
    @State private var expandedBy: CGFloat = 0
    @State private var shiftedLeft = false
    @State private var shiftedBy: CGFloat = 0
    /// 正在由我们自己改窗口 / 侧边栏：期间的尺寸变化不再触发自动收起
    @State private var busy = false

    func body(content: Content) -> some View {
        content
            .background(WindowGrabber { w in
                if window !== w { window = w }
                DispatchQueue.main.async { checkWidth() }
            })
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResizeNotification)) { n in
                guard let w = n.object as? NSWindow, w === window else { return }
                checkWidth()
            }
            .onChange(of: visibility) { _, new in visibilityChanged(shown: new != .detailOnly) }
    }

    private func checkWidth() {
        guard let w = window, !busy, visibility != .detailOnly else { return }
        if w.frame.width < detailMin + sidebarWidth - 0.5 {
            lock(for: 0.4)
            expandedBy = 0
            visibility = .detailOnly
        }
    }

    private func visibilityChanged(shown: Bool) {
        guard !busy, let w = window else { return }
        if shown {
            guard w.frame.width < detailMin + sidebarWidth - 0.5 else { return }
            // 太窄放不下：窗口向外长出侧边栏的宽度
            lock(for: 0.5)
            var f = w.frame
            let screen = (w.screen ?? NSScreen.main)?.visibleFrame ?? f
            // 先尽量向左长（侧边栏本来就在左边）；左边屏幕空间不够的那一部分才向右补
            let leftRoom = max(0, min(sidebarWidth, f.minX - screen.minX))
            f.size.width += sidebarWidth
            f.origin.x -= leftRoom
            if f.maxX > screen.maxX { f.origin.x = max(screen.minX, screen.maxX - f.width) }
            expandedBy = sidebarWidth
            shiftedLeft = leftRoom > 0
            shiftedBy = leftRoom
            animate(w, to: f)
        } else if expandedBy > 0 {
            lock(for: 0.5)
            var f = w.frame
            f.size.width = max(f.width - expandedBy, w.minSize.width)
            if shiftedLeft { f.origin.x += shiftedBy }
            expandedBy = 0
            animate(w, to: f)
        }
    }

    /// 窗口用我们自己的时长和缓动动画（系统默认的 setFrame 动画时长随尺寸变，和侧边栏的展开节奏对不上，会显得一顿一顿）
    private func animate(_ w: NSWindow, to f: NSRect) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.24
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            ctx.allowsImplicitAnimation = true
            w.animator().setFrame(f, display: true)
        }
    }

    private func lock(for seconds: TimeInterval) {
        busy = true
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { busy = false }
    }
}

/// 拿到所在的 NSWindow
private struct WindowGrabber: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { onWindow(nsView.window) }
    }
}
