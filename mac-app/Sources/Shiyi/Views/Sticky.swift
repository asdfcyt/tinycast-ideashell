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
 * - 关闭 = 关闭：新建的便签有内容时先问是否保存；关掉的便签收在「已关闭的便签」里，随时能再打开。删除放在「…」里
 * - 从笔记 / 结审记录「使用便签打开」的便签带着来源：底部显示来源，能写回的（笔记、想法、线索）有「写回」按钮
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
    /// 从哪条笔记 / 结审记录打开的（没有就是新建的便签）
    var source: StickySource?
    /// 打开时的原文：和现在的内容比，就知道有没有改过
    var original: String?
    /// 已关闭（不在桌面上，收在「已关闭的便签」里）
    var closed: Bool?

    var rect: NSRect { NSRect(x: x, y: y, width: w, height: h) }
}

/// 便签的来源：一条笔记，或一条结审记录
struct StickySource: Codable, Equatable {
    var kind: String            // "note" | "sjz"
    var id: String
    var project = ""
    var captureKind = ""        // 结审：idea / clue / evidence / regulation
    var title = ""
    /// 能写回原处：笔记整篇、结审的想法 / 线索（证据 / 法规带摘录和图片，写回会丢结构，不开放）
    var writable = false
    /// 在结审里打开的路径
    var openTo = ""

    var icon: String {
        kind == "note" ? "doc.text" : (["evidence": "doc.text.image", "regulation": "book.closed", "clue": "lightbulb", "idea": "text.bubble"][captureKind] ?? "doc")
    }
    var label: String {
        if kind == "note" { return "笔记 · " + (title.isEmpty ? "未命名" : title) }
        let k = ["evidence": "证据", "regulation": "法规", "clue": "线索", "idea": "想法"][captureKind] ?? "记录"
        return "\(k) · \(id)"
    }
}

/// 已关闭的便签：不在桌面上，但还在，菜单里可以重新打开
@MainActor
final class StickyShelf: ObservableObject {
    static let shared = StickyShelf()
    @Published var closed: [StickyNote] = []

    /// 菜单里的一行：来源标签或首行文字
    static func preview(_ n: StickyNote) -> String {
        let first = n.text.components(separatedBy: "\n").first { !$0.trimmed.isEmpty }?.mdPlain ?? "空白便签"
        let head = first.count > 22 ? String(first.prefix(22)) + "…" : first
        return n.source.map { "\($0.label)　\(head)" } ?? head
    }
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
    let source: StickySource?
    /// 打开时的原文（带来源的便签用来判断有没有改过）
    @Published var original: String
    /// 关闭 / 删除前的确认条
    enum Confirm { case close, delete }
    @Published var confirm: Confirm?
    /// 外面（确认条）要求保存：+1 就让万能输入保存一次
    @Published var submitTick = 0

    var dirty: Bool { text != original }

    init(_ n: StickyNote) {
        source = n.source
        original = n.original ?? n.text
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
        let all = load()
        StickyShelf.shared.closed = all.filter { $0.closed == true }
        for n in all where n.closed != true { open(n) }
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
    func create(text: String = "", source: StickySource? = nil) {
        guard model != nil else { return }
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        let v = screen.visibleFrame
        var n = StickyNote(text: text, color: order.count % StickyPalette.papers.count)
        n.source = source
        n.original = text
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

    /// 把窗口拆掉（不动存盘数据）：返回关掉时的内容快照
    @discardableResult
    private func teardown(_ id: UUID) -> StickyNote? {
        guard let e = entries.removeValue(forKey: id) else { return nil }
        let f = e.panel.frame
        let snap = StickyNote(id: id, text: e.model.text, color: e.model.color, pinned: e.model.pinned,
                              x: f.origin.x, y: f.origin.y, w: f.width, h: f.height, createdAt: e.model.createdAt,
                              source: e.model.source, original: e.model.original, closed: nil)
        e.tokens.forEach(NotificationCenter.default.removeObserver)
        e.panel.orderOut(nil)
        e.panel.contentView = nil
        order.removeAll { $0 == id }
        return snap
    }

    /// 删除：连数据一起删掉
    func delete(_ id: UUID) {
        teardown(id)
        scheduleSave()
    }

    /// 关闭：窗口收起，便签留在「已关闭的便签」里，随时能重新打开
    func close(_ id: UUID) {
        guard var snap = teardown(id) else { return }
        // 空的新便签没有留着的意义；带来源的即使没改也不留（随时可以再从原处打开）
        if snap.text.trimmed.isEmpty || (snap.source != nil && snap.text == (snap.original ?? "")) {
            scheduleSave()
            return
        }
        snap.closed = true
        let shelf = StickyShelf.shared
        shelf.closed.removeAll { $0.id == id }
        shelf.closed.insert(snap, at: 0)
        if shelf.closed.count > 30 { shelf.closed.removeLast(shelf.closed.count - 30) }
        scheduleSave()
    }

    func reopen(_ id: UUID) {
        let shelf = StickyShelf.shared
        guard var n = shelf.closed.first(where: { $0.id == id }) else { return }
        shelf.closed.removeAll { $0.id == id }
        n.closed = nil
        open(n)
        scheduleSave()
        if let e = entries[id] { e.panel.makeKey(); lastKeyID = id }
    }

    func deleteClosed(_ id: UUID) {
        StickyShelf.shared.closed.removeAll { $0.id == id }
        scheduleSave()
    }

    func clearClosed() {
        StickyShelf.shared.closed = []
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

        let root = StickyView(m: m, onDelete: { [weak self] in self?.delete(n.id) }, onClose: { [weak self] in self?.close(n.id) }).environmentObject(model)
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
                              x: f.origin.x, y: f.origin.y, w: f.width, h: f.height, createdAt: e.model.createdAt,
                              source: e.model.source, original: e.model.original, closed: nil)
        } + StickyShelf.shared.closed
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .millisecondsSince1970
        if let d = try? enc.encode(notes), let s = String(data: d, encoding: .utf8) { LocalStore.write("stickies.json", s) }
    }
}

