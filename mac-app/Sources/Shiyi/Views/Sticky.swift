import AppKit
import SwiftUI

/*
 * 便签：万能输入的「贴在桌面上」版本。
 * - 一张张小窗，写了自动存在本机（stickies.json），退出再打开还在原来的位置
 * - 图钉：钉住的便签浮在所有窗口上面（所有桌面可见）；不钉就是普通窗口层级
 * - 八种纸色，点标题行的圆点随时换；拖顶部移动，拖边缘改大小
 * - 内容就是一个完整的万能输入（QuickAddView 的便签形态）：自动识别 待办 / Daily Note / 笔记 / 结审，Tab 切类型，
 *   带优先级、听写、图片，⌘↩ 保存；保存后默认删掉便签
 * - Markdown 边写边预览：标题 / 粗体 / 列表 / 引用 / 代码当场上样式，点 [ ] 方框勾选，列表末尾回车自动续项
 * 窗口都是「不激活应用」的面板：点便签不会把主窗口带到前面。
 */

// MARK: - 数据

struct StickyNote: Codable, Identifiable {
    var id = UUID()
    var text = ""
    var color = 0
    var pinned = true
    var x: Double = 0
    var y: Double = 0
    var w: Double = 300
    var h: Double = 290
    var createdAt = Date()

    var rect: NSRect { NSRect(x: x, y: y, width: w, height: h) }
}

enum StickyPalette {
    /// 纸色
    static let papers: [Color] = [
        Color(hex: 0xFFF1A8), Color(hex: 0xD5F2C2), Color(hex: 0xCDE6FF), Color(hex: 0xFFD4DE), Color(hex: 0xE3D8FF),
        Color(hex: 0xFFDDB3), Color(hex: 0xC4EEE6), Color(hex: 0xEDEBE4),
    ]
    static let names = ["黄", "绿", "蓝", "粉", "紫", "橙", "青", "灰"]
    static let ink = Color(hex: 0x3B3524)
    static let keepKey = "sticky.deleteAfterConvert"
}

@MainActor
final class StickyModel: ObservableObject, Identifiable {
    let id: UUID
    let createdAt: Date
    @Published var text: String { didSet { if oldValue != text { onEdit?() } } }
    @Published var color: Int { didSet { onEdit?() } }
    @Published var pinned: Bool { didSet { onEdit?(); onPinChanged?() } }
    var onEdit: (() -> Void)?
    var onPinChanged: (() -> Void)?

    init(_ n: StickyNote) {
        id = n.id
        createdAt = n.createdAt
        text = n.text
        color = n.color
        pinned = n.pinned
    }
}

// MARK: - 窗口

private final class StickyPanel: NSPanel {
    var onKey: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func becomeKey() {
        super.becomeKey()
        onKey?()
    }

}

/// 顶部的拖动区：按住拖动整个窗口（SwiftUI 内容上窗口自带的「拖背景移动」不生效，自己处理）
private struct StickyDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class DragView: NSView {
        private var mouseStart = NSPoint.zero
        private var originStart = NSPoint.zero
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {
            mouseStart = NSEvent.mouseLocation
            originStart = window?.frame.origin ?? .zero
        }
        override func mouseDragged(with event: NSEvent) {
            guard let w = window else { return }
            let n = NSEvent.mouseLocation
            w.setFrameOrigin(NSPoint(x: originStart.x + n.x - mouseStart.x, y: originStart.y + n.y - mouseStart.y))
        }
    }
}

// MARK: - 控制器

/// 新建便签快捷键的注册结果（设置页显示）
@MainActor
final class StickyHotkeyState: ObservableObject {
    static let shared = StickyHotkeyState()
    @Published var registerError: String?
}

@MainActor
final class StickyController {
    static let shared = StickyController()

    private struct Entry {
        let model: StickyModel
        let panel: StickyPanel
        var tokens: [NSObjectProtocol]
    }

    private weak var model: AppModel?
    private var entries: [UUID: Entry] = [:]
    private var order: [UUID] = []
    private var saveWork: DispatchWorkItem?
    private var started = false
    /// 最后一张拿到键盘的便签：听写 / 麦克风提交只给它
    private var lastKeyID: UUID?
    func isActive(_ id: UUID) -> Bool { lastKeyID == id }

