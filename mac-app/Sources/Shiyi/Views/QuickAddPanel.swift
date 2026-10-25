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
    let onSubmitted: (String) -> Void
    let onHeight: (CGFloat) -> Void

    var body: some View {
        QuickAddView(onDone: onDone, onDraftChange: onDraft, onSubmitted: onSubmitted)
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
        if let why = c.problem {
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

    func show() {
        guard let model else { return }
        closeWork?.cancel()
        closeWork = nil
        // 结果提示还没消失就又唤出输入窗：收掉它，免得叠在一起
        hudWork?.cancel()
        hud?.orderOut(nil)

        let p = panel ?? makePanel()
        panel = p

        if !draft.isEmpty, Date().timeIntervalSince(hiddenAt) < 300 {
            model.quickAddText = draft
        } else {
            draft = ""
        }

        let root = QuickAddPanelRoot(
            onDone: { [weak self] in self?.hide() },
            onDraft: { [weak self] text in
                guard let self else { return }
                self.draft = text
                // 保存成功后的收尾倒计时里又开始写了：别关
                if !text.isEmpty { self.closeWork?.cancel(); self.closeWork = nil }
            },
            onSubmitted: { [weak self] msg in
                // 保存成功：输入窗马上收起，只留一个结果提示
                self?.hide()
                self?.showResult(msg, ok: true, undoIds: CaptureOutbox.shared.takeSubmitted())
            },
            onHeight: { [weak self] h in self?.heightChanged(h) }
        )
        let host = NSHostingView(rootView: root.environmentObject(model))
        host.sizingOptions = []

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

    private func reveal() {
        guard revealPending, let p = panel, p.isVisible else { return }
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
        p.isMovableByWindowBackground = true
        p.animationBehavior = .utilityWindow
        p.onResign = { [weak self] in self?.panelResigned() }
        p.onCancel = { [weak self] in self?.hide() }
        return p
    }

    /// 鼠标所在屏幕的水平居中、顶边在可用区域上方 28% 处
    private func frame(forHeight h: CGFloat) -> NSRect {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        let v = screen.visibleFrame
        let inset = Self.shadowInset
        let top = v.maxY - v.height * 0.28 + inset   // 卡片顶边在 28% 处，窗口比卡片高出一圈阴影
        return NSRect(x: v.midX - width / 2 - inset, y: top - h - inset * 2, width: width + inset * 2, height: h + inset * 2)
    }
}
