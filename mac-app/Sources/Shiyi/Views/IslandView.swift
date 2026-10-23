import AppKit
import SwiftUI

// MARK: - 打开主窗口

/// 统一打开主窗口的入口：菜单栏弹窗和灵动岛（不在 Scene 里，拿不到 openWindow）都走这里
@MainActor
enum MainWindow {
    /// 由主窗口的 SwiftUI 视图在出现时写入
    static var opener: (() -> Void)?

    static func show() {
        IslandController.shared.collapse()
        // 隐藏了 Dock 图标（纯后台）时先变回普通应用，窗口才能正常打开、拿到焦点
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        NSApp.activate(ignoringOtherApps: true)
        if let w = NSApp.windows.first(where: { !($0 is NSPanel) && $0.title == "拾忆" }) {
            if w.isMiniaturized { w.deminiaturize(nil) }
            w.makeKeyAndOrderFront(nil)
        } else {
            opener?()
        }
    }
}

// MARK: - 状态

enum DropPhase: Equatable {
    case idle
    /// 拖着东西悬在岛上
    case hover
    case working
    case done(String, ok: Bool)
}

/// 展开后显示什么：待办小组件 / 投放区 / 实时活动
enum IslandMode: Equatable { case widget, drop, activity }

/// 灵动岛的几何与状态；SwiftUI 视图读它，控制器改它。
/// 展开 / 收起的动画由 AppKit 驱动（面板 frame + 图层圆角），SwiftUI 内容尺寸固定，动画期间不重新布局。
@MainActor
final class IslandState: ObservableObject {
    @Published var expanded = false
    @Published var contentHeight: CGFloat = 200
    /// 刘海宽 / 高；没有刘海时为 0
    @Published var notchWidth: CGFloat = 0
    @Published var notchHeight: CGFloat = 0
    @Published var maxContentHeight: CGFloat = 560
    @Published var mode: IslandMode = .widget
    @Published var drop: DropPhase = .idle
    @Published var zone: DropZone = .save
    @Published var activity: IslandActivity?

    var onContentHeight: ((CGFloat) -> Void)?
    var onTapCollapsed: (() -> Void)?
    var onActivityAction: ((IslandActivity, ActivityAction) -> Void)?

    var hasNotch: Bool { notchHeight > 0 }
    /// 收起时的高度：有刘海就和刘海一样高，没有就是一条细的 Top Handle
    var barHeight: CGFloat { hasNotch ? notchHeight : 26 }
    /// 刘海两侧各留一块放小图标 / 数字
    var wing: CGFloat { 36 }
    var collapsedWidth: CGFloat { notchWidth + wing * 2 }
    let expandedWidth: CGFloat = 400
    /// 展开后内容要避开刘海
    var topInset: CGFloat { hasNotch ? notchHeight : barHeight }
    var shownContentHeight: CGFloat { min(contentHeight, maxContentHeight) }
    var widgetHeight: CGFloat { topInset + shownContentHeight + 14 }
    var dropHeight: CGFloat { topInset + 100 }
    var activityHeight: CGFloat { topInset + 76 }
    var targetHeight: CGFloat {
        switch mode {
        case .widget: return widgetHeight
        case .drop: return dropHeight
        case .activity: return activityHeight
        }
    }
}

// MARK: - 视图

private struct IslandHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// 收起状态：刘海两侧各一小块。平时 = 今天 N · 逾期 M；专注 / 休息时左边是进度环、右边是倒计时
private struct IslandCollapsedView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var focus: FocusStore
    @ObservedObject var state: IslandState

    var body: some View {
        HStack(spacing: 0) {
            leading.frame(width: state.wing)
            Spacer(minLength: state.notchWidth)
            trailing.frame(width: state.wing)
        }
        .frame(width: state.collapsedWidth, height: state.barHeight)
        .contentShape(Rectangle())
        .onTapGesture { state.onTapCollapsed?() }
        .environment(\.colorScheme, .dark)
        .ignoresSafeArea()
    }

    @ViewBuilder private var leading: some View {
        if let r = focus.run {
            let nowMs = Int64(focus.now.timeIntervalSince1970 * 1000)
            let progress = r.plannedMs > 0 ? Double(r.elapsedMs(nowMs)) / Double(r.plannedMs) : 0
            ZStack {
                Circle().stroke(Color.white.opacity(0.2), lineWidth: 2)
                Circle().trim(from: 0, to: progress)
                    .stroke(r.kind.isBreak ? Color.green : Brand.orange, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: r.paused ? "pause.fill" : (r.kind.isBreak ? "cup.and.saucer.fill" : "timer"))
                    .font(.system(size: 7.5, weight: .bold)).foregroundStyle(.white)
            }
            .frame(width: 18, height: 18)
            .contentShape(Rectangle())
            .onTapGesture { focus.pauseOrResume() }
            .help(r.paused ? "继续" : "暂停")
        } else {
            Image(systemName: "checklist").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
        }
    }

    @ViewBuilder private var trailing: some View {
        if let r = focus.run {
            let ms = r.remainingMs(Int64(focus.now.timeIntervalSince1970 * 1000))
            let left = max(Int(ms / 1000), 0)
            Text(String(format: "%02d:%02d", left / 60, left % 60))
                .font(.system(size: 11, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(.white)
        } else if model.hasDida, let ov = model.overview {
            HStack(spacing: 3) {
                Text("\(ov.todayTasks().count)").foregroundStyle(.white)
                if !ov.overdue.isEmpty { Text("·\(ov.overdue.count)").foregroundStyle(.red) }
            }
            .font(.system(size: 11, weight: .semibold, design: .rounded)).monospacedDigit()
        } else {
            Text("拾忆").font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.6))
        }
    }
}

