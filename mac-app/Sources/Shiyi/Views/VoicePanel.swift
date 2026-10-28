import AppKit
import Combine
import SwiftUI

// MARK: - 悬浮窗

private final class VoicePanel: NSPanel {
    var onCancel: (() -> Void)?
    var onReturn: (() -> Void)?
    var onResign: (() -> Void)?
    var onSpace: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
    override func resignKey() {
        super.resignKey()
        onResign?()
    }
    override func keyDown(with event: NSEvent) {
        // 录音 / 预览阶段没有文本框抢键：回车直接结束 / 保存
        if event.keyCode == 36 || event.keyCode == 76 { onReturn?(); return }
        // 预览阶段按空格：用语音说一条修改指令（没有输入框在编辑时才会走到这里）
        if event.keyCode == 49, event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty { onSpace?(); return }
        super.keyDown(with: event)
    }
}

private struct VoiceTextHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct VoiceHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// 语音输入的悬浮窗：和全局万能输入同一个位置与样式，不激活应用，原来的 App 保持前台
@MainActor
final class VoicePanelHost {
    static let shared = VoicePanelHost()

    private var panel: VoicePanel?
    private var bag = Set<AnyCancellable>()
    private weak var controller: VoiceController?
    private let width: CGFloat = 360
    private let inset: CGFloat = 24
    private var contentHeight: CGFloat = 90

    func start() {
        guard bag.isEmpty else { return }
        let c = VoiceController.shared
        controller = c
        // 听写进万能输入框、正在录音时：输入框自己有录音状态和停止按钮，底下这张语音卡片收起，免得两处同时出现
        Publishers.CombineLatest(c.$phase, c.$dictating).removeDuplicates { $0 == $1 }
            .receive(on: RunLoop.main).sink { [weak self] phase, dictating in
            guard let self else { return }
            if phase == .idle {
                self.hide(); self.removeEscMonitor()
            } else if dictating, phase == .listening || phase == .organizing {
                self.hide(animated: true); self.installEscMonitor()
            } else {
                self.show(); self.installEscMonitor()
            }
        }.store(in: &bag)
    }

    // 卡片不是 key window（比如点了别的窗口）时 Esc 也能关掉
    private var escMonitor: Any?

    private func installEscMonitor() {
        guard escMonitor == nil else { return }
        escMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { e in
            guard e.keyCode == 53 else { return }
            Task { @MainActor in
                let c = VoiceController.shared
                if c.phase != .idle { c.cancel() }
            }
        }
    }

    private func removeEscMonitor() {
        if let m = escMonitor { NSEvent.removeMonitor(m) }
        escMonitor = nil
    }

    /// 语音卡片在屏幕上的位置（去掉窗口多出来的阴影边）；没显示时是 nil。给「飞向万能输入框」的动画用
    var cardFrame: NSRect? {
        guard let p = panel, p.isVisible else { return nil }
        return p.frame.insetBy(dx: inset, dy: inset)
    }

    /// 鼠标是否在卡片上（预览倒计时据此暂停）
    var mouseInside: Bool {
        guard let p = panel, p.isVisible else { return false }
        return NSMouseInRect(NSEvent.mouseLocation, p.frame.insetBy(dx: inset - 6, dy: inset - 6), false)
    }

    private func show() {
        guard let c = controller else { return }
        if let p = panel, p.isVisible {
            fadeToken += 1          // 正在淡出的话取消，恢复显示
            p.alphaValue = 1
            p.makeKey()
            return
        }
        let p = panel ?? makePanel()
        panel = p
        let root = VoiceCardRoot(controller: c) { [weak self] h in self?.heightChanged(h) }
        let host = FirstMouseHostingView(rootView: root)
        host.sizingOptions = []
        contentHeight = 90
        p.setFrame(frame(forHeight: contentHeight), display: false)
        p.contentView = host
        p.orderFrontRegardless()
        p.makeKey()
    }

    private var fadeToken = 0

