import AppKit
import SwiftUI

/// 小票浮层的内容：（可选的终端）+ 从出纸口一点点「打印」出来的小票 + 保存 / 复制按钮
struct TicketOverlay: View {
    let c: Celebration
    /// 灵动岛模式下由岛扮演终端；其它情况下面板自带一个
    let showTerminal: Bool
    let onClose: () -> Void
    let onHover: (Bool) -> Void

    @State private var printed = false
    @State private var ticketH: CGFloat = 420
    @State private var savedURL: URL?
    @State private var copied = false
    @State private var failed = false

    /// 面板和灵动岛展开时一样宽（400）；小票比终端窄一圈
    static let ticketWidth: CGFloat = 350
    static let width: CGFloat = 400
    static let sidePad: CGFloat = (width - ticketWidth) / 2

    var body: some View {
        VStack(spacing: 0) {
            if showTerminal {
                TicketTerminalView(c: c, onClose: onClose)
                    .padding(.horizontal, 14).padding(.bottom, -6)
                    .zIndex(1)
            }
            // 裁剪区：小票从上沿外面滑下来，上沿始终藏在出纸口后面
            VStack(spacing: 10) {
                ResultTicketView(c: c, width: Self.ticketWidth)
                    .shadow(color: .black.opacity(0.32), radius: 12, y: 7)
                    .background(GeometryReader { g in Color.clear.onAppear { ticketH = g.size.height } })
                    .onTapGesture { onClose() }
                // 保存 / 复制 / 收起跟小票连在一起，一起从出纸口滑出来（以前要等小票停稳再淡入，看起来像后补的）
                actions
            }
            .padding(.horizontal, Self.sidePad).padding(.top, 2).padding(.bottom, 22)
            .offset(y: printed ? 0 : -(ticketH + 40))
            .frame(maxWidth: .infinity, alignment: .top)
            .clipped()
        }
        .frame(width: Self.width)
        .onHover(perform: onHover)
        .task {
            try? await Task.sleep(nanoseconds: 450_000_000)
            TicketController.shared.playPrintSound()
            withAnimation(.timingCurve(0.1, 0.55, 0.2, 1, duration: 1.1)) { printed = true }
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            pill(savedURL == nil ? "square.and.arrow.down" : "folder", savedURL == nil ? "保存图片" : "在 Finder 中显示") {
                if let u = savedURL { NSWorkspace.shared.activateFileViewerSelecting([u]); return }
                if let u = TicketExporter.save(c) { savedURL = u; failed = false } else { failed = true }
            }
            pill(copied ? "checkmark" : "doc.on.doc", copied ? "已复制" : "复制") {
                copied = TicketExporter.copy(c)
            }
            pill("xmark", "收起", prominent: false) { onClose() }
        }
        .overlay(alignment: .bottom) {
            if failed { Text("保存失败").font(.caption2).foregroundStyle(.red).offset(y: 18) }
        }
    }