/// 展开状态：待办小组件 + 暂存架 / 投放区 / 实时活动。尺寸固定为 400 × 目标高度，由外层容器裁剪出展开过程。
private struct IslandExpandedView: View {
    @ObservedObject var state: IslandState
    @ObservedObject private var shelf = ShelfStore.shared

    var body: some View {
        ZStack(alignment: .top) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    MenuBarView()
                    Divider().padding(.horizontal, 12)
                    ShelfStrip(shelf: shelf)
                }
                .frame(width: 380)
                .clipped()
                .background(GeometryReader { g in
                    Color.clear.preference(key: IslandHeightKey.self, value: g.size.height)
                })
            }
            .frame(width: 380, height: state.shownContentHeight)
            .padding(.top, state.topInset)
            .opacity(state.mode == .widget ? 1 : 0)
            .allowsHitTesting(state.mode == .widget)
            .onPreferenceChange(IslandHeightKey.self) { h in
                guard h > 0 else { return }
                state.onContentHeight?(h)
            }

            IslandDropPane(state: state)
                .padding(.top, state.topInset)
                .opacity(state.mode == .drop ? 1 : 0)
                .allowsHitTesting(false)

            if let a = state.activity {
                IslandActivityView(state: state, activity: a)
                    .padding(.top, state.topInset)
                    .opacity(state.mode == .activity ? 1 : 0)
                    .allowsHitTesting(state.mode == .activity)
            }
        }
        .animation(.easeOut(duration: 0.18), value: state.mode)
        .frame(width: state.expandedWidth, height: state.targetHeight, alignment: .top)
        .environment(\.colorScheme, .dark)
        .ignoresSafeArea()
    }
}

// MARK: - AppKit 容器

private final class IslandHost: NSHostingView<AnyView> {
    /// 不可见 / 不该响应的那一层把鼠标事件让给下面
    var passthrough = false
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { passthrough ? nil : super.hitTest(point) }
}

/// 黑色底 + 底部圆角的容器：两层内容（收起 / 展开）都贴顶居中，容器 frame 变化时只移动它们，不改变它们的尺寸。
private final class IslandContainer: NSView {
    var collapsedHost: NSView?
    var expandedHost: NSView?
    var collapsedSize = NSSize(width: 200, height: 32)
    var expandedSize = NSSize(width: 400, height: 200)

    var onDragEnter: ((NSDraggingInfo) -> NSDragOperation)?
    var onDragExit: (() -> Void)?
    var onDrop: ((NSDraggingInfo) -> Bool)?

    /// 面板左右各多出来的一截，用来画顶部向外翘起的「耳朵」（和屏幕顶边连成一体）
    var earMax: CGFloat = 12
    private let maskLayer = CAShapeLayer()

    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        relayout()
    }

    /// 展开进度 0…1：由当前宽度推出，形状和内容透明度都跟着它走，动画只需要驱动面板 frame
    private var progress: CGFloat {
        let cw = collapsedSize.width, ew = expandedSize.width
        guard ew > cw + 1 else { return 1 }
        return min(max((bounds.width - 2 * earMax - cw) / (ew - cw), 0), 1)
    }

    func relayout() {
        let w = bounds.width, h = bounds.height
        collapsedHost?.frame = NSRect(x: (w - collapsedSize.width) / 2, y: h - collapsedSize.height,
                                      width: collapsedSize.width, height: collapsedSize.height)
        expandedHost?.frame = NSRect(x: (w - expandedSize.width) / 2, y: h - expandedSize.height,
                                     width: expandedSize.width, height: expandedSize.height)
        guard let layer, w > 1, h > 1 else { return }
        let p = progress
        let r = min(11 + (28 - 11) * p, h / 2)
        let e = max(min(5 + (earMax - 5) * p, earMax, h - r), 0)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if layer.mask !== maskLayer { layer.mask = maskLayer }
        maskLayer.frame = bounds
        maskLayer.path = shape(w: w, h: h, radius: r, ear: e)
        // 收起内容先淡出、展开内容在后半段淡入
        collapsedHost?.alphaValue = 1 - min(p / 0.3, 1)
        expandedHost?.alphaValue = min(max((p - 0.25) / 0.6, 0), 1)
        CATransaction.commit()
    }

    /// 岛的外形：顶部两个向外翘起的凹圆角（耳朵）+ 底部两个凸圆角（坐标系 y 向上）
    private func shape(w: CGFloat, h: CGFloat, radius r: CGFloat, ear e: CGFloat) -> CGPath {
        let E = earMax
        let q = CGFloat.pi / 2
        let path = CGMutablePath()
        path.move(to: CGPoint(x: E - e, y: h))
        path.addLine(to: CGPoint(x: w - E + e, y: h))
        if e > 0.1 {
            path.addRelativeArc(center: CGPoint(x: w - E + e, y: h - e), radius: e, startAngle: q, delta: q)
        } else {
            path.addLine(to: CGPoint(x: w - E, y: h))
        }
        path.addLine(to: CGPoint(x: w - E, y: r))
        path.addRelativeArc(center: CGPoint(x: w - E - r, y: r), radius: r, startAngle: 0, delta: -q)
        path.addLine(to: CGPoint(x: E + r, y: 0))
        path.addRelativeArc(center: CGPoint(x: E + r, y: r), radius: r, startAngle: -q, delta: -q)
        path.addLine(to: CGPoint(x: E, y: h - e))
        if e > 0.1 {
            path.addRelativeArc(center: CGPoint(x: E - e, y: h - e), radius: e, startAngle: 0, delta: q)
        }
        path.closeSubpath()
        return path
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { onDragEnter?(sender) ?? [] }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { onDragEnter?(sender) ?? [] }
    override func draggingExited(_ sender: NSDraggingInfo?) { onDragExit?() }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { onDrop?(sender) ?? false }
}