    /// 启动时把上次留下的便签都摆回去
    func start(model: AppModel) {
        guard !started else { return }
        started = true
        self.model = model
        for n in load() { open(n) }
        GlobalHotkey.sticky.onPress = { [weak self] in self?.create() }
        hotkeyObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.applyHotkey() }
        }
        applyHotkey()
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveNow() }
        }
    }

    var count: Int { order.count }

    // MARK: 全局快捷键

    private var hotkeyObserver: NSObjectProtocol?
    private var appliedHotkey: HotkeyCombo?
    private var hotkeySuspended = false

    private func applyHotkey() {
        guard !hotkeySuspended else { return }
        let want = StickyHotkey.current.combo
        if want == appliedHotkey { return }
        appliedHotkey = want
        let state = StickyHotkeyState.shared
        guard let c = want else {
            GlobalHotkey.sticky.unregister()
            if state.registerError != nil { state.registerError = nil }
            return
        }
        if let why = c.problem(for: .sticky) {
            GlobalHotkey.sticky.unregister()
            state.registerError = why
            return
        }
        let ok = GlobalHotkey.sticky.register(keyCode: c.code, modifiers: c.mods)
        state.registerError = ok ? nil : "这个组合已被系统或其他 App 占用，换一个试试"
    }

    /// 设置页录制新组合时先把热键停掉
    func suspendHotkey() {
        hotkeySuspended = true
        appliedHotkey = nil
        GlobalHotkey.sticky.unregister()
    }

    func resumeHotkey() {
        hotkeySuspended = false
        applyHotkey()
    }

    /// 新建一张便签并让光标停在里面
    func create(text: String = "") {
        guard model != nil else { return }
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        let v = screen.visibleFrame
        var n = StickyNote(text: text, color: order.count % StickyPalette.papers.count)
        let step = CGFloat(order.count % 8) * 26
        n.x = Double(v.maxX - CGFloat(n.w) - 28 - step)
        n.y = Double(v.maxY - CGFloat(n.h) - 28 - step)
        open(n)
        scheduleSave()
        lastKeyID = n.id
        if let e = entries[n.id] {
            e.panel.makeKey()
            // 等 SwiftUI 把输入框排出来再抢焦点
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.focusEditor(e.panel) }
        }
    }

    func delete(_ id: UUID) {
        guard let e = entries.removeValue(forKey: id) else { return }
        e.tokens.forEach(NotificationCenter.default.removeObserver)
        e.panel.orderOut(nil)
        e.panel.contentView = nil
        order.removeAll { $0 == id }
        scheduleSave()
    }

    /// 所有便签浮到最前（菜单里「显示全部便签」）
    func bringAllToFront() {
        for id in order { entries[id]?.panel.orderFrontRegardless() }
    }

    // MARK: 窗口

    private func open(_ n: StickyNote) {
        guard let model else { return }
        let m = StickyModel(n)
        let p = StickyPanel(contentRect: Self.visible(n.rect), styleMask: [.borderless, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.isMovableByWindowBackground = false
        p.animationBehavior = .utilityWindow
        p.minSize = NSSize(width: 220, height: 190)
        applyLevel(p, pinned: m.pinned)

        let root = StickyView(m: m, onDelete: { [weak self] in self?.delete(n.id) }).environmentObject(model)
        let host = FirstMouseHostingView(rootView: root)
        host.sizingOptions = []
        p.contentView = host

        m.onEdit = { [weak self] in self?.scheduleSave() }
        m.onPinChanged = { [weak self, weak p, weak m] in
            guard let p, let m else { return }
            self?.applyLevel(p, pinned: m.pinned)
        }
        p.onKey = { [weak self, weak p] in
            guard let p else { return }
            self?.lastKeyID = n.id
            self?.focusEditor(p)
        }
        let nc = NotificationCenter.default
        let tokens = [NSWindow.didMoveNotification, NSWindow.didResizeNotification].map { name in
            nc.addObserver(forName: name, object: p, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleSave() }
            }
        }
        entries[n.id] = Entry(model: m, panel: p, tokens: tokens)
        order.append(n.id)
        p.orderFrontRegardless()
    }

    /// 钉住：浮在所有窗口上面、所有桌面可见；没钉：普通窗口层级
    private func applyLevel(_ p: NSPanel, pinned: Bool) {
        p.level = pinned ? .floating : .normal
        p.collectionBehavior = pinned ? [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle] : [.fullScreenAuxiliary, .ignoresCycle]
    }

    /// 上次的位置所在的屏幕已经拔掉了：挪回主屏幕里
    private static func visible(_ r: NSRect) -> NSRect {
        if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(r) }) { return r }
        guard let s = NSScreen.main else { return r }
        var o = r
        o.origin = NSPoint(x: s.visibleFrame.maxX - r.width - 28, y: s.visibleFrame.maxY - r.height - 28)
        return o
    }

    /// 面板不激活应用：输入法默认还挂在原来的 App 上，要显式把输入上下文切到便签的输入框（和万能输入悬浮窗一样）
    private func focusEditor(_ p: NSPanel) {
        guard let root = p.contentView, let tv = Self.firstTextView(in: root) else { return }
        if p.firstResponder !== tv { p.makeFirstResponder(tv) }
        tv.inputContext?.activate()
    }

    private static func firstTextView(in view: NSView) -> NSTextView? {
        if let tv = view as? NSTextView, tv.isEditable { return tv }
        for s in view.subviews { if let f = firstTextView(in: s) { return f } }
        return nil
    }

    // MARK: 存取

    private func load() -> [StickyNote] {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .millisecondsSince1970
        return LocalStore.read("stickies.json")
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? dec.decode([StickyNote].self, from: $0) } ?? []
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: w)
    }

    private func saveNow() {
        saveWork?.cancel()
        saveWork = nil
        let notes: [StickyNote] = order.compactMap { id in
            guard let e = entries[id] else { return nil }
            let f = e.panel.frame
            return StickyNote(id: id, text: e.model.text, color: e.model.color, pinned: e.model.pinned,
                              x: f.origin.x, y: f.origin.y, w: f.width, h: f.height, createdAt: e.model.createdAt)
        }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .millisecondsSince1970
        if let d = try? enc.encode(notes), let s = String(data: d, encoding: .utf8) { LocalStore.write("stickies.json", s) }
    }
}

