import AppKit
import SwiftUI

// MARK: - 悬浮窗


private final class QuickAddPanel: NSPanel {
    var onResign: (() -> Void)?
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func resignKey() {
        super.resignKey()
        onResign?()
    }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

/// 窗口不是 key 窗口时，第一下点击默认只用来激活窗口、不会点到按钮；悬浮小窗（HUD / 语音卡）要第一下就能点
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// 输入窗的内容视图：在没有被输入框 / 按钮接走的空白处按住拖动，就能移动整个窗口
/// （窗口自带的「拖背景移动」在 SwiftUI 内容上不生效，所以自己处理）。拖动时由控制器负责吸附和辅助线。
final class QuickAddHostingView<Content: View>: NSHostingView<Content> {
    var onDragMove: ((NSRect) -> NSRect)?
    var onDragEnd: (() -> Void)?
    private var mouseStart: NSPoint?
    private var frameStart: NSRect = .zero
    private var dragging = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        mouseStart = NSEvent.mouseLocation
        frameStart = window?.frame ?? .zero
        dragging = false
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let w = window, let start = mouseStart else { super.mouseDragged(with: event); return }
        let now = NSEvent.mouseLocation
        let dx = now.x - start.x, dy = now.y - start.y
        if !dragging {
            guard hypot(dx, dy) > 3 else { super.mouseDragged(with: event); return }
            dragging = true
        }
        var f = frameStart
        f.origin.x += dx
        f.origin.y += dy
        let snapped = onDragMove?(f) ?? f
        w.setFrame(snapped, display: true)
    }

    override func mouseUp(with event: NSEvent) {
        let was = dragging
        dragging = false
        mouseStart = nil
        if was { onDragEnd?() } else { super.mouseUp(with: event) }
    }
}

/// 拖动输入窗时的辅助线：铺满当前屏幕的透明窗口，画出输入窗四条边的虚线；吸附到水平居中 / 默认高度时那条线变成实线高亮
private final class GuideView: NSView {
    struct Lines {
        var card = NSRect.zero          // 输入窗卡片（屏幕坐标）
        var snapX = false               // 吸附在水平居中
        var snapY = false               // 吸附在默认高度
        var centerX: CGFloat = 0
        var topY: CGFloat = 0
    }
    var lines = Lines() { didSet { needsDisplay = true } }

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let w = window else { return }
        let o = w.frame.origin
        let c = lines.card.offsetBy(dx: -o.x, dy: -o.y)
        let b = bounds

        func stroke(_ a: NSPoint, _ z: NSPoint, solid: Bool) {
            func line(_ width: CGFloat) -> NSBezierPath {
                let path = NSBezierPath()
                path.move(to: a); path.line(to: z)
                path.lineWidth = width
                if !solid { path.setLineDash([5, 4], count: 2, phase: 0) }
                return path
            }
            // 先描一层更粗的深色淡线垫底，浅色 / 深色壁纸上都看得清
            NSColor.black.withAlphaComponent(0.18).setStroke()
            line(3).stroke()
            (solid ? NSColor.controlAccentColor : NSColor.white.withAlphaComponent(0.8)).setStroke()
            line(1).stroke()
        }

        for x in [c.minX, c.maxX] { stroke(NSPoint(x: x, y: b.minY), NSPoint(x: x, y: b.maxY), solid: false) }
        for y in [c.minY, c.maxY] { stroke(NSPoint(x: b.minX, y: y), NSPoint(x: b.maxX, y: y), solid: false) }
        if lines.snapX {
            let x = lines.centerX - o.x
            stroke(NSPoint(x: x, y: b.minY), NSPoint(x: x, y: b.maxY), solid: true)
        }
        if lines.snapY {
            let y = lines.topY - o.y
            stroke(NSPoint(x: b.minX, y: y), NSPoint(x: b.maxX, y: y), solid: true)
        }
    }
}

