import SwiftUI
import ServiceManagement

// MARK: - 主题与小工具

enum MicTheme {
    static let accent = Color(red: 0.04, green: 0.52, blue: 1.0)
    static let yellow = Color(red: 1.0, green: 0.82, blue: 0.10)
    static let txImage: NSImage? = {
        guard let url = Bundle.main.url(forResource: "tx", withExtension: "png", subdirectory: "Mic") else { return nil }
        return NSImage(contentsOf: url)
    }()
    /// 按钮在发射器图片上的位置(相对宽高)
    static let buttonAnchor = CGPoint(x: 0.025, y: 0.515)
}

func micNoiseLabel(_ level: Int) -> String {
    switch level {
    case 1: return "弱 · 10dB"
    case 2: return "中 · 15dB"
    case 3: return "强 · 20dB"
    default: return "关闭"
    }
}

extension MicSettingsStore {
    func bind<T>(_ kp: WritableKeyPath<MicConfig, T>) -> Binding<T> {
        Binding(get: { self.cfg[keyPath: kp] }, set: { self.cfg[keyPath: kp] = $0 })
    }
}

/// 界面局部状态(这个 SDK 的命令行工具里没有 @State 宏插件,统一放进对象里)。
@MainActor
final class MicUIModel: ObservableObject {
    enum Tab: String, CaseIterable, Identifiable {
        case voice = "语音输入"
        case behavior = "时序与行为"
        case system = "权限与诊断"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .voice: return "waveform.badge.mic"
            case .behavior: return "slider.horizontal.3"
            case .system: return "stethoscope"
            }
        }
    }

    @Published var tab: Tab = .voice
    @Published var tilt: CGSize = .zero
    @Published var appeared = false
    @Published var hovered: MicGesture?
    @Published var flashing: MicGesture?
    @Published var rippleStart = Date.distantPast
    @Published var rippleKind: MicGesture = .single
    private var flashTask: Task<Void, Never>?

    func flash(_ g: MicGesture) {
        rippleStart = Date()
        rippleKind = g
        withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { flashing = g }
        flashTask?.cancel()
        flashTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_100_000_000)
            if !Task.isCancelled {
                withAnimation(.easeOut(duration: 0.5)) { self?.flashing = nil }
            }
        }
    }
}

/// 开机自启状态。
final class MicLoginItem: ObservableObject {
    @Published var enabled = (SMAppService.mainApp.status == .enabled)

    func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            // 忽略:下面按系统真实状态回读
        }
        enabled = (SMAppService.mainApp.status == .enabled)
    }
}

// MARK: - 入口

/// 打开设置窗口的「猛犸麦克风」页:菜单栏、命令菜单等都走这里。
@MainActor
enum MicWindow {
    static func show() { SettingsWindow.show(.mic) }
}

// MARK: - 左侧:发射器展示

struct MicHeroPanel: View {
    @EnvironmentObject var engine: MicEngine
    @EnvironmentObject var model: MicUIModel
    @Environment(\.colorScheme) private var scheme
    /// 嵌在设置页里用:横向排布、发射器缩小
    var compact = false

    private var online: Bool { engine.connected && engine.heart.anyOnline }
    private var scale: CGFloat { compact ? 0.64 : 1 }

    private var glow: Color {
        if !online { return .gray }
        if engine.state == .recording { return .red }
        if engine.heart.anyMuted { return .orange }
        return MicTheme.accent
    }