// MARK: - 内容

private struct StickyView: View {
    @ObservedObject var m: StickyModel
    let onDelete: () -> Void

    @EnvironmentObject private var model: AppModel
    @AppStorage(StickyPalette.keepKey) private var deleteAfter = true
    @State private var hovering = false
    @State private var confirmDelete = false
    @State private var swatches = false

    private var paper: Color { StickyPalette.papers[m.color % StickyPalette.papers.count] }
    private var ink: Color { StickyPalette.ink }
    private var empty: Bool { m.text.trimmed.isEmpty }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        VStack(spacing: 0) {
            header
            if swatches { swatchRow }
            // 内容就是万能输入（便签形态）：自动识别、Tab 切类型、优先级、听写、图片、⌘↩ 保存
            QuickAddView(
                compact: true,
                onSubmitted: { msg in saved(msg) },
                note: QuickAddNote(text: $m.text, isActive: { [id = m.id] in StickyController.shared.isActive(id) })
            )
        }
        .background(paper)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.black.opacity(0.1), lineWidth: 0.5))
        .environment(\.colorScheme, .light)
        .tint(ink)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    // 标题行：和纸一个颜色，没有底色块；图标很淡，鼠标移上来才清楚。空白处可以拖动
    private var header: some View {
        HStack(spacing: 0) {
            tool(m.pinned ? "pin.fill" : "pin", m.pinned ? "已钉住：浮在所有窗口上面，点一下取消" : "钉住：浮在所有窗口上面", on: m.pinned) { m.pinned.toggle() }
            Spacer(minLength: 4)
            Button { swatches.toggle() } label: {
                Circle().strokeBorder(ink.opacity(hovering || swatches ? 0.55 : 0.3), lineWidth: 1.2)
                    .background(Circle().fill(ink.opacity(0.1)))
                    .frame(width: 11, height: 11)
                    .frame(width: 24, height: 22).contentShape(Rectangle())
            }
            .buttonStyle(.plain).help("换颜色")
            Menu {
                Toggle("保存后删除便签", isOn: $deleteAfter)
                Button("复制全文") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(ComposerImage.stripMarker(m.text), forType: .string)
                }
                .disabled(empty)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(ink.opacity(hovering ? 0.6 : 0.3))
                    .frame(width: 24, height: 22).contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            tool(confirmDelete ? "trash.fill" : "xmark", confirmDelete ? "再点一次删除这张便签" : "删除便签", tint: confirmDelete ? .red : nil) { delete() }
        }
        .padding(.horizontal, 6)
        .frame(height: 24)
        .background(StickyDragHandle())
    }

    /// 颜色：点一个就换，行收起
    private var swatchRow: some View {
        HStack(spacing: 8) {
            ForEach(0 ..< StickyPalette.papers.count, id: \.self) { i in
                Button {
                    m.color = i
                    swatches = false
                } label: {
                    Circle().fill(StickyPalette.papers[i])
                        .overlay(Circle().strokeBorder(ink.opacity(m.color == i ? 0.75 : 0.22), lineWidth: m.color == i ? 1.6 : 0.8))
                        .frame(width: 16, height: 16)
                        .padding(2).contentShape(Circle())
                }
                .buttonStyle(.plain).help(StickyPalette.names[i])
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.bottom, 4)
        .transition(.opacity)
    }

    private func tool(_ icon: String, _ help: String, on: Bool = false, tint: Color? = nil, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(tint ?? ink.opacity(on ? (hovering ? 0.8 : 0.55) : (hovering ? 0.6 : 0.3)))
                .frame(width: 24, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(help)
    }

    // MARK: 动作

    private func delete() {
        // 空的直接删；有内容的要点两次，免得手滑
        if empty || confirmDelete { onDelete(); return }
        confirmDelete = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { confirmDelete = false }
    }

    /// 万能输入保存成功：底部弹结果（带撤销），按设置删掉便签
    private func saved(_ msg: String) {
        QuickAddPanelController.shared.showResult(msg, ok: true, undoIds: CaptureOutbox.shared.takeSubmitted())
        if deleteAfter { onDelete() }
    }
}