    /// animated：先淡出再收起（改走万能输入框时，卡片一边淡出一边变成飞走的圆点）
    private func hide(animated: Bool = false) {
        fadeToken += 1
        guard let p = panel, p.isVisible else { return }
        guard animated else {
            p.orderOut(nil)
            p.contentView = nil
            p.alphaValue = 1
            return
        }
        let token = fadeToken
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            p.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, token == self.fadeToken else { return }
                p.orderOut(nil)
                p.contentView = nil
                p.alphaValue = 1
            }
        })
    }

    private func heightChanged(_ h: CGFloat) {
        contentHeight = h
        guard let p = panel, p.contentView != nil else { return }
        // 贴着屏幕底部（和 HUD 同一位置），底边不动、向上长高
        var f = p.frame
        f.size.height = h + inset * 2
        p.setFrame(f, display: true)
    }

    private func makePanel() -> VoicePanel {
        let p = VoicePanel(
            contentRect: NSRect(x: 0, y: 0, width: width + inset * 2, height: contentHeight + inset * 2),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.isMovableByWindowBackground = true
        p.animationBehavior = .utilityWindow
        p.onCancel = { VoiceController.shared.cancel() }
        p.onReturn = { VoiceController.shared.returnPressed() }
        p.onSpace = { VoiceController.shared.refineByVoice() }
        p.onResign = {
            // 结果 / 错误卡片点别处就收起；录音和预览阶段不收（内容在，再按快捷键继续）
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                let c = VoiceController.shared
                if c.phase == .info || c.phase == .failed, let p = VoicePanelHost.shared.panel, !p.isKeyWindow,
                   !NSMouseInRect(NSEvent.mouseLocation, p.frame, false) { c.dismiss() }
            }
        }
        return p
    }

    private func frame(forHeight h: CGFloat) -> NSRect {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        let v = screen.visibleFrame
        // 和结果 HUD 一样：屏幕底部居中，卡片底边距可用区域底 36（窗口比卡片多出一圈阴影）
        return NSRect(x: v.midX - width / 2 - inset, y: v.minY + 36 - inset, width: width + inset * 2, height: h + inset * 2)
    }
}

private struct VoiceCardRoot: View {
    @ObservedObject var controller: VoiceController
    let onHeight: (CGFloat) -> Void

    var body: some View {
        VoiceCardView(c: controller)
            .glassCard(radius: 20)
            .background(GeometryReader { g in Color.clear.preference(key: VoiceHeightKey.self, value: g.size.height) })
            .onPreferenceChange(VoiceHeightKey.self) { h in
                guard h > 0 else { return }
                onHeight(h)
            }
            .shadow(color: .black.opacity(0.22), radius: 14, y: 6)
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }
}

// MARK: - 卡片