    private var statusText: String {
        if !engine.connected { return engine.attached ? "接收器无响应" : "接收器未连接" }
        if !engine.heart.anyOnline { return "发射器未开机" }
        if engine.state == .recording { return "录音中" }
        if engine.heart.anyMuted { return "已静音" }
        return "收音中"
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: compact ? 24 : 30, style: .continuous)
                .fill(LinearGradient(colors: scheme == .dark
                                     ? [Color(red: 0.14, green: 0.17, blue: 0.25), Color(red: 0.08, green: 0.10, blue: 0.16)]
                                     : [Color(red: 0.90, green: 0.94, blue: 1.0), Color(red: 0.80, green: 0.86, blue: 0.97)],
                                     startPoint: compact ? .topLeading : .top, endPoint: compact ? .bottomTrailing : .bottom))
                .overlay(
                    RoundedRectangle(cornerRadius: compact ? 24 : 30, style: .continuous)
                        .strokeBorder(Color.white.opacity(scheme == .dark ? 0.08 : 0.7), lineWidth: 1)
                )
                .shadow(color: .black.opacity(compact ? 0 : (scheme == .dark ? 0.4 : 0.12)), radius: 24, y: 10)

            if compact {
                HStack(spacing: 14) {
                    stage.frame(width: 190)
                    VStack(spacing: 0) {
                        header
                        Spacer(minLength: 10)
                        tiles
                        footer
                    }
                }
                .padding(18)
            } else {
                VStack(spacing: 0) {
                    header
                    Spacer(minLength: 0)
                    stage
                    Spacer(minLength: 0)
                    tiles
                    footer
                }
                .padding(22)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text("LARK A2")
                    .font(.system(size: compact ? 22 : 26, weight: .bold, design: .rounded))
                Text("无线麦克风 · 发射器 TX1")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 6) {
                Circle().fill(glow).frame(width: 8, height: 8)
                    .shadow(color: glow, radius: 4)
                Text(statusText).font(.system(size: 12, weight: .medium))
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Capsule().fill(.ultraThinMaterial))
            .animation(.easeInOut(duration: 0.3), value: statusText)
        }
    }

    // 发射器 + 光晕 + 按键涟漪
    private var stage: some View {
        let h: CGFloat = 290 * scale
        let w: CGFloat = h * 732 / 1352
        let areaW: CGFloat = compact ? 190 : 340
        let areaH: CGFloat = h + 30 * scale
        return TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let recording = engine.state == .recording
            let bob = sin(t * 1.4) * 5 * scale
            let pulse = 1 + 0.06 * sin(t * (recording ? 5 : 1.6))
            ZStack {
                Circle()
                    .fill(glow.opacity(0.38))
                    .frame(width: 210 * scale, height: 210 * scale)
                    .blur(radius: 42 * scale)
                    .scaleEffect(pulse)
                if recording {
                    ForEach(0..<3, id: \.self) { i in
                        let p = (t * 0.7 + Double(i) / 3).truncatingRemainder(dividingBy: 1)
                        Circle()
                            .stroke(Color.red.opacity((1 - p) * 0.55), lineWidth: 2)
                            .frame(width: (170 + 150 * p) * scale, height: (170 + 150 * p) * scale)
                    }
                }
                txBody(w: w, h: h, now: ctx.date)
                    .offset(y: bob)
                    .rotation3DEffect(.degrees(Double(model.tilt.height) * -8), axis: (1, 0, 0), perspective: 0.6)
                    .rotation3DEffect(.degrees(Double(model.tilt.width) * 10), axis: (0, 1, 0), perspective: 0.6)
                    .animation(.interactiveSpring(response: 0.35, dampingFraction: 0.7), value: model.tilt)
            }
            // 紧凑模式整体右移,给左侧的「按键」标签留出位置,不溢出卡片
            .offset(x: compact ? 22 : 0)
            .frame(maxWidth: .infinity)
            .frame(height: areaH)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let p):
                    model.tilt = CGSize(width: (p.x / areaW - 0.5) * 2, height: (p.y / areaH - 0.5) * 2)
                case .ended:
                    model.tilt = .zero
                }
            }
        }
        .frame(height: areaH)
    }

    @ViewBuilder
    private func txBody(w: CGFloat, h: CGFloat, now: Date) -> some View {
        let img = MicTheme.txImage
        ZStack(alignment: .topLeading) {
            if let img {
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: w, height: h)
                    .shadow(color: .black.opacity(0.35), radius: 14 * scale, x: 0, y: 10 * scale)
            } else {
                RoundedRectangle(cornerRadius: 40 * scale).fill(.black).frame(width: w, height: h)
            }
            // 按键涟漪
            let ax = w * MicTheme.buttonAnchor.x
            let ay = h * MicTheme.buttonAnchor.y
            ZStack {
                let count = model.rippleKind == .single ? 1 : (model.rippleKind == .double ? 2 : 3)
                ForEach(0..<count, id: \.self) { i in
                    let p = now.timeIntervalSince(model.rippleStart) / 0.8 - Double(i) * 0.22
                    if p >= 0 && p <= 1 {
                        Circle()
                            .stroke(MicTheme.yellow.opacity(1 - p), lineWidth: 3)
                            .frame(width: (14 + 60 * p) * scale, height: (14 + 60 * p) * scale)
                    }
                }
            }
            .position(x: ax, y: ay)
            .allowsHitTesting(false)
            // 引线标注
            HStack(spacing: 3) {
                Text(compact ? "按键" : "机身按键")
                    .font(.system(size: compact ? 10 : 10.5, weight: .semibold))
                    .foregroundStyle(.black.opacity(0.8))
                    .padding(.horizontal, compact ? 6 : 7).padding(.vertical, compact ? 2 : 3)
                    .background(Capsule().fill(MicTheme.yellow))
                Rectangle().fill(MicTheme.yellow).frame(width: compact ? 8 : 12, height: 1.5)
            }
            .fixedSize()
            .position(x: ax - (compact ? 30 : 50), y: ay)
        }
        .frame(width: w, height: h)
    }

    private var tiles: some View {
        HStack(spacing: 10) {
            MicStatTile(title: "电量") {
                let b = online ? engine.heart.tx1Battery : 0
                ZStack {
                    Circle().stroke(Color.primary.opacity(0.12), lineWidth: 5)
                    Circle()
                        .trim(from: 0, to: CGFloat(b) / 100)
                        .stroke(b > 40 ? Color.green : (b > 20 ? Color.orange : Color.red),
                                style: StrokeStyle(lineWidth: 5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.easeOut(duration: 0.6), value: b)
                    if engine.heart.tx1Charging && online {
                        Image(systemName: "bolt.fill").font(.system(size: 14)).foregroundStyle(.green)
                    } else {
                        Text(online ? "\(b)" : "–").font(.system(size: 15, weight: .bold, design: .rounded))
                    }
                }
                .frame(width: 46, height: 46)
            } caption: {
                Text(engine.heart.tx1Charging && online ? "充电中" : "TX1 电量")
            }

            MicStatTile(title: "麦克风") {
                Image(systemName: !online ? "mic.slash" : (engine.heart.anyMuted ? "mic.slash.fill" : "mic.fill"))
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(!online ? Color.gray : (engine.heart.anyMuted ? Color.orange : MicTheme.accent))
                    .frame(width: 46, height: 46)
                    .animation(.spring(response: 0.3, dampingFraction: 0.6), value: engine.heart.anyMuted)
            } caption: {
                Text(!online ? "离线" : (engine.heart.anyMuted ? "已静音" : "收音中"))
            }

            MicStatTile(title: "降噪") {
                MicNoiseBars(level: online ? engine.heart.noise : 0)
                    .frame(width: 46, height: 46)
            } caption: {
                Text(micNoiseLabel(online ? engine.heart.noise : 0))
            }
        }
        .padding(.bottom, 12)
    }

    private var footer: some View {
        VStack(spacing: 3) {
            Text("接收器 3547:0411 · 固件 \(engine.firmware.isEmpty ? "—" : engine.firmware)")
            if !engine.txSerial.isEmpty { Text("TX1 序列号 \(engine.txSerial)") }
        }
        .font(.system(size: 10.5, design: .monospaced))
        .foregroundStyle(.secondary)
    }
}