    private func pill(_ icon: String, _ label: String, prominent: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 10, weight: .bold))
                Text(label).font(.system(size: 11.5, weight: .semibold))
            }
            .foregroundStyle(.white.opacity(prominent ? 0.95 : 0.7))
            .padding(.horizontal, 12).frame(height: 26)
            .background(Color.black.opacity(0.62), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

private final class TicketPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// 番茄完成后的小票浮层。
/// - 灵动岛模式：岛左右拉宽成「专注终端」，小票在岛里面打印（见 IslandFocusDone.swift），不走这里
/// - 其它情况（提前结束、岛被占用、没开灵动岛）：自带一个终端，出现在屏幕右上角（灵动岛模式没弹岛时在顶部中间）
@MainActor
final class TicketController {
    static let shared = TicketController()

    static let enabledKey = "focus.ticket"
    static let soundKey = "focus.ticketSound"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [enabledKey: true, soundKey: true])
    }

    /// 小票停留多久（鼠标放在上面时不计时）；想看多久看多久，点「收起」或小票才消失
    static let life: TimeInterval = 120

    var isShowing: Bool { panel != nil }

    static var enabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    private var panel: TicketPanel?
    private var hovering = false
    private var hideTimer: Timer?
    private var shownAt = Date()
    private var current: Celebration?

    var frame: NSRect? { panel?.frame }

    func contains(_ p: NSPoint, margin: CGFloat = 8) -> Bool {
        guard let f = panel?.frame else { return false }
        return f.insetBy(dx: -margin, dy: -margin).contains(p)
    }

    func present(_ c: Celebration) {
        guard Self.enabled else { return }
        // 走完的番茄：岛自己把小票打印在岛里；岛让不出来（正在用小组件 / 投放）才退回独立浮层
        if c.completed, IslandController.shared.presentFocusDone(c) { return }
        show(c)
    }

    func playPrintSound() {
        guard UserDefaults.standard.bool(forKey: Self.soundKey) else { return }
        NSSound(named: "Glass")?.play()
    }

    private func show(_ c: Celebration) {
        hide()
        current = c
        hovering = false
        shownAt = Date()

        let view = TicketOverlay(c: c, showTerminal: true, onClose: { [weak self] in self?.hide() },
                                 onHover: { [weak self] in self?.hovering = $0 })
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: TicketOverlay.width, height: 600)
        let size = NSSize(width: TicketOverlay.width, height: max(host.fittingSize.height, 200))
        host.sizingOptions = []
        host.safeAreaRegions = []

        let p = TicketPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        // 比灵动岛低一层：小票从岛的下面钻出来
        p.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2)
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.animationBehavior = .none
        p.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        panel = p

        p.setFrame(placement(size: size), display: false)
        p.orderFrontRegardless()
        startTimer(life: Self.life)
    }

    private func placement(size: NSSize) -> NSRect {
        let s = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens[0]
        let vf = s.visibleFrame
        let centered = DisplayMode.current == .island
        let x = centered ? s.frame.midX - size.width / 2 : vf.maxX - size.width - 6
        return NSRect(x: x, y: vf.maxY - size.height - 6, width: size.width, height: size.height)
    }

    private func startTimer(life: TimeInterval) {
        hideTimer?.invalidate()
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.hovering { self.shownAt = max(self.shownAt, Date().addingTimeInterval(-life + 30)); return }
                if Date().timeIntervalSince(self.shownAt) > life { self.hide() }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        hideTimer = t
    }

    func hide() {
        hideTimer?.invalidate(); hideTimer = nil
        current = nil
        if let p = panel {
            panel = nil
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.22
                p.animator().alphaValue = 0
            }, completionHandler: { p.orderOut(nil); p.contentView = nil })
        }
    }
}

/// 专注页里小票下面的按钮：保存图片 / 复制 / 收起（浅色背景上用系统样式）
struct TicketActions: View {
    let c: Celebration
    var showClose = true
    let onClose: () -> Void
    @State private var savedURL: URL?
    @State private var copied = false
    @State private var failed = false

    var body: some View {
        HStack(spacing: 8) {
            Button {
                if let u = savedURL { NSWorkspace.shared.activateFileViewerSelecting([u]); return }
                if let u = TicketExporter.save(c) { savedURL = u; failed = false } else { failed = true }
            } label: {
                Label(savedURL == nil ? "保存图片" : "在 Finder 中显示", systemImage: savedURL == nil ? "square.and.arrow.down" : "folder")
            }
            Button { copied = TicketExporter.copy(c) } label: {
                Label(copied ? "已复制" : "复制", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            if showClose { Button(action: onClose) { Label("收起", systemImage: "xmark") } }
        }
        .buttonStyle(.bordered).controlSize(.small)
        if failed { Text("保存失败，请检查「图片」文件夹的权限").font(.caption2).foregroundStyle(.red) }
    }
}