private struct VoiceCardView: View {
    @ObservedObject var c: VoiceController
    @State private var showRaw = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            switch c.phase {
            case .listening: listening
            case .organizing: organizing
            case .preview: preview
            case .info: info
            case .failed: failed
            case .idle: EmptyView()
            }
        }
        .padding(c.phase == .listening ? EdgeInsets(top: 8, leading: 12, bottom: 9, trailing: 12) : EdgeInsets(top: 11, leading: 12, bottom: 11, trailing: 12))
        .frame(width: 360, alignment: .leading)
    }

    // MARK: 录音中

    private var listening: some View { VoiceListeningView(c: c) }

    private var organizing: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("正在整理…").font(.system(size: 11.5, weight: .medium))
            }
            if !c.rawText.isEmpty {
                Text(c.rawText).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(4)
            }
            HStack {
                Spacer()
                Button("取消") { c.cancel() }.buttonStyle(.plain).foregroundStyle(.secondary).font(.caption)
            }
        }
    }

    private func footer(_ left: String?, _ right: String) -> some View {
        HStack {
            if let left { Text(left).font(.caption).foregroundStyle(.tertiary) }
            Spacer()
            Text(right).font(.caption).foregroundStyle(.tertiary)
        }
    }

    // MARK: 预览

    private var preview: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").foregroundStyle(Brand.orange)
                Text("整理结果").font(.system(size: 11.5, weight: .semibold))
                if let left = c.countdown {
                    ProgressView(value: left, total: VoiceController.countdownSeconds).progressViewStyle(.linear).tint(Brand.orange).frame(width: 36)
                        .padding(.leading, 4)
                    Text(c.hovering ? "已暂停自动保存" : "\(Int(left.rounded(.up))) 秒后保存")
                        .font(.caption).foregroundStyle(.tertiary).lineLimit(1).fixedSize()
                }
                Spacer(minLength: 4)
                closeButton
                if !c.rawText.isEmpty {
                    Button { showRaw.toggle(); c.userTouched() } label: {
                        Text(showRaw ? "收起原文" : "看原始转写").font(.caption).foregroundStyle(.secondary)
                    }.buttonStyle(.plain)
                }
            }
            if showRaw {
                Text(c.rawText).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    .padding(6).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            if let n = c.notice {
                Label(n, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach($c.drafts) { $d in
                DraftRow(d: $d, c: c, showsTag: c.drafts.count > 1)
            }
            ForEach(c.infos) { InfoBlock(info: $0, c: c) }

            HStack(spacing: 8) {
                // 只有一条时，类型标签（结审想法 / 追加笔记 / 改待办……）放在左下角；多条时各自留在每条左侧
                if c.drafts.count == 1 {
                    ForEach($c.drafts) { $d in
                        DraftTag(d: $d, c: c).fixedSize()
                    }
                }
                Spacer()
                Button { c.refineByVoice() } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "mic.fill").font(.system(size: 10))
                        Text("说话修改")
                    }
                    .font(.system(size: 11.5)).foregroundStyle(Brand.orangeDeep)
                }
                .buttonStyle(.plain).help("用语音下指令改：改正式一些 / 翻译成英文 / 第二条改到明天（空格键）")
                Button("取消") { c.cancel() }.buttonStyle(.plain).foregroundStyle(.secondary).font(.system(size: 11.5))
                Button { c.confirm() } label: {
                    HStack(spacing: 6) {
                        Text("保存").font(.system(size: 11.5, weight: .semibold))
                        Text("↩").font(.caption2).opacity(0.7)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 3)
                    .background(Brand.orange, in: Capsule())
                }.buttonStyle(.plain)
            }
        }
    }

    // MARK: 只读结果 / 错误

    private var closeButton: some View {
        Button { c.cancel() } label: {
            Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                .frame(width: 18, height: 18).contentShape(Rectangle())
        }
        .buttonStyle(.plain).help("关闭（Esc）")
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack { Spacer(); closeButton }
            ForEach(c.infos) { InfoBlock(info: $0, c: c) }
            footer(nil, "↩ / Esc 关闭")
        }
    }

    private var failed: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(c.errorText ?? "出错了", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 11.5)).foregroundStyle(Color.orange).fixedSize(horizontal: false, vertical: true)
            if !c.rawText.isEmpty {
                Text(c.rawText).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            HStack(spacing: 8) {
                Spacer()
                if let a = c.errorAction {
                    Button(a.label) { a.run() }.buttonStyle(.bordered)
                }
                Button("关闭") { c.dismiss() }.buttonStyle(.borderedProminent).tint(Brand.orange)
            }
        }
    }
}

// MARK: - 预览里每一条的类型标签（放在卡片左下角）

private struct DraftTag: View {
    @Binding var d: VoiceDraft
    @ObservedObject var c: VoiceController

    @ViewBuilder var body: some View {
        switch d.action {
        case .create:
            Menu {
                ForEach(CaptureKind.available(sjz: AppModel.current?.hasSjz ?? false)) { k in
                    Button { d.kind = k; c.userTouched() } label: {
                        if k == d.kind { Label(k.rawValue, systemImage: "checkmark") } else { Label(k.rawValue, systemImage: k.icon) }
                    }
                }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: d.kind.icon)
                    Text(d.kind.rawValue)
                }
                .font(.caption.weight(.medium))
                .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Brand.orange.opacity(0.14), in: Capsule()).foregroundStyle(Brand.orangeDeep)
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
        case .append:
            tag("追加笔记", "text.append", Brand.orangeDeep)
        case .edit:
            tag("改待办", "pencil", .blue)
        case .complete:
            tag("完成", "checkmark.circle", .green)
        case .delete:
            tag("删除", "trash", .red)
        }
    }

    private func tag(_ text: String, _ icon: String, _ color: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
            Text(text)
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.14), in: Capsule()).foregroundStyle(color)
    }
}

// MARK: - 预览里的一条