private final class HUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// 保存结果的小提示：一个小玻璃胶囊，不抢焦点、不挡鼠标
private struct QuickAddHUDView: View {
    let text: String
    let ok: Bool
    var undo: (() -> Void)?
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ok ? Color.green : Color.orange)
            Text(text).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            if let undo {
                Button(action: undo) {
                    Text("撤销").foregroundStyle(Brand.orange)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 12).padding(.vertical, 7)
        .frame(maxWidth: 300)
        .glassCapsule()
        .padding(8)
    }
}

private struct PanelHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// 悬浮窗里的内容：就是万能输入本体，包一层玻璃底，并把自己的高度报给控制器（内容多了窗口向下长）
private struct QuickAddPanelRoot: View {
    let onDone: () -> Void
    let onDraft: (String) -> Void
    let onKind: (CaptureKind?) -> Void
    let onSubmitted: (String) -> Void
    let onHeight: (CGFloat) -> Void

    var body: some View {
        QuickAddView(onDone: onDone, onDraftChange: onDraft, onKindChange: onKind, onSubmitted: onSubmitted)
            .glassCard(radius: 20)
            .background(GeometryReader { g in
                Color.clear.preference(key: PanelHeightKey.self, value: g.size.height)
            })
            .onPreferenceChange(PanelHeightKey.self) { h in
                guard h > 0 else { return }
                onHeight(h)
            }
            // 阴影自己画（窗口阴影会透过半透明玻璃，在暗色下出现一圈黑边）：四周留出 shadowInset 给它
            .shadow(color: .black.opacity(0.22), radius: 14, y: 6)
            .padding(QuickAddPanelController.shadowInset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - 控制器

/// 全局万能输入：在任何 App 里按下快捷键，在鼠标所在屏幕的中上部弹出一个悬浮输入窗（复用万能输入），
/// 回车保存后显示结果并自动消失。不激活本应用（原来的 App 保持前台、不会带出主窗口）；点别处或按 Esc 关闭。
/// 没保存的内容留 5 分钟：不小心点到别处，再按一次快捷键还在。
@MainActor
final class QuickAddPanelController: ObservableObject {
    static let shared = QuickAddPanelController()

    /// 热键注册失败 / 不可用的原因（设置页显示）
    @Published private(set) var registerError: String?

    private weak var model: AppModel?
    private var panel: QuickAddPanel?
    private var observer: NSObjectProtocol?
    /// 当前已按它注册（或尝试注册过）的组合：设置没变就不重复注册
    private var applied: HotkeyCombo?
    private var suspended = false

    private var draft = ""
    /// 草稿对应的手动类型（比如已经选了「想法」）：重新唤出时一起恢复，不然会变回自动识别的 Daily Note
    private var draftKind: CaptureKind?
    private var hiddenAt = Date.distantPast
    private var closeWork: DispatchWorkItem?
    private var revealPending = false
    private var shownAt = Date.distantPast
    private let width: CGFloat = 480
    /// 卡片四周给自绘阴影留的空白
    static let shadowInset: CGFloat = 24
    private var contentHeight: CGFloat = 130

    func start(model: AppModel) {
        guard observer == nil else { return }
        self.model = model
        GlobalHotkey.quickAdd.onPress = { [weak self] in self?.toggle() }
        observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.applyHotkey() }
        }
        applyHotkey()
    }

    // MARK: 热键

    private func applyHotkey() {
        guard !suspended else { return }
        let want = QuickAddHotkey.current.combo
        if want == applied { return }
        applied = want
        guard let c = want else {
            GlobalHotkey.quickAdd.unregister()
            registerError = nil
            return
        }
        if let why = c.problem(for: .quickAdd) {
            GlobalHotkey.quickAdd.unregister()
            registerError = why
            return
        }
        let ok = GlobalHotkey.quickAdd.register(keyCode: c.code, modifiers: c.mods)
        registerError = ok ? nil : "这个组合已被系统或其他 App 占用，换一个试试"
    }

    /// 设置页录制新组合时先把热键停掉，免得按下同一个组合反而弹出输入窗
    func suspendHotkey() {
        suspended = true
        applied = nil
        GlobalHotkey.quickAdd.unregister()
    }

    func resumeHotkey() {
        suspended = false
        applyHotkey()
    }

    // MARK: 显示 / 隐藏

    func toggle() {
        if let p = panel, p.isVisible { hide() } else { show() }
    }

    /// 输入窗卡片在屏幕上的位置（去掉阴影边）；没开时是 nil
    var cardFrame: NSRect? {
        guard let p = panel, p.isVisible else { return nil }
        return p.frame.insetBy(dx: Self.shadowInset, dy: Self.shadowInset)
    }

    /// 输入窗现在是否开着（语音输入据此决定：开着就把说的话听写进输入框）
    var isVisible: Bool { panel?.isVisible ?? false }

    /// 语音卡片收起后，把键盘焦点还给输入窗和输入框（语音卡片弹出时会抢走 key）
    func refocusAfterVoice() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self, let p = self.panel, p.isVisible else { return }
            p.makeKey()
            self.focusEditor()
        }
    }

    func show() {
        guard let model else { return }
        closeWork?.cancel()
        closeWork = nil
        // 结果提示还没消失就又唤出输入窗：收掉它，免得叠在一起
        hudWork?.cancel()
        hud?.orderOut(nil)

        let p = panel ?? makePanel()
        panel = p

        if (!draft.isEmpty || draftKind != nil), Date().timeIntervalSince(hiddenAt) < 300 {
            model.quickAddText = draft
            model.quickAddKind = draftKind
        } else {
            draft = ""
            draftKind = nil
        }

        let root = QuickAddPanelRoot(
            onDone: { [weak self] in self?.hide() },
            onDraft: { [weak self] text in
                guard let self else { return }
                self.draft = text
                // 保存成功后的收尾倒计时里又开始写了：别关
                if !text.isEmpty { self.closeWork?.cancel(); self.closeWork = nil }
            },
            onKind: { [weak self] k in self?.draftKind = k },
            onSubmitted: { [weak self] msg in
                // 保存成功：输入窗马上收起，只留一个结果提示
                self?.hide()
                self?.showResult(msg, ok: true, undoIds: CaptureOutbox.shared.takeSubmitted())
            },
            onHeight: { [weak self] h in self?.heightChanged(h) }
        )
        let host = QuickAddHostingView(rootView: root.environmentObject(model))
        host.sizingOptions = []
        host.onDragMove = { [weak self] f in self?.dragMoved(f) ?? f }
        host.onDragEnd = { [weak self] in self?.dragEnded() }

        contentHeight = 130
        p.setFrame(frame(forHeight: contentHeight), display: false)
        p.contentView = host
        // 先透明地摆好，等第一次量出高度再显示，免得先显示一个默认高度再跳
        p.alphaValue = 0
        revealPending = true
        shownAt = Date()
        // 不激活应用：别的 App 保持前台、主窗口不会被带出来；输入法靠 focusEditor 里显式激活输入上下文
        p.orderFrontRegardless()
        p.makeKey()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in self?.reveal() }
    }

    func hide() {
        closeWork?.cancel()
        closeWork = nil
        guard let p = panel, p.isVisible else { return }
        hiddenAt = Date()
        hideGuides()
        p.orderOut(nil)
        p.contentView = nil
    }

    // MARK: 结果提示

    private var hud: HUDPanel?
    private var hudWork: DispatchWorkItem?

    /// 屏幕底部居中的结果提示（保存成功 / 后台保存失败）
    /// `undoIds` 不为空时多一个「撤销」按钮（HUD 停留得久一点，也能点）
    func showResult(_ text: String, ok: Bool, undoIds: [UUID] = []) {
        hudWork?.cancel()
        let undo: (() -> Void)? = undoIds.isEmpty ? nil : { [weak self] in
            self?.hudWork?.cancel()
            self?.hud?.orderOut(nil)
            Task { @MainActor in
                let r = await CaptureOutbox.shared.retract(undoIds)
                var msg = r.undone > 0 ? "已撤销 \(r.undone) 条" : "没有可以撤销的内容"
                if r.unsupported > 0 { msg += "；\(r.unsupported) 条已保存（笔记），需要手动删除" }
                self?.showResult(msg, ok: r.undone > 0)
            }
        }
        let host = FirstMouseHostingView(rootView: QuickAddHUDView(text: text, ok: ok, undo: undo))
        let size = host.fittingSize
        let p = hud ?? HUDPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        hud = p
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = undo == nil
        p.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.isReleasedWhenClosed = false
        p.animationBehavior = .none
        p.contentView = host
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        let v = screen.visibleFrame
        // 屏幕底部居中（和系统音量 / 亮度提示一个位置）
        p.setFrame(NSRect(x: v.midX - size.width / 2, y: v.minY + 36, width: size.width, height: size.height), display: true)
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; p.animator().alphaValue = 1 }

        let w = DispatchWorkItem { [weak self] in
            guard let p = self?.hud else { return }
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; p.animator().alphaValue = 0 }, completionHandler: {
                if p.alphaValue == 0 { p.orderOut(nil); p.contentView = nil }
            })
        }
        hudWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + (undo != nil ? 4.5 : (ok ? 1.3 : 3.5)), execute: w)
    }

    /// 飞行动画期间先别显示：圆点落下后由 releaseReveal() 淡入（输入框像灵动岛一样从圆点里「展开」出来）
    var holdReveal = false

    func releaseReveal() {
        holdReveal = false
        guard revealPending, let p = panel, p.isVisible else { return }
        revealPending = false
        p.alphaValue = 0
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.28
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            p.animator().alphaValue = 1
        })
        focusEditor()
    }

    private func reveal() {
        guard !holdReveal, revealPending, let p = panel, p.isVisible else { return }
        revealPending = false
        p.alphaValue = 1
        focusEditor()
    }

    /// 让输入框拿到焦点：面板是「不激活应用」的，SwiftUI 在面板还不是 key 的时候设的焦点会落空，这里补一次
    private func focusEditor() {
        guard let p = panel, let root = p.contentView else { return }
        if !p.isKeyWindow { p.makeKey() }
        if let tv = Self.firstTextView(in: root) {
            p.makeFirstResponder(tv)
            // 面板不激活应用时，输入法默认还挂在原来的 App 上：显式把输入上下文切到这个输入框
            tv.inputContext?.activate()
        }
    }

    private static func firstTextView(in view: NSView) -> NSTextView? {
        if let tv = view as? NSTextView, tv.isEditable { return tv }
        for s in view.subviews { if let found = firstTextView(in: s) { return found } }
        return nil
    }

    private func heightChanged(_ h: CGFloat) {
        contentHeight = h
        guard let p = panel, p.contentView != nil else { return }
        // 顶边不动，向下长
        var f = p.frame
        let top = f.maxY
        f.size.height = h + Self.shadowInset * 2
        f.origin.y = top - f.size.height
        p.setFrame(f, display: true)
        if revealPending { reveal() }
    }

    private func panelResigned() {
        // 弹出菜单（类型 / 优先级）也会让面板短暂失去 key：稍后再看，鼠标还在面板上就不关
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, let p = self.panel, p.isVisible else { return }
            if p.isKeyWindow || NSMouseInRect(NSEvent.mouseLocation, p.frame, false) { return }
            // 语音听写：语音卡片弹出会抢走 key，说完还要回到输入框，这时不能关
            if VoiceController.shared.phase != .idle || VoiceController.shared.dictating { return }
            // 刚弹出的半秒内失去 key 多半是应用刚被系统激活 / 主窗口抢了一下焦点，不是用户点了别处：抢回来
            if Date().timeIntervalSince(self.shownAt) < 0.8 {
                p.makeKey()
                self.focusEditor()
                return
            }
            self.hide()
        }
    }

    // MARK: 创建 / 定位

    private func makePanel() -> QuickAddPanel {
        let p = QuickAddPanel(
            contentRect: NSRect(x: 0, y: 0, width: width + Self.shadowInset * 2, height: contentHeight + Self.shadowInset * 2),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        // 和灵动岛一样高：在全屏 App 的桌面上也要能显示出来
        p.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.isMovableByWindowBackground = false
        p.animationBehavior = .utilityWindow
        p.onResign = { [weak self] in self?.panelResigned() }
        p.onCancel = { [weak self] in self?.hide() }
        return p
    }

    /// 默认位置：鼠标所在屏幕的水平居中、卡片顶边在可用区域上方 28% 处；用户拖过就用他放的位置（相对屏幕记住）
    private func frame(forHeight h: CGFloat) -> NSRect {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        let v = screen.visibleFrame
        let inset = Self.shadowInset
        let ud = UserDefaults.standard
        let dx = ud.object(forKey: Self.dxKey) as? Double ?? 0
        let topFrac = ud.object(forKey: Self.topKey) as? Double ?? Self.defaultTopFraction
        var cardX = v.midX - width / 2 + CGFloat(dx)
        cardX = min(max(cardX, v.minX), v.maxX - width)
        let cardTop = min(max(v.maxY - v.height * CGFloat(topFrac), v.minY + h), v.maxY)
        return NSRect(x: cardX - inset, y: cardTop - h - inset * 2 + inset, width: width + inset * 2, height: h + inset * 2)
    }

    // MARK: 拖动与辅助线

    private static let dxKey = "quickadd.dx"
    private static let topKey = "quickadd.top"
    private static let defaultTopFraction = 0.28
    private static let snapDistance: CGFloat = 8

    private var guideWindow: NSPanel?
    private var guideView: GuideView?

    private func screenForPanel(_ f: NSRect) -> NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.screens.first { $0.frame.intersects(f) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    /// 拖动中：把窗口位置吸附到「水平居中」和「默认高度」，同时刷新辅助线；返回吸附后的窗口位置
    private func dragMoved(_ proposed: NSRect) -> NSRect {
        let inset = Self.shadowInset
        let screen = screenForPanel(proposed)
        let v = screen.visibleFrame
        var f = proposed
        var card = f.insetBy(dx: inset, dy: inset)
        let defaultTop = v.maxY - v.height * CGFloat(Self.defaultTopFraction)

        var snapX = false, snapY = false
        if abs(card.midX - v.midX) < Self.snapDistance { f.origin.x += v.midX - card.midX; snapX = true }
        if abs(card.maxY - defaultTop) < Self.snapDistance { f.origin.y += defaultTop - card.maxY; snapY = true }
        card = f.insetBy(dx: inset, dy: inset)

        showGuides(on: screen, lines: GuideView.Lines(card: card, snapX: snapX, snapY: snapY, centerX: v.midX, topY: defaultTop))
        return f
    }

    private func dragEnded() {
        hideGuides()
        guard let p = panel else { return }
        let card = p.frame.insetBy(dx: Self.shadowInset, dy: Self.shadowInset)
        let v = screenForPanel(p.frame).visibleFrame
        let ud = UserDefaults.standard
        ud.set(Double(card.midX - v.midX), forKey: Self.dxKey)
        ud.set(Double((v.maxY - card.maxY) / v.height), forKey: Self.topKey)
        // 拖动后窗口还要保持 key，输入框继续能打字
        p.makeKey()
        focusEditor()
    }

    private func showGuides(on screen: NSScreen, lines: GuideView.Lines) {
        let gw: NSPanel
        if let w = guideWindow { gw = w } else {
            gw = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            gw.isOpaque = false
            gw.backgroundColor = .clear
            gw.hasShadow = false
            gw.ignoresMouseEvents = true
            gw.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2)   // 在输入窗下面一层
            gw.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            gw.isReleasedWhenClosed = false
            gw.animationBehavior = .none
            let gv = GuideView(frame: NSRect(origin: .zero, size: screen.frame.size))
            gv.autoresizingMask = [.width, .height]
            gw.contentView = gv
            guideView = gv
            guideWindow = gw
        }
        if gw.frame != screen.frame { gw.setFrame(screen.frame, display: false) }
        guideView?.lines = lines
        if !gw.isVisible { gw.orderFrontRegardless() }
    }

    private func hideGuides() {
        guideWindow?.orderOut(nil)
    }
}