// MARK: - 内容

private struct StickyView: View {
    @ObservedObject var m: StickyModel
    let onDelete: () -> Void
    let onClose: () -> Void

    @EnvironmentObject private var model: AppModel
    @State private var hovering = false
    @State private var swatches = false
    @State private var busy = false

    private var paper: Color { StickyPalette.papers[m.color % StickyPalette.papers.count] }
    private var ink: Color { StickyPalette.ink }
    private var empty: Bool { m.text.trimmed.isEmpty }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        VStack(spacing: 0) {
            header
            if swatches { swatchRow }
            // 内容就是万能输入（便签形态）：自动识别、Tab 切类型、优先级、听写、图片、⌘↩ 保存。
            // 从笔记 / 结审记录打开的便签有来源：底部改成来源条，不再显示「保存到哪里」的识别
            QuickAddView(
                compact: true,
                onSubmitted: { msg in saved(msg) },
                note: QuickAddNote(text: $m.text, isActive: { [id = m.id] in StickyController.shared.isActive(id) },
                                   bound: m.source != nil, submitTick: m.submitTick)
            )
            if let s = m.source { sourceBar(s) }
        }
        .background(paper)
        .overlay(alignment: .bottom) { if let c = m.confirm { confirmBar(c) } }
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.black.opacity(0.1), lineWidth: 0.5))
        .environment(\.colorScheme, .light)
        .tint(ink)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(.easeOut(duration: 0.12), value: m.confirm)
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
                Menu("Markdown 快捷键") {
                    Text("⌘B 粗体　⌘I 斜体")
                    Text("⇧⌘X 删除线　⌘E 行内代码")
                    Text("⌘K 链接")
                    Text("⌥⌘1 / 2 / 3 标题")
                    Text("⇧⌘L 列表　⇧⌘T 清单")
                    Text("⇧⌘O 有序列表　⇧⌘U 引用")
                    Text("⌘↩ 保存")
                }
                Button("复制全文") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(ComposerImage.stripMarker(m.text), forType: .string)
                }
                .disabled(empty)
                Divider()
                Button("删除便签…", role: .destructive) {
                    if empty { onDelete() } else { m.confirm = .delete }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(ink.opacity(hovering ? 0.6 : 0.3))
                    .frame(width: 24, height: 22).contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            tool("xmark", "关闭", action: requestClose)
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

    private func tool(_ icon: String, _ help: String, on: Bool = false, tint: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(tint ?? ink.opacity(on ? (hovering ? 0.8 : 0.55) : (hovering ? 0.6 : 0.3)))
                .frame(width: 24, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(help)
    }

    // MARK: 来源条 / 确认条

    private func sourceBar(_ s: StickySource) -> some View {
        HStack(spacing: 8) {
            Button { openSource(s) } label: {
                HStack(spacing: 5) {
                    Image(systemName: s.icon).font(.system(size: 10.5, weight: .semibold))
                    Text(s.label).font(.system(size: 11.5, weight: .medium)).lineLimit(1).truncationMode(.tail)
                    Image(systemName: "arrow.up.forward").font(.system(size: 8, weight: .bold)).opacity(0.5)
                }
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(Color.primary.opacity(0.08), in: Capsule())
                .foregroundStyle(Color.primary.opacity(0.7))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain).help("打开原文")
            Spacer(minLength: 4)
            if s.writable {
                Button { Task { await writeBack(s) } } label: {
                    HStack(spacing: 5) {
                        if busy { ProgressView().controlSize(.mini) }
                        Text("写回").font(.callout.weight(.semibold))
                    }
                    .foregroundStyle(m.dirty && !busy ? Color.white : Color.primary.opacity(0.35))
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(m.dirty && !busy ? Color.primary.opacity(0.78) : Color.primary.opacity(0.08), in: Capsule())
                }
                .buttonStyle(.plain).disabled(!m.dirty || busy)
                .keyboardShortcut(.return, modifiers: .command)
                .help("把修改写回原处（⌘↩）")
            }
        }
        .padding(.horizontal, 12).padding(.top, 4).padding(.bottom, 10)
    }

    private func confirmBar(_ c: StickyModel.Confirm) -> some View {
        let s = m.source
        let writeBackClose = c == .close && s?.writable == true
        return VStack(alignment: .leading, spacing: 8) {
            Text(c == .delete ? "删除这张便签？" : (writeBackClose ? "有修改还没写回，写回再关闭？" : "这张便签还没保存，保存吗？"))
                .font(.system(size: 12.5, weight: .semibold))
            HStack(spacing: 8) {
                switch c {
                case .delete:
                    pill("删除", strong: true) { onDelete() }
                case .close where writeBackClose:
                    pill("写回并关闭", strong: true) {
                        Task { if await writeBack(s!) { onClose() } }
                    }
                    pill("放弃修改") { m.text = m.original; onClose() }
                default:
                    // 保存：走万能输入的自动识别；保存成功后便签自己关掉
                    pill("保存", strong: true) { m.confirm = nil; m.submitTick += 1 }
                    pill("不保存") { onClose() }
                }
                pill("取消") { m.confirm = nil }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(paper)
        .overlay(alignment: .top) { Rectangle().fill(ink.opacity(0.12)).frame(height: 0.5) }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func pill(_ title: String, strong: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 12, weight: .semibold))
                .foregroundStyle(strong ? Color.white : Color.primary.opacity(0.7))
                .padding(.horizontal, 11).padding(.vertical, 4)
                .background(strong ? Color.primary.opacity(0.78) : Color.primary.opacity(0.08), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: 动作

    /// 关闭：新建的有内容 → 问保存；带来源的改过且能写回 → 问写回；其余直接关
    private func requestClose() {
        if empty { onClose(); return }
        if let s = m.source {
            if s.writable, m.dirty { m.confirm = .close } else { onClose() }
        } else {
            m.confirm = .close
        }
    }

    private func openSource(_ s: StickySource) {
        if s.kind == "note" { model.openNote(s.id, title: s.title); MainWindow.show() }
        else { model.openSjzApp(project: s.project, to: s.openTo.isEmpty ? "/" : s.openTo) }
    }

    /// 写回原处：笔记整篇覆盖；结审的想法 / 线索改正文
    @discardableResult
    private func writeBack(_ s: StickySource) async -> Bool {
        guard !busy else { return false }
        busy = true
        defer { busy = false }
        let text = ComposerImage.stripMarker(m.text)
        do {
            if s.kind == "note" {
                try await model.ideashell.updateNoteBody(s.id, body: text)
                model.noteCache[s.id] = nil
                model.invalidateHistory()
                await model.loadTimeline(silent: true)
            } else {
                _ = try await model.sjz.updateCapture(project: s.project, id: s.id, fields: ["content": text])
                SjzDetailStore.forget(project: s.project, id: s.id)
                await model.refreshSjzOverview(force: true)
            }
            m.original = m.text
            QuickAddPanelController.shared.showResult("已写回原处", ok: true)
            return true
        } catch {
            QuickAddPanelController.shared.showResult("写回失败：" + error.localizedDescription, ok: false)
            return false
        }
    }

    /// 万能输入保存成功：底部弹结果（带撤销），并把这张便签关掉
    private func saved(_ msg: String) {
        QuickAddPanelController.shared.showResult(msg, ok: true, undoIds: CaptureOutbox.shared.takeSubmitted())
        onDelete()
    }
}