private struct DraftRow: View {
    @Binding var d: VoiceDraft
    @ObservedObject var c: VoiceController
    /// 多条时类型标签留在每条左侧；只有一条时标签放到卡片左下角
    var showsTag = true
    @State private var editing = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            if showsTag { DraftTag(d: $d, c: c).fixedSize() }
            VStack(alignment: .leading, spacing: 4) {
                body1
                if let p = d.problem {
                    Label(p, systemImage: "xmark.octagon.fill").font(.caption).foregroundStyle(Color.red)
                } else {
                    meta
                }
            }
            Button { c.removeDraft(d.id) } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
            }.buttonStyle(.plain).help("去掉这一条")
        }
        .padding(6)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder private var body1: some View {
        switch d.action {
        case .complete, .delete:
            Text(d.task?.cleanTitle ?? "").font(.system(size: 12)).lineLimit(2)
        case .edit:
            VStack(alignment: .leading, spacing: 2) {
                Text(d.task?.cleanTitle ?? "").font(.system(size: 12, weight: .medium)).lineLimit(2)
                if !d.content.isEmpty || d.problem == nil {
                    TextField("补充到备注（可留空）", text: $d.content, axis: .vertical)
                        .textFieldStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1 ... 3)
                        .fixedSize(horizontal: false, vertical: true)
                        .onChange(of: d.content) { _, _ in c.userTouched() }
                        .onSubmit { c.confirm() }
                }
            }
        default:
            if editing {
                // 编辑时才用输入框；平时用普通文字显示，保证整理后的内容完整换行显示
                TextField("", text: $d.content, axis: .vertical)
                    .textFieldStyle(.plain).font(.system(size: 11.5)).lineLimit(1 ... 8)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .focused($focused)
                    .onChange(of: d.content) { _, _ in c.userTouched() }
                    .onChange(of: focused) { _, f in if !f { editing = false } }
                    .onSubmit { editing = false; c.confirm() }
            } else {
                Text(d.content.isEmpty ? "（空）" : d.content)
                    .font(.system(size: 11.5))
                    .foregroundStyle(d.content.isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentShape(Rectangle())
                    .onTapGesture { editing = true; focused = true; c.userTouched() }
                    .help("点击修改")
            }
        }
    }

    @ViewBuilder private var meta: some View {
        let hasWhen = d.date != nil || d.time != nil
        if d.action == .edit {
            HStack(spacing: 6) {
                if hasWhen {
                    chip("clock", "改到 " + whenText)
                }
                if d.priority != 0 { chip("flag.fill", priorityText) }
            }
        } else if d.action == .create, d.kind == .todo {
            HStack(spacing: 6) {
                chip(hasWhen ? "calendar" : "tray", hasWhen ? whenText : "无日期 · 收集箱")
                if d.priority != 0 { chip("flag.fill", priorityText) }
                if let r = d.repeatText { chip("repeat", r) }
                ForEach(d.tags, id: \.self) { chip("number", $0) }
            }
        } else if d.action == .create, d.kind.isSjz {
            // 结审：写清楚会存到哪（钉住的取证单 / 线索 / 法规，没钉住就新建），免得说完不知道去了哪
            HStack(spacing: 6) {
                chip(d.kind.icon, sjzDestination)
                ForEach(d.tags, id: \.self) { chip("number", $0) }
            }
        } else if !d.tags.isEmpty {
            HStack(spacing: 6) { ForEach(d.tags, id: \.self) { chip("number", $0) } }
        }
    }

    private var sjzDestination: String {
        let m = AppModel.current
        let pin = m?.sjzPin ?? SjzPin()
        let project = (m?.sjzTargetTitle.isEmpty == false) ? m!.sjzTargetTitle : "未选择项目"
        switch d.kind {
        case .evidence:
            if !pin.evidencePath.isEmpty { return "追加到证据「\(pin.evidenceLabel)」" }
            return pin.noteLabel.isEmpty ? "\(project) · 单独证据文件" : "追加到取证单 \(pin.noteLabel)"
        case .regulation: return pin.regulation.isEmpty ? "\(project) · 自动取名新建法规" : "追加到《\(pin.regulation)》"
        case .clue: return pin.clueId.isEmpty ? "\(project) · 新线索" : "追加到线索 \(pin.clueLabel)"
        default: return "\(project) · 当天工作日志"
        }
    }

    private var whenText: String {
        (d.date.map { Day.label($0) } ?? "") + (d.time.map { (d.date == nil ? "" : " ") + $0 } ?? "")
    }

    private var priorityText: String { d.priority >= 5 ? "高优先级" : (d.priority >= 3 ? "中优先级" : "低优先级") }

    private func chip(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 9))
            Text(text)
        }
        .font(.caption2).foregroundStyle(Brand.orangeDeep)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(Brand.orange.opacity(0.12), in: Capsule())
    }
}