struct MicStatTile<Content: View, Caption: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content
    @ViewBuilder var caption: () -> Caption

    var body: some View {
        VStack(spacing: 8) {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
            content()
            caption().font(.system(size: 11.5, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.ultraThinMaterial))
    }
}

struct MicNoiseBars: View {
    let level: Int
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 4) {
                ForEach(0..<5, id: \.self) { i in
                    let on = level > 0
                    let base: CGFloat = [14, 26, 36, 26, 14][i]
                    let wobble = on ? CGFloat(sin(t * 3 + Double(i))) * 4 * CGFloat(level) / 3 : 0
                    Capsule()
                        .fill(on ? MicTheme.accent : Color.primary.opacity(0.2))
                        .frame(width: 5, height: max(6, (on ? base : 8) + wobble))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - 右侧:配置

struct MicConfigPane: View {
    @EnvironmentObject var engine: MicEngine
    @EnvironmentObject var settings: MicSettingsStore
    @EnvironmentObject var model: MicUIModel

    /// 直接放在设置页的分组表单里：返回若干个 Section
    var body: some View {
        Group {
            gestures
            MicVoiceTab()
            MicBehaviorTab()
            MicSystemTab()
        }
    }

    private var gestures: some View {
        let acts = MicButtonAction.available(for: settings.cfg.backend)
        return Section {
            MicGestureCard(gesture: .single, symbol: "waveform", actions: acts,
                           action: settings.bind(\.singleAction), customKey: settings.bind(\.singleCustomKey))
            MicGestureCard(gesture: .double, symbol: "speaker.slash", actions: acts,
                           action: settings.bind(\.doubleAction), customKey: settings.bind(\.doubleCustomKey))
            MicGestureCard(gesture: .triple, symbol: "camera", actions: acts,
                           action: settings.bind(\.tripleAction), customKey: settings.bind(\.tripleCustomKey))
        } header: {
            // 发射器展示卡放在分组标题里:标题没有分组底色,卡片周围不会出现灰底
            VStack(alignment: .leading, spacing: 16) {
                MicHeroPanel(compact: true)
                    .frame(height: 250)
                    .frame(maxWidth: .infinity)
                Text(settings.cfg.backend == .shiyi ? "按键映射 · 拾忆" : "按键映射 · 外部输入法")
                    .font(.headline)
            }
            .foregroundStyle(.primary)
            .textCase(nil)
        } footer: {
            Text(engine.statusLine)
        }
    }
}

// MARK: - 手势行

/// 按键映射里的一行：图标 + 手势名 + 右侧选择动作（按发射器时图标会亮一下）
struct MicGestureCard: View {
    let gesture: MicGesture
    let symbol: String
    var actions: [MicButtonAction] = MicButtonAction.allCases
    @Binding var action: MicButtonAction
    @Binding var customKey: String
    @EnvironmentObject var model: MicUIModel

    private var flashing: Bool { model.flashing == gesture }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(flashing ? Color.white : MicTheme.accent)
                    .frame(width: 26, height: 26)
                    .background(MicTheme.accent.opacity(flashing ? 0.95 : 0.14), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .scaleEffect(flashing ? 1.12 : 1)
                    .animation(.spring(response: 0.3, dampingFraction: 0.6), value: flashing)
                Text(gesture.title)
                Spacer(minLength: 8)
                Menu {
                    ForEach(actions) { a in
                        Button { action = a } label: { Label(a.title, systemImage: a.symbol) }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: action.symbol).font(.system(size: 11.5, weight: .medium))
                        Text(action.shortTitle)
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            if action == .customKey {
                HStack {
                    Image(systemName: "keyboard").foregroundStyle(.secondary)
                    MicKeyField(id: "custom-\(gesture.rawValue)", placeholder: "组合键,如 alt+space", text: $customKey, width: 220)
                }
            }
        }
    }
}

// MARK: - 设置面板组件

/// 一组设置：原生分组（Section），要放在表单里
struct MicPanel<Content: View, Trailing: View>: View {
    var title: String?
    @ViewBuilder var trailing: () -> Trailing
    @ViewBuilder var content: () -> Content

    var body: some View {
        if let title {
            Section { content() } header: {
                HStack {
                    Text(title)
                    Spacer()
                    trailing()
                }
            }
        } else {
            Section { content() }
        }
    }
}

extension MicPanel where Trailing == EmptyView {
    init(title: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.trailing = { EmptyView() }
        self.content = content
    }
}

/// 一行：左边标题（需要时加一行灰色说明），右边放控件。`divider` 已不再使用（分隔线由表单自动画），只为兼容旧调用。
struct MicRow<Control: View>: View {
    let title: String
    var subtitle: String?
    var divider = true
    @ViewBuilder var control: () -> Control

    var body: some View {
        LabeledContent {
            control()
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let subtitle {
                    Text(subtitle).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// 数值 + 步进器（值写在左边，步进箭头在右边）
struct MicStepper: View {
    let text: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    let step: Int

    var body: some View {
        HStack(spacing: 8) {
            Text(text).monospacedDigit().foregroundStyle(.secondary)
            Stepper("", value: $value, in: range, step: step).labelsHidden()
        }
    }
}

/// 带「录制」按钮的按键输入框:点录制后直接按下想要的组合键(或单独的修饰键)。
struct MicKeyField: View {
    let id: String
    let placeholder: String
    @Binding var text: String
    var append = false
    var width: CGFloat = 140
    @ObservedObject private var recorder = MicKeyRecorder.shared

    private var recording: Bool { recorder.activeID == id }

    var body: some View {
        HStack(spacing: 6) {
            TextField("", text: $text, prompt: Text(placeholder))
                .labelsHidden()
                .textFieldStyle(.plain).multilineTextAlignment(.trailing)
                .font(.system(size: 12.5).monospaced())
                .frame(width: width)
                .disabled(recording)
            Button {
                if recording {
                    recorder.cancel()
                } else {
                    recorder.begin(id: id) { result in
                        if append, !text.trimmingCharacters(in: .whitespaces).isEmpty {
                            text += ", " + result
                        } else {
                            text = result
                        }
                    }
                }
            } label: {
                Image(systemName: recording ? "record.circle" : "keyboard.badge.ellipsis")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(recording ? Color.red : Color.accentColor)
                    .frame(width: 22, height: 20)
            }
            .buttonStyle(.borderless)
            .help(recording ? "按 Esc 取消录制" : (append ? "录制：追加一个按键到序列末尾" : "录制：点一下，然后直接按下想要的按键"))
        }
    }
}

struct MicPresetField: View {
    let id: String
    let placeholder: String
    @Binding var text: String
    var append = false
    let presets: [(String, String)]

    var body: some View {
        HStack(spacing: 8) {
            MicKeyField(id: id, placeholder: placeholder, text: $text, append: append)
            Menu {
                ForEach(presets, id: \.1) { p in
                    Button(p.0) { text = p.1 }
                }
            } label: {
                Image(systemName: "list.bullet")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("预设")
        }
    }
}

// MARK: - 标签页:语音输入

struct MicVoiceTab: View {
    @EnvironmentObject var engine: MicEngine
    @EnvironmentObject var settings: MicSettingsStore

    /// 手动测试:标题行右侧的三个图标按钮(悬停显示名称)
    private var testButtons: some View {
        HStack(spacing: 4) {
            MicTestButton(title: engine.state == .recording ? "停止" : "开始说话", symbol: engine.state == .recording ? "stop.fill" : "mic.fill") { engine.trigger(.voiceToggle) }
            MicTestButton(title: settings.cfg.backend == .shiyi ? "保存" : "发送", symbol: "paperplane.fill") { engine.trigger(.send) }
            MicTestButton(title: settings.cfg.backend == .shiyi ? "取消" : "清除", symbol: "trash") { engine.trigger(.clear) }
        }
    }

    var body: some View {
        Group {
            MicPanel(title: "语音输入", trailing: { testButtons }) {
                MicRow(title: "语音输入对象") {
                    Picker("", selection: settings.bind(\.backend)) {
                        Text("拾忆").tag(MicBackend.shiyi)
                        Text("外部输入法").tag(MicBackend.external)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 190)
                }
                if settings.cfg.backend == .external {
                    MicRow(title: "语音输入法快捷键") {
                        MicPresetField(id: "voiceKey", placeholder: "如 fn", text: settings.bind(\.voiceKey), presets: [
                            ("Fn", "fn"), ("右 Option", "ralt"), ("右 Command", "rcmd"), ("右 Control", "rctrl"),
                            ("Option + 空格", "alt+space"), ("Control + 空格", "ctrl+space"),
                        ])
                    }
                    MicRow(title: "触发方式") {
                        Picker("", selection: settings.bind(\.voiceMode)) {
                            Text("按住说话").tag(MicVoiceMode.hold)
                            Text("免按").tag(MicVoiceMode.tap)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 170)
                    }
                    MicRow(title: "发送键") {
                        MicPresetField(id: "sendKey", placeholder: "如 enter", text: settings.bind(\.sendKey), presets: [
                            ("回车", "enter"), ("⌘ + 回车", "cmd+enter"), ("⇧ + 回车", "shift+enter"), ("⌃ + 回车", "ctrl+enter"),
                        ])
                    }
                    MicRow(title: "清除文字") {
                        MicPresetField(id: "clearKeys", placeholder: "如 cmd+a, backspace", text: settings.bind(\.clearKeys), append: true, presets: [
                            ("全选后删除(输入框)", "cmd+a, backspace"),
                            ("终端:Ctrl+U", "ctrl+u"),
                            ("终端:Ctrl+A, Ctrl+K", "ctrl+a, ctrl+k"),
                        ])
                    }
                }
            }
        }
    }
}

struct MicTestButton: View {
    let title: String
    let symbol: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 22, height: 20)
        }
        .buttonStyle(.borderless)
        .help(title)
    }
}

// MARK: - 标签页:时序与行为

struct MicBehaviorTab: View {
    @EnvironmentObject var settings: MicSettingsStore
    @StateObject private var loginItem = MicLoginItem()

    var body: some View {
        Group {
            MicPanel(title: "行为") {
                MicRow(title: "单击时的降噪") {
                    Picker("", selection: settings.bind(\.noiseLock)) {
                        ForEach(MicNoiseLock.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                }
                if settings.cfg.backend == .external {
                    MicRow(title: "解除静音的双击不触发动作") {
                        Toggle("", isOn: settings.bind(\.unmuteDoubleSkipsAction)).labelsHidden().toggleStyle(.switch)
                    }
                    MicRow(title: "同步系统录音状态") {
                        Toggle("", isOn: settings.bind(\.syncWithMic)).labelsHidden().toggleStyle(.switch)
                    }
                }
                MicRow(title: "屏幕顶部状态提示") {
                    Toggle("", isOn: settings.bind(\.showHUD)).labelsHidden().toggleStyle(.switch)
                }
                MicRow(title: "拾忆开机自动启动") {
                    Toggle("", isOn: Binding(get: { loginItem.enabled }, set: { loginItem.set($0) }))
                        .labelsHidden().toggleStyle(.switch)
                }
            }

            Section {
                MicRow(title: "双击判定窗口") {
                    MicStepper(text: "\(settings.cfg.clickDebounceMs) ms", value: settings.bind(\.clickDebounceMs), range: 60...400, step: 20)
                }
                if settings.cfg.backend == .external {
                    MicRow(title: "发送前等待识别提交") {
                        MicStepper(text: "\(settings.cfg.sendDelayMs) ms", value: settings.bind(\.sendDelayMs), range: 200...3000, step: 100)
                    }
                    MicRow(title: "轻按语音键的时长") {
                        MicStepper(text: "\(settings.cfg.tapHoldMs) ms", value: settings.bind(\.tapHoldMs), range: 30...300, step: 10)
                    }
                    MicRow(title: "最长录音") {
                        MicStepper(text: "\(settings.cfg.maxRecordSeconds) 秒", value: settings.bind(\.maxRecordSeconds), range: 10...600, step: 10)
                    }
                    MicRow(title: "待确认超时复位") {
                        MicStepper(text: "\(settings.cfg.reviewTimeoutSeconds) 秒", value: settings.bind(\.reviewTimeoutSeconds), range: 10...600, step: 10)
                    }
                }
                MicRow(title: "按键轮询间隔") {
                    MicStepper(text: "\(settings.cfg.pollMs) ms", value: settings.bind(\.pollMs), range: 20...200, step: 10)
                }
            } header: {
                HStack {
                    Text("时序")
                    Spacer()
                    Button { settings.reset() } label: {
                        Image(systemName: "arrow.counterclockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("恢复默认设置")
                }
            }
        }
    }
}

// MARK: - 标签页:权限与诊断

struct MicSystemTab: View {
    @EnvironmentObject var engine: MicEngine

    var body: some View {
        Group {
            MicPanel(title: "权限") {
                MicPermissionRow(title: "输入监控", subtitle: "", ok: engine.inputMonitoringOK) {
                    engine.requestInputMonitoring()
                }
                MicPermissionRow(title: "辅助功能", subtitle: "", ok: engine.accessibilityOK) {
                    engine.requestAccessibility()
                }
            }

            MicPanel(title: "诊断") {
                MicRow(title: "接收器") {
                    Text(engine.connected ? "已连接 · 固件 \(engine.firmware.isEmpty ? "—" : engine.firmware)" : "未连接")
                        .font(.system(size: 12.5)).foregroundStyle(.secondary)
                }
                MicRow(title: "接收器 ID") { mono(engine.rxID.isEmpty ? "—" : engine.rxID) }
                MicRow(title: "TX1 序列号") { mono(engine.txSerial.isEmpty ? "—" : engine.txSerial) }
                MicRow(title: "系统录音状态") {
                    HStack(spacing: 6) {
                        Circle().fill(engine.micActive ? Color.red : Color.gray.opacity(0.4)).frame(width: 9, height: 9)
                        Text(engine.micActive ? "收音中" : "空闲").font(.system(size: 12.5)).foregroundStyle(.secondary)
                    }
                }
                MicRow(title: "三击通道", subtitle: engine.consumerSeized ? nil : "共享模式:三击可能会同时调高系统音量") {
                    Image(systemName: engine.consumerSeized ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(engine.consumerSeized ? Color.green : Color.orange)
                }
                MicRow(title: "心跳原始数据") { mono(engine.heart.rawHex.isEmpty ? "—" : engine.heart.rawHex) }
            }

            MicPanel(title: "最近事件") {
                VStack(alignment: .leading, spacing: 6) {
                    if engine.eventLog.isEmpty {
                        Text("暂无").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    ForEach(engine.eventLog.suffix(10).reversed()) { line in
                        HStack(spacing: 10) {
                            Text(Self.fmt.string(from: line.time))
                                .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                            Text(line.text).font(.system(size: 12))
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func mono(_ s: String) -> some View {
        Text(s).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary)
            .textSelection(.enabled)
    }

    static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}

struct MicPermissionRow: View {
    let title: String
    let subtitle: String
    let ok: Bool
    var divider = true
    let request: () -> Void

    var body: some View {
        MicRow(title: title, subtitle: subtitle.isEmpty ? nil : subtitle, divider: divider) {
            HStack(spacing: 10) {
                Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(ok ? Color.green : Color.red)
                    .font(.system(size: 17))
                if !ok {
                    SIconButton(symbol: "lock.open", help: "授权", action: request)
                    SIconButton(symbol: "gearshape", help: "打开系统设置") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            }
        }
    }
}