private final class IslandPanel: NSPanel {
    var onResign: (() -> Void)?
    var onCancel: (() -> Void)?
    /// ⌘V / ⌘⇧V（参数：是否放进暂存架）
    var onPaste: ((Bool) -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    /// 不让系统把面板挤到菜单栏下面
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override func resignKey() {
        super.resignKey()
        onResign?()
    }
    override func cancelOperation(_ sender: Any?) { onCancel?() }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command), !flags.contains(.option), !flags.contains(.control),
           event.charactersIgnoringModifiers?.lowercased() == "v", !(firstResponder is NSText) {
            onPaste?(flags.contains(.shift))
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

// MARK: - 弹簧动画

/// 用显示器刷新驱动的弹簧：宽、高各一个弹簧，展开时轻微回弹，收起时利落。
/// 可以随时改目标（重新展开 / 切换模式），速度会接着用，不会生硬跳变。
@MainActor
private final class SpringDriver: NSObject {
    struct Params { var stiffness: CGFloat; var damping: CGFloat }
    static let expand = Params(stiffness: 330, damping: 23)
    static let collapse = Params(stiffness: 420, damping: 40)
    static let resize = Params(stiffness: 380, damping: 34)

    var size = CGSize.zero
    private var velocity = CGSize.zero
    private var target = CGSize.zero
    private var params = SpringDriver.expand
    private var link: CADisplayLink?
    private var lastTime: CFTimeInterval = 0
    /// 每帧回调当前宽高
    var onFrame: ((CGSize) -> Void)?
    var onSettle: (() -> Void)?
    var minSize = CGSize(width: 1, height: 1)

    var isRunning: Bool { link != nil }

    func animate(from current: CGSize, to newTarget: CGSize, params p: Params, view: NSView) {
        if link == nil { size = current; velocity = .zero }
        target = newTarget
        params = p
        guard link == nil else { return }
        lastTime = 0
        let l = view.displayLink(target: self, selector: #selector(tick(_:)))
        l.add(to: .main, forMode: .common)
        link = l
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func tick(_ l: CADisplayLink) {
        let now = l.timestamp
        var dt = lastTime == 0 ? 1.0 / 60 : now - lastTime
        lastTime = now
        dt = min(max(dt, 0.001), 1.0 / 30)
        // 子步长积分，保证低帧率时也稳定
        let steps = max(Int(ceil(dt / (1.0 / 240))), 1)
        let h = CGFloat(dt) / CGFloat(steps)
        for _ in 0..<steps {
            let ax = -params.stiffness * (size.width - target.width) - params.damping * velocity.width
            let ay = -params.stiffness * (size.height - target.height) - params.damping * velocity.height
            velocity.width += ax * h; velocity.height += ay * h
            size.width += velocity.width * h; size.height += velocity.height * h
        }
        size.width = max(size.width, minSize.width)
        size.height = max(size.height, minSize.height)
        let settled = abs(size.width - target.width) < 0.25 && abs(size.height - target.height) < 0.25
            && abs(velocity.width) < 6 && abs(velocity.height) < 6
        if settled {
            size = target
            stop()
            onFrame?(size)
            onSettle?()
        } else {
            onFrame?(size)
        }
    }
}

// MARK: - 控制器

/// 灵动岛：一个贴在屏幕顶部中央的无边框面板。
/// - 悬停 / 点击 / 触控板下滑 / 全局快捷键展开成待办小组件（含暂存架）
/// - 把截图 / 链接 / 文字 / 文件拖到刘海处：左半边按万能输入的规则保存，右半边放进暂存架
/// - 实时活动：刚截了图、番茄完成、待办到点时，岛自己弹出来
@MainActor
final class IslandController {
    static let shared = IslandController()

    private weak var model: AppModel?
    private var started = false
    private var panel: IslandPanel?
    private var container: IslandContainer?
    private var collapsedHost: IslandHost?
    private var expandedHost: IslandHost?
    private let state = IslandState()

    private let captureWatcher = CaptureWatcher()
    private var capturing = false
    private var hotkeyInstalled: IslandHotkey?
    private var dueTimer: Timer?
    private var firedDue = Set<String>()

    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []
    private var checkTimer: Timer?
    private var collapseWork: DispatchWorkItem?
    private var finishWork: DispatchWorkItem?
    private var activityWork: DispatchWorkItem?
    private var activityHover = false
    /// 刚弹出的「番茄完成」是否有小票要从岛下面出来
    private var ticketHost = false
    private var suppressUntil = Date.distantPast
    /// 鼠标按下时拖拽剪贴板的版本号；之后变了，说明开始了一次新的拖拽
    private var dragBaseline = 0
    private var scrollAccum: CGFloat = 0
    private var scrollFired = false

    /// 面板比岛本体左右各宽出这一截（顶部「耳朵」占的位置）
    private let ear: CGFloat = 12
    private let spring = SpringDriver()

    /// 启动后一直监听设置里的显示模式，切换即时生效
    func start(model: AppModel) {
        guard !started else { return }
        started = true
        self.model = model
        state.onContentHeight = { [weak self] h in self?.contentHeightChanged(h) }
        state.onTapCollapsed = { [weak self] in self?.expand() }
        state.onActivityAction = { [weak self] a, act in self?.perform(a, act) }
        captureWatcher.onOffer = { [weak self] offer in self?.present(.capture(offer)) }
        GlobalHotkey.shared.onPress = { [weak self] in self?.hotkeyPressed() }
        model.focus.onCompleted = { [weak self] kind, minutes in
            guard let self else { return }
            if kind.isBreak {
                self.present(.breakDone(kind))
            } else {
                // 岛弹成了「终端」：紧接着的小票就从岛的下沿打印出来
                self.ticketHost = self.present(.focusDone(minutes: minutes, nextBreak: model.focus.pendingBreak))
            }
        }

        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.apply() }
        })
        observers.append(nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.screenChanged() }
        })
        apply()
    }

    private func apply() {
        let want = DisplayMode.current == .island
        if want, panel == nil { show() } else if !want, panel != nil { hide() }
        guard panel != nil else { return }
        // 这些设置随时可能被改：对账一次
        let wantCapture = DisplayMode.captureEnabled
        if wantCapture != capturing {
            capturing = wantCapture
            if wantCapture { captureWatcher.start() } else { captureWatcher.stop() }
        }
        let hk = DisplayMode.hotkey
        if hk != hotkeyInstalled {
            hotkeyInstalled = hk
            GlobalHotkey.shared.register(hk)
        }
    }

    // MARK: 显示 / 隐藏

    private func show() {
        guard let model else { return }
        refreshGeometry()
        state.expanded = false
        state.mode = .widget
        state.drop = .idle
        state.activity = nil

        let p = IslandPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false   // 只在展开时开，见 setShadow
        p.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.hidesOnDeactivate = false
        p.isMovable = false
        p.isReleasedWhenClosed = false
        p.animationBehavior = .none
        p.onResign = { [weak self] in self?.panelResigned() }
        p.onCancel = { [weak self] in self?.collapse() }
        p.onPaste = { [weak self] toShelf in self?.pasteClipboard(toShelf: toShelf) }

        let c = IslandContainer(frame: .zero)
        c.earMax = ear
        c.wantsLayer = true
        // 外形（顶部耳朵 + 底部圆角）由容器的 mask 画出来
        c.layer?.backgroundColor = NSColor.black.cgColor
        c.registerForDraggedTypes(DropReader.types)
        c.onDragEnter = { [weak self] info in self?.dragEntered(info) ?? [] }
        c.onDragExit = { [weak self] in self?.dragExited() }
        c.onDrop = { [weak self] info in self?.handleDrop(info) ?? false }

        let small = IslandHost(rootView: AnyView(IslandCollapsedView(focus: model.focus, state: state).environmentObject(model)))
        let big = IslandHost(rootView: AnyView(IslandExpandedView(state: state).environmentObject(model)))
        for h in [small, big] {
            h.sizingOptions = []
            h.safeAreaRegions = []
        }
        // 展开层先放着（透明、不响应），首次展开时内容已经布局好，不会卡一下
        big.alphaValue = 0
        big.passthrough = true
        c.addSubview(small)
        c.addSubview(big)
        c.collapsedHost = small
        c.expandedHost = big
        updateSizes(in: c)

        p.contentView = c
        panel = p
        container = c
        collapsedHost = small
        expandedHost = big
        spring.onFrame = { [weak self] size in self?.applySpringFrame(size) }
        spring.onSettle = { [weak self] in self?.springSettled() }
        p.setFrame(collapsedFrame(), display: true)
        c.relayout()
        p.orderFrontRegardless()
        installMonitors()
        startDueTimer()
    }

    private func hide() {
        spring.stop()
        removeMonitors()
        stopCheckTimer()
        dueTimer?.invalidate(); dueTimer = nil
        captureWatcher.stop(); capturing = false
        GlobalHotkey.shared.unregister(); hotkeyInstalled = nil
        collapseWork?.cancel(); collapseWork = nil
        finishWork?.cancel(); finishWork = nil
        activityWork?.cancel(); activityWork = nil
        state.expanded = false
        state.mode = .widget
        state.activity = nil
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
        container = nil
        collapsedHost = nil
        expandedHost = nil
    }

    // MARK: 几何

    /// 优先放在带刘海的屏幕，否则主屏幕
    private var screen: NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens.first
    }

    private func refreshGeometry() {
        guard let s = screen else { return }
        let top = s.safeAreaInsets.top
        if top > 0 {
            let l = s.auxiliaryTopLeftArea?.width ?? 0
            let r = s.auxiliaryTopRightArea?.width ?? 0
            let w = s.frame.width - l - r
            state.notchWidth = (l > 0 && r > 0 && w > 0) ? w : 185
            state.notchHeight = top
        } else {
            state.notchWidth = 0
            state.notchHeight = 0
        }
        state.maxContentHeight = max(220, s.visibleFrame.height - state.topInset - 40)
    }

    private func screenChanged() {
        guard let panel, let c = container else { return }
        spring.stop()
        refreshGeometry()
        updateSizes(in: c)
        panel.setFrame(state.expanded ? expandedFrame() : collapsedFrame(), display: true)
        c.relayout()
    }

    private func frame(width: CGFloat, height: CGFloat) -> NSRect {
        guard let s = screen else { return NSRect(x: 0, y: 0, width: width, height: height) }
        return NSRect(x: s.frame.midX - width / 2, y: s.frame.maxY - height, width: width, height: height)
    }

    private func collapsedFrame() -> NSRect { frame(width: state.collapsedWidth + 2 * ear, height: state.barHeight) }
    private func expandedFrame() -> NSRect { frame(width: state.expandedWidth + 2 * ear, height: state.targetHeight) }

    private func updateSizes(in c: IslandContainer) {
        c.collapsedSize = NSSize(width: state.collapsedWidth, height: state.barHeight)
        c.expandedSize = NSSize(width: state.expandedWidth, height: state.targetHeight)
    }

    // MARK: 弹簧动画

    /// 面板 frame 由弹簧驱动（每帧只移动贴顶的两层内容，不触发 SwiftUI 重新布局）；
    /// 外形、圆角、内容淡入淡出都由容器根据当前宽度算出，不需要另外的动画
    private func animateFrame(to frame: NSRect, params: SpringDriver.Params) {
        guard let panel, let c = container else { return }
        spring.minSize = collapsedFrame().size
        spring.animate(from: panel.frame.size, to: frame.size, params: params, view: c)
    }

    private func applySpringFrame(_ size: CGSize) {
        guard let panel else { return }
        panel.setFrame(frame(width: size.width, height: size.height), display: true)
        if panel.hasShadow { panel.invalidateShadow() }
    }

    private func springSettled() {
        guard let panel else { return }
        panel.invalidateShadow()
        guard !state.expanded else { return }
        // 收起动画跑完：内容切回小组件，关掉阴影
        state.mode = .widget
        state.activity = nil
        if let c = container { updateSizes(in: c) }
        panel.hasShadow = false
    }

    private func setInteractive(expanded: Bool) {
        collapsedHost?.passthrough = expanded
        expandedHost?.passthrough = !expanded
    }

    /// 展开后内容高度变了（待办增减 / 切换模式）：更新展开层尺寸并让面板跟着长高 / 缩短
    private func resizeExpanded() {
        guard let c = container else { return }
        updateSizes(in: c)
        if state.expanded { animateFrame(to: expandedFrame(), params: SpringDriver.resize) }
    }

    private func contentHeightChanged(_ h: CGFloat) {
        guard abs(h - state.contentHeight) > 0.5 else { return }
        state.contentHeight = h
        if state.expanded, state.mode == .widget { resizeExpanded() }
    }

    // MARK: 展开 / 收起

    func expand(mode: IslandMode = .widget) {
        guard panel != nil, !state.expanded else { return }
        collapseWork?.cancel(); collapseWork = nil
        state.mode = mode
        refreshGeometry()
        if let c = container { updateSizes(in: c) }
        state.expanded = true
        panel?.hasShadow = true
        setInteractive(expanded: true)
        animateFrame(to: expandedFrame(), params: SpringDriver.expand)
        startCheckTimer()
    }

    func collapse() {
        guard state.expanded else { return }
        collapseWork?.cancel(); collapseWork = nil
        finishWork?.cancel(); finishWork = nil
        activityWork?.cancel(); activityWork = nil
        activityHover = false
        suppressUntil = Date().addingTimeInterval(0.5)
        ticketHost = false
        TicketController.shared.islandCollapsed()
        state.expanded = false
        if state.drop != .working { state.drop = .idle }
        stopCheckTimer()
        setInteractive(expanded: false)
        animateFrame(to: collapsedFrame(), params: SpringDriver.collapse)
        // 弹簧停下后（springSettled）再把内容切回小组件，避免收起过程中闪一下
    }

    /// 切换展开层显示的内容（已展开时）
    private func switchMode(_ m: IslandMode) {
        guard state.mode != m else { return }
        state.mode = m
        resizeExpanded()
    }

    private func panelResigned() {
        // 弹出菜单等也可能让面板短暂失去 key：稍后再看鼠标还在不在上面
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, self.state.expanded, let panel = self.panel else { return }
            if panel.isKeyWindow || self.mouseInsidePanel() || self.shouldKeepOpen() { return }
            self.collapse()
        }
    }

    // MARK: 快捷键 / 粘贴

    private func hotkeyPressed() {
        guard panel != nil else { return }
        if state.expanded {
            collapse()
        } else {
            expand()
            // 让键盘直接可用（⌘V、Esc、输入）；不激活应用，不抢走原来的窗口
            panel?.makeKey()
        }
    }

    /// 把剪贴板里的内容保存（自动识别）或放进暂存架
    func pasteClipboard(toShelf: Bool) {
        submit(DropReader.read(.general), toShelf: toShelf)
    }

    // MARK: 保存 / 暂存

    /// 保存（万能输入规则）或暂存，并在岛上显示结果
    func submit(_ raw: RawDrop, toShelf: Bool = false) {
        guard panel != nil, let model else { return }
        activityWork?.cancel(); activityWork = nil
        finishWork?.cancel(); finishWork = nil
        collapseWork?.cancel(); collapseWork = nil
        guard !raw.isEmpty else {
            state.drop = .done("没有读到可以保存的内容", ok: false)
            showDropResult()
            scheduleFinishDrop(after: 2.4)
            return
        }
        state.drop = .working
        showDropResult()
        Task { @MainActor in
            do {
                let msg: String
                if toShelf {
                    let n = await ShelfStore.shared.add(raw)
                    msg = n > 0 ? "已放进暂存架（\(n) 项）" : "没有可以暂存的内容"
                } else {
                    msg = try await model.submitDrop(raw)
                }
                state.drop = .done(msg, ok: true)
                scheduleFinishDrop(after: 1.6)
            } catch {
                state.drop = .done(error.localizedDescription, ok: false)
                scheduleFinishDrop(after: 3.2)
            }
        }
    }

    /// 展开成「结果」页（没展开就先展开）
    private func showDropResult() {
        if state.expanded { switchMode(.drop) } else { expand(mode: .drop) }
    }

    private func scheduleFinishDrop(after delay: TimeInterval) {
        finishWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.finishWork = nil
            self.state.drop = .idle
            self.collapse()
        }
        finishWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }

    // MARK: 拖拽投放

    /// 进入投放模式：展开成投放区
    private func enterDropMode() {
        finishWork?.cancel(); finishWork = nil
        collapseWork?.cancel(); collapseWork = nil
        activityWork?.cancel(); activityWork = nil
        if state.drop != .working { state.drop = .hover }
        if !state.expanded {
            expand(mode: .drop)
        } else {
            switchMode(.drop)
        }
    }

    private func dragEntered(_ info: NSDraggingInfo) -> NSDragOperation {
        // 从岛里拖出去的东西（暂存架、截图缩略图）再拖回来，不当作投放
        guard info.draggingSource == nil, DropReader.accepts(info.draggingPasteboard) else { return [] }
        if let c = container {
            state.zone = c.convert(info.draggingLocation, from: nil).x < c.bounds.midX ? .save : .shelf
        }
        if state.mode != .drop || !state.expanded { enterDropMode() }
        return .copy
    }

    private func dragExited() {
        if state.drop == .hover { state.drop = .idle }
    }

    private func handleDrop(_ info: NSDraggingInfo) -> Bool {
        guard info.draggingSource == nil, DropReader.accepts(info.draggingPasteboard) else { return false }
        let raw = DropReader.read(info.draggingPasteboard)
        submit(raw, toShelf: state.zone == .shelf)
        return true
    }

    // MARK: 实时活动

    /// 弹出一条活动；用户正在用岛（展开着小组件 / 正在保存）时不打断
    @discardableResult
    private func present(_ a: IslandActivity) -> Bool {
        guard panel != nil, DisplayMode.activitiesEnabled else { return false }
        if case .capture = a, !DisplayMode.captureEnabled { return false }
        if state.expanded, state.mode == .drop { return false }
        if state.expanded, state.mode == .widget, mouseInsidePanel() { return false }
        state.activity = a
        activityHover = false
        if state.expanded { switchMode(.activity) } else { expand(mode: .activity) }
        scheduleActivityDismiss(after: a.duration)
        return true
    }

    // MARK: 小票挂靠

    /// 番茄完成、岛弹成了终端：小票由岛下沿打印出来。返回岛的实时位置（只能取一次）
    func takeTicketAnchor() -> (() -> NSRect?)? {
        guard ticketHost, panel != nil else { return nil }
        ticketHost = false
        // 小票要留给人慢慢看：岛也跟着多留一会儿
        scheduleActivityDismiss(after: TicketController.life)
        return { [weak self] in self?.panel?.frame }
    }

    /// 用户把小票收起了：岛的提示也一起收
    func ticketDismissed() {
        if state.expanded, state.mode == .activity { collapse() }
    }

    private func scheduleActivityDismiss(after delay: TimeInterval) {
        activityWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.activityWork = nil
            if self.state.mode == .activity { self.collapse() }
        }
        activityWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }

    private func perform(_ a: IslandActivity, _ action: ActivityAction) {
        guard let model else { return }
        if action == .dismiss { collapse(); return }
        switch a {
        case let .capture(o):
            submit(o.raw, toShelf: action == .secondary)
        case let .focusDone(_, nextBreak):
            if action == .primary {
                if nextBreak != nil { model.focus.start() } else { model.focus.quickFocus(model.focus.focusMinutes) }
            } else {
                model.focus.skipBreak()
                model.focus.quickFocus(model.focus.focusMinutes)
            }
            collapse()
        case .breakDone:
            model.focus.quickFocus(model.focus.focusMinutes)
            collapse()
        case let .todoDue(task, _):
            switch action {
            case .primary: Task { await model.complete(task) }
            case .secondary:
                model.focus.attach(task)
                model.focus.quickFocus(model.focus.focusMinutes)
            default: Task { await model.snooze(task, .hour) }
            }
            collapse()
        }
    }

    /// 待办到点：每 20 秒看一次今天有时间的待办，到了提醒时刻就弹出来（每条只弹一次）
    private func startDueTimer() {
        dueTimer?.invalidate()
        let t = Timer(timeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkDue() }
        }
        RunLoop.main.add(t, forMode: .common)
        dueTimer = t
    }

    private func checkDue() {
        guard panel != nil, DisplayMode.activitiesEnabled, NotifyPrefs.on("notify.due"),
              let model, model.hasDida, let ov = model.overview else { return }
        let cal = Calendar.current
        let now = Date()
        let nowMin = cal.component(.hour, from: now) * 60 + cal.component(.minute, from: now)
        let stored = UserDefaults.standard.object(forKey: "notify.lead") as? Int
        let lead = stored ?? 10
        for t in ov.todayTasks() {
            guard let time = t.time else { continue }
            let parts = time.split(separator: ":").compactMap { Int($0) }
            guard parts.count == 2 else { continue }
            let due = parts[0] * 60 + parts[1]
            let key = t.id + "|" + Day.today() + "|" + time
            // 提前量到了、且还没过期太久
            guard nowMin >= due - lead, nowMin <= due + 5, !firedDue.contains(key) else { continue }
            firedDue.insert(key)
            present(.todoDue(t, leadMin: max(due - nowMin, 0)))
            return
        }
    }

    // MARK: 鼠标

    private func mouseInsidePanel(margin: CGFloat = 12) -> Bool {
        guard let panel else { return false }
        return panel.frame.insetBy(dx: -margin, dy: -margin).contains(NSEvent.mouseLocation)
            || TicketController.shared.contains(NSEvent.mouseLocation, margin: margin)
    }

    private func menuIsOpen() -> Bool {
        NSApp.windows.contains { $0 !== panel && $0.isVisible && $0.level.rawValue >= NSWindow.Level.popUpMenu.rawValue }
    }

    /// 正在输入、保存中、拖着东西出去、或有弹出菜单时，不因为鼠标移开而收起
    private func shouldKeepOpen(checkMouseButton: Bool = true) -> Bool {
        if state.drop == .working { return true }
        if case .done = state.drop { return true }
        if let p = panel, p.isKeyWindow, p.firstResponder is NSText { return true }
        // 按着鼠标键：多半是正在把暂存架 / 缩略图拖出去，别把拖拽源收掉
        if checkMouseButton, NSEvent.pressedMouseButtons != 0, state.mode != .drop { return true }
        return menuIsOpen()
    }

    private func installMonitors() {
        removeMonitors()
        if let g = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved, handler: { [weak self] _ in
            Task { @MainActor in self?.evaluate() }
        }) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved, handler: { [weak self] e in
            self?.evaluate()
            return e
        }) { monitors.append(l) }

        // 其他应用里开始的拖拽：靠近刘海就展开成投放区
        if let g = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged, handler: { [weak self] _ in
            Task { @MainActor in self?.evaluate(drag: true) }
        }) { monitors.append(g) }

        // 触控板双指下滑展开 / 上滑收起
        if let g = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel, handler: { [weak self] e in
            Task { @MainActor in self?.handleScroll(e) }
        }) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel, handler: { [weak self] e in
            self?.handleScroll(e)
            return e
        }) { monitors.append(l) }

        let clickMask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: clickMask, handler: { [weak self] _ in
            Task { @MainActor in
                self?.dragBaseline = NSPasteboard(name: .drag).changeCount
                self?.clickedElsewhere()
            }
        }) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: clickMask, handler: { [weak self] e in
            if let self, e.window !== self.panel { self.clickedElsewhere() }
            return e
        }) { monitors.append(l) }
    }

    private func removeMonitors() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
    }

    /// 小票还挂在岛下面：点别处、鼠标移开都不收，让人从容看完
    private var ticketUp: Bool { state.mode == .activity && TicketController.shared.isShowing }

    private func clickedElsewhere() {
        guard state.expanded, !ticketUp, !mouseInsidePanel(margin: 0), !shouldKeepOpen(checkMouseButton: false) else { return }
        collapse()
    }

    private func startCheckTimer() {
        stopCheckTimer()
        let t = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.evaluate() }
        }
        RunLoop.main.add(t, forMode: .common)
        checkTimer = t
    }

    private func stopCheckTimer() {
        checkTimer?.invalidate()
        checkTimer = nil
    }

    private func hoverZone(on s: NSScreen, extraWidth: CGFloat = 0, extraHeight: CGFloat = 0) -> NSRect {
        let w = state.collapsedWidth + extraWidth, h = state.barHeight + extraHeight
        // 多留 2pt：鼠标顶到屏幕最上沿时 y 正好在边界上
        return NSRect(x: s.frame.midX - w / 2, y: s.frame.maxY - h, width: w, height: h + 2)
    }

    /// 触控板双指下滑（手指向下）展开；展开后在顶部一条上面、或内容不需要滚动时上滑收起
    private func handleScroll(_ e: NSEvent) {
        guard DisplayMode.swipeEnabled, e.hasPreciseScrollingDeltas, let panel, let s = screen else { return }
        if e.phase == .began || e.phase == .mayBegin { scrollAccum = 0; scrollFired = false }
        if e.phase == .ended || e.phase == .cancelled { scrollAccum = 0; scrollFired = false; return }
        guard e.momentumPhase.isEmpty, !scrollFired else { return }
        let p = NSEvent.mouseLocation
        // > 0：手指向下（不管系统是不是自然滚动）
        let dy = e.isDirectionInvertedFromDevice ? e.scrollingDeltaY : -e.scrollingDeltaY
        if !state.expanded {
            guard Date() >= suppressUntil else { return }
            guard hoverZone(on: s).contains(p) else { scrollAccum = 0; return }
            scrollAccum += dy
            if scrollAccum > 12 { scrollFired = true; expand() }
        } else if state.mode == .widget {
            guard panel.frame.contains(p) else { return }
            let inBand = p.y >= panel.frame.maxY - state.topInset - 8
            let scrollable = state.contentHeight > state.maxContentHeight + 1
            guard inBand || !scrollable else { return }
            scrollAccum += dy
            if scrollAccum < -36 { scrollFired = true; collapse() }
        }
    }

    /// 鼠标进入刘海区域就展开（拖着东西时区域更宽，直接展开成投放区）；展开后离开面板一小会儿就收起
    private func evaluate(drag: Bool = false) {
        guard let panel, let s = screen else { return }
        let p = NSEvent.mouseLocation
        if !state.expanded {
            guard Date() >= suppressUntil else { return }
            if drag {
                let pb = NSPasteboard(name: .drag)
                guard pb.changeCount != dragBaseline, DropReader.accepts(pb) else { return }
                if hoverZone(on: s, extraWidth: 120, extraHeight: 14).contains(p) { enterDropMode() }
                return
            }
            guard DisplayMode.hoverEnabled else { return }
            if hoverZone(on: s).contains(p) { expand() }
            return
        }

        // 实时活动：鼠标在上面时不消失，移开后再停留一会儿
        if state.mode == .activity {
            if panel.frame.insetBy(dx: -12, dy: -12).contains(p) || TicketController.shared.contains(p, margin: 4) {
                activityHover = true
                activityWork?.cancel(); activityWork = nil
            } else if activityHover {
                activityHover = false
                scheduleActivityDismiss(after: ticketUp ? 30 : 2.5)
            }
            return
        }

        guard DisplayMode.hoverEnabled || state.mode == .drop else { return }
        if panel.frame.insetBy(dx: -12, dy: -12).contains(p) {
            collapseWork?.cancel(); collapseWork = nil
        } else if collapseWork == nil, !shouldKeepOpen() {
            let w = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.collapseWork = nil
                if !self.mouseInsidePanel() && !self.shouldKeepOpen() { self.collapse() }
            }
            collapseWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: w)
        }
    }
}