// MARK: - 只读结果块（查询待办 / 问 AI）

private struct InfoBlock: View {
    let info: VoiceInfo
    @ObservedObject var c: VoiceController

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(info.title).font(.system(size: 11.5, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
            ForEach(info.lines, id: \.self) { Text("· " + $0).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            if let a = info.answer {
                Text(a).font(.system(size: 11.5)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("存为笔记") { c.saveInfoAsNote(info) }.buttonStyle(.bordered).controlSize(.small)
                }
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}


// MARK: - 录音中卡片（紧凑：以文字为主，小波形和按钮都挤在一行）

private struct VoiceListeningView: View {
    @ObservedObject var c: VoiceController
    @ObservedObject private var mic = MicEngine.shared
    @State private var pulse = false

    private var liveShown: String {
        if c.liveText.isEmpty, c.refining { return "说出修改指令：改正式一些 / 翻译成英文 / 第二条改到明天…" }
        if c.liveText.isEmpty, mic.connected, mic.heart.anyOnline, mic.settings.cfg.backend == .shiyi { return "请说话…（双击发射器按键结束）" }
        if c.liveText.isEmpty { return VoiceSettings.mode == .hold ? "请说话…（松开快捷键结束）" : "请说话…（再按一次快捷键结束）" }
        return c.liveText.count > 70 ? "…" + c.liveText.suffix(70) : c.liveText
    }

    private var bars: [Float] { Array(c.levels.suffix(18)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 第一行：状态（录音点 / 修改标记 / 计时 / 引擎）靠左，发射器和波形靠右；每一项都不换行、不被挤扁
            HStack(spacing: 8) {
                Circle().fill(Color.red).frame(width: 8, height: 8)
                    .opacity(pulse ? 0.35 : 1)
                    .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulse)
                if c.refining {
                    Text("修改").font(.system(size: 10, weight: .semibold)).foregroundStyle(Brand.orangeDeep)
                        .lineLimit(1).fixedSize()
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Brand.orange.opacity(0.14), in: Capsule())
                }
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    let t = max(0, Int(ctx.date.timeIntervalSince(c.listeningSince)))
                    Text(String(format: "%d:%02d", t / 60, t % 60))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .lineLimit(1).fixedSize()
                }
                Text(c.engineLabel).font(.system(size: 9.5)).foregroundStyle(.tertiary).lineLimit(1).fixedSize()
                Spacer(minLength: 8)
                if mic.connected, mic.heart.anyOnline { MicMiniTX(height: 20).frame(width: 26, height: 22) }
                HStack(spacing: 2) {
                    ForEach(bars.indices, id: \.self) { i in
                        Capsule().fill(Brand.orange.opacity(0.4 + 0.55 * Double(min(1, bars[i]))))
                            .frame(width: 3, height: 3 + CGFloat(min(1, bars[i])) * 13)
                    }
                }
                .frame(height: 16)
                .animation(.easeOut(duration: 0.08), value: c.levels)
            }

            // 实时文字是主体：不用滚动容器（会把顶部一行裁掉一截），只显示最后 70 个字、最多三行，前面的用「…」省略
            Text(liveShown)
                .font(.system(size: 12))
                .lineSpacing(2)
                .foregroundStyle(c.liveText.isEmpty ? .secondary : .primary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, minHeight: 16, alignment: .topLeading)
                .fixedSize(horizontal: false, vertical: true)

            // 第二行动作：和整理结果卡片的底部一致（取消 + 主按钮靠右）
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                Button("取消") { c.cancel() }
                    .buttonStyle(.plain).foregroundStyle(.secondary).font(.system(size: 11.5))
                    .lineLimit(1).fixedSize()
                Button { c.finish() } label: {
                    HStack(spacing: 6) {
                        Text("说完了").font(.system(size: 11.5, weight: .semibold))
                        Text("↩").font(.caption2).opacity(0.7)
                    }
                    .lineLimit(1).fixedSize()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 3)
                    .background(Brand.orange, in: Capsule())
                }.buttonStyle(.plain)
            }
        }
        .onAppear {
            pulse = true
        }
    }
}
