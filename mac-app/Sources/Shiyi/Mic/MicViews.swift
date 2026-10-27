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
                .shadow(color: .black.opacity(scheme == .dark ? 0.4 : 0.12), radius: compact ? 16 : 24, y: compact ? 6 : 10)

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

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            gestures
            tabs
            Group {
                switch model.tab {
                case .voice: MicVoiceTab()
                case .behavior: MicBehaviorTab()
                case .system: MicSystemTab()
                }
            }
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("按键映射")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                Text(engine.statusLine)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var gestures: some View {
        VStack(spacing: 8) {
            MicGestureCard(index: 0, gesture: .single, symbol: "waveform",
                        factory: "出厂:切换降噪",
                        note: "静音状态下单击无效(固件不上报);" + (settings.cfg.noiseLock == .off ? "未静音时生效" : "未静音时生效,且不会再改变降噪"),
                        action: settings.bind(\.singleAction), customKey: settings.bind(\.singleCustomKey))
            MicGestureCard(index: 1, gesture: .double, symbol: "speaker.slash",
                        factory: "出厂:开关静音",
                        note: settings.cfg.doubleAction == .voiceToggle
                            ? (settings.cfg.backend == .shiyi
                               ? "静音即录音开关:解除静音=开始说话(预览中=说话修改),静音=结束"
                               : "静音即录音开关:未静音=说话中,静音=已停止")
                            : "硬件行为,无法改写;静音状态下无法收音",
                        action: settings.bind(\.doubleAction), customKey: settings.bind(\.doubleCustomKey))
            MicGestureCard(index: 2, gesture: .triple, symbol: "camera",
                        factory: "出厂:启停拍摄(音量+)",
                        note: settings.cfg.backend == .shiyi ? "预览中=确认保存,录音中=结束" : "已独占该按键,不会影响系统音量",
                        action: settings.bind(\.tripleAction), customKey: settings.bind(\.tripleCustomKey))
        }
    }

    private var tabs: some View {
        HStack(spacing: 6) {
            ForEach(MicUIModel.Tab.allCases) { tab in
                let selected = model.tab == tab
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { model.tab = tab }
                } label: {
                    Label(tab.rawValue, systemImage: tab.symbol)
                        .font(.system(size: 13, weight: selected ? .semibold : .regular))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Capsule().fill(selected ? MicTheme.accent : Color.primary.opacity(0.06)))
                        .foregroundStyle(selected ? Color.white : Color.primary)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }
}

// MARK: - 手势卡片

struct MicGestureCard: View {
    let index: Int
    let gesture: MicGesture
    let symbol: String
    let factory: String
    let note: String?
    @Binding var action: MicButtonAction
    @Binding var customKey: String
    @EnvironmentObject var model: MicUIModel

    private var hovered: Bool { model.hovered == gesture }
    private var flashing: Bool { model.flashing == gesture }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(MicTheme.accent.opacity(flashing ? 0.95 : 0.12))
                    Image(systemName: symbol)
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(flashing ? Color.white : MicTheme.accent)
                        .scaleEffect(flashing ? 1.15 : 1)
                }
                .frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(gesture.title)
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                        Text(factory)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    if let note {
                        Text(note)
                            .font(.system(size: 10))
                            .foregroundStyle(Color.orange)
                    }
                }
                Spacer(minLength: 8)

                Menu {
                    ForEach(MicButtonAction.allCases) { a in
                        Button { action = a } label: { Label(a.title, systemImage: a.symbol) }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: action.symbol).font(.system(size: 11.5, weight: .semibold))
                        Text(action.shortTitle).font(.system(size: 12, weight: .semibold))
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .bold)).opacity(0.6)
                    }
                    .padding(.horizontal, 11).padding(.vertical, 6)
                    .background(Capsule().fill(MicTheme.accent.opacity(0.12)))
                    .foregroundStyle(MicTheme.accent)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            if action == .customKey {
                HStack {
                    Image(systemName: "keyboard").foregroundStyle(.secondary)
                    MicKeyField(id: "custom-\(gesture.rawValue)", placeholder: "组合键,如 alt+space", text: $customKey, width: 220)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(hovered ? 0.16 : 0.06), radius: hovered ? 16 : 8, y: hovered ? 8 : 3)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(MicTheme.accent.opacity(flashing ? 0.9 : 0), lineWidth: 2)
        )
        .overlay(alignment: .topTrailing) {
            if flashing {
                Text("已触发")
                    .font(.system(size: 10, weight: .bold))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(MicTheme.accent))
                    .foregroundStyle(.white)
                    .padding(8)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .scaleEffect(flashing ? 1.015 : (hovered ? 1.008 : 1))
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.18)) { model.hovered = inside ? gesture : (model.hovered == gesture ? nil : model.hovered) }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: action)
        .opacity(model.appeared ? 1 : 0)
        .offset(y: model.appeared ? 0 : 26)
        .animation(.spring(response: 0.6, dampingFraction: 0.82).delay(Double(index) * 0.08), value: model.appeared)
    }
}

// MARK: - 设置面板组件

struct MicPanel<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(spacing: 0) { content() }
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.primary.opacity(0.05)))
    }
}

struct MicRow<Control: View>: View {
    let title: String
    var subtitle: String?
    var divider = true
    @ViewBuilder var control: () -> Control

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 13.5, weight: .medium))
                    if let subtitle {
                        Text(subtitle).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 12)
                control().layoutPriority(1)
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
            if divider { Divider().padding(.leading, 18) }
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
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
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
                HStack(spacing: 5) {
                    Image(systemName: recording ? "record.circle" : "keyboard.badge.ellipsis")
                    Text(recording ? "请按键…" : (append ? "追加" : "录制")).lineLimit(1)
                }
                .fixedSize()
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Capsule().fill(recording ? Color.red.opacity(0.18) : MicTheme.accent.opacity(0.12)))
                .foregroundStyle(recording ? Color.red : MicTheme.accent)
            }
            .buttonStyle(.plain)
            .help(recording ? "按 Esc 取消录制" : (append ? "追加一个按键到序列末尾" : "点一下,然后直接按下想要的按键"))
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
            Menu("预设") {
                ForEach(presets, id: \.1) { p in
                    Button(p.0) { text = p.1 }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .lineLimit(1)
        }
    }
}

// MARK: - 标签页:语音输入

struct MicVoiceTab: View {
    @EnvironmentObject var engine: MicEngine
    @EnvironmentObject var settings: MicSettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            MicPanel {
                MicRow(title: "语音输入对象",
                       subtitle: settings.cfg.backend == .shiyi
                           ? "按键直接驱动拾忆的语音输入:录音 → 识别 → AI 整理 → 预览 → 入库,状态与拾忆完全同步"
                           : "按键通过模拟按键唤起豆包、Typeless、闪电说等输入法,文字直接上屏到当前输入框",
                       divider: settings.cfg.backend == .external) {
                    Picker("", selection: settings.bind(\.backend)) {
                        Text("拾忆").tag(MicBackend.shiyi)
                        Text("外部输入法").tag(MicBackend.external)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 190)
                }
                if settings.cfg.backend == .external {
                    MicRow(title: "语音输入法快捷键",
                        subtitle: "豆包、Typeless、闪电说等:填它们设置里的语音快捷键。修饰键 cmd/shift/alt/ctrl/fn,右侧加 r 前缀") {
                        MicPresetField(id: "voiceKey", placeholder: "如 fn", text: settings.bind(\.voiceKey), presets: [
                            ("Fn", "fn"), ("右 Option", "ralt"), ("右 Command", "rcmd"), ("右 Control", "rctrl"),
                            ("Option + 空格", "alt+space"), ("Control + 空格", "ctrl+space"),
                        ])
                    }
                    MicRow(title: "触发方式", subtitle: "按住说话:单击开始时按下、停止时松开。免按:每次只轻按一下") {
                        Picker("", selection: settings.bind(\.voiceMode)) {
                            Text("按住说话").tag(MicVoiceMode.hold)
                            Text("免按").tag(MicVoiceMode.tap)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 170)
                    }
                    MicRow(title: "发送键", subtitle: "发送手势执行时按下的键") {
                        MicPresetField(id: "sendKey", placeholder: "如 enter", text: settings.bind(\.sendKey), presets: [
                            ("回车", "enter"), ("⌘ + 回车", "cmd+enter"), ("⇧ + 回车", "shift+enter"), ("⌃ + 回车", "ctrl+enter"),
                        ])
                    }
                    MicRow(title: "清除文字", subtitle: "按键序列用逗号分隔", divider: false) {
                        MicPresetField(id: "clearKeys", placeholder: "如 cmd+a, backspace", text: settings.bind(\.clearKeys), append: true, presets: [
                            ("全选后删除(输入框)", "cmd+a, backspace"),
                            ("终端:Ctrl+U", "ctrl+u"),
                            ("终端:Ctrl+A, Ctrl+K", "ctrl+a, ctrl+k"),
                        ])
                    }
                }
            }

            if settings.cfg.backend == .shiyi {
                MicPanel {
                    MicRow(title: "识别引擎、整理方式、倒计时等",
                           subtitle: "这些仍然在拾忆的「设置 → 语音输入」里设置,按键和界面入口共用同一套",
                           divider: false) {
                        Button("打开语音输入设置") { SettingsWindow.show(.voice) }
                            .controlSize(.small)
                    }
                }
            }

            MicPanel {
                MicRow(title: "手动测试", subtitle: "不用按发射器,直接验证上面的设置", divider: false) {
                    HStack(spacing: 8) {
                        MicTestButton(title: engine.state == .recording ? "停止" : "开始说话", symbol: "mic.fill") { engine.trigger(.voiceToggle) }
                        MicTestButton(title: settings.cfg.backend == .shiyi ? "保存" : "发送", symbol: "paperplane.fill") { engine.trigger(.send) }
                        MicTestButton(title: settings.cfg.backend == .shiyi ? "取消" : "清除", symbol: "trash") { engine.trigger(.clear) }
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
            Label(title, systemImage: symbol)
                .font(.system(size: 12.5, weight: .semibold))
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(Capsule().fill(Color.primary.opacity(0.07)))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 标签页:时序与行为

struct MicBehaviorTab: View {
    @EnvironmentObject var settings: MicSettingsStore
    @StateObject private var loginItem = MicLoginItem()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            MicPanel {
                MicRow(title: "单击时的降噪", subtitle: "固件会在单击时切换降噪,这里可以让它保持不变") {
                    Picker("", selection: settings.bind(\.noiseLock)) {
                        ForEach(MicNoiseLock.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 250)
                }
                if settings.cfg.backend == .external {
                    MicRow(title: "解除静音的双击不触发动作", subtitle: "避免双击仅为解除静音时误执行映射动作") {
                        Toggle("", isOn: settings.bind(\.unmuteDoubleSkipsAction)).labelsHidden().toggleStyle(.switch)
                    }
                    MicRow(title: "同步系统录音状态", subtitle: "以系统的「麦克风使用中」为准:输入法自己停止时界面同步,并等它真正开始收音再提示可以说话") {
                        Toggle("", isOn: settings.bind(\.syncWithMic)).labelsHidden().toggleStyle(.switch)
                    }
                }
                MicRow(title: "屏幕顶部状态提示", subtitle: "全程无声,只在屏幕顶部显示") {
                    Toggle("", isOn: settings.bind(\.showHUD)).labelsHidden().toggleStyle(.switch)
                }
                MicRow(title: "拾忆开机自动启动", subtitle: "麦克风按键只有在拾忆运行时才有效", divider: false) {
                    Toggle("", isOn: Binding(get: { loginItem.enabled }, set: { loginItem.set($0) }))
                        .labelsHidden().toggleStyle(.switch)
                }
            }

            MicPanel {
                MicRow(title: "双击判定窗口", subtitle: "两次点击间隔小于该值才算双击") {
                    Stepper("\(settings.cfg.clickDebounceMs) ms", value: settings.bind(\.clickDebounceMs), in: 60...400, step: 20)
                }
                if settings.cfg.backend == .external {
                    MicRow(title: "发送前等待识别提交", subtitle: "停止说话后,等输入法把文字写入输入框") {
                        Stepper("\(settings.cfg.sendDelayMs) ms", value: settings.bind(\.sendDelayMs), in: 200...3000, step: 100)
                    }
                    MicRow(title: "轻按语音键的时长", subtitle: "免按模式下按键按下到松开的时间,识别不触发时可调大") {
                        Stepper("\(settings.cfg.tapHoldMs) ms", value: settings.bind(\.tapHoldMs), in: 30...300, step: 10)
                    }
                    MicRow(title: "最长录音") {
                        Stepper("\(settings.cfg.maxRecordSeconds) 秒", value: settings.bind(\.maxRecordSeconds), in: 10...600, step: 10)
                    }
                    MicRow(title: "待确认超时复位") {
                        Stepper("\(settings.cfg.reviewTimeoutSeconds) 秒", value: settings.bind(\.reviewTimeoutSeconds), in: 10...600, step: 10)
                    }
                }
                MicRow(title: "按键轮询间隔", divider: false) {
                    Stepper("\(settings.cfg.pollMs) ms", value: settings.bind(\.pollMs), in: 20...200, step: 10)
                }
            }

            Button(role: .destructive) { settings.reset() } label: {
                Label("恢复默认设置", systemImage: "arrow.uturn.backward")
                    .font(.system(size: 12.5, weight: .semibold))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Capsule().fill(Color.red.opacity(0.12)))
                    .foregroundStyle(Color.red)
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - 标签页:权限与诊断

struct MicSystemTab: View {
    @EnvironmentObject var engine: MicEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            MicPanel {
                MicPermissionRow(title: "输入监控", subtitle: "读取麦克风按键", ok: engine.inputMonitoringOK) {
                    engine.requestInputMonitoring()
                }
                MicPermissionRow(title: "辅助功能", subtitle: "外部输入法模式(模拟按键)与录制按键需要", ok: engine.accessibilityOK, divider: false) {
                    engine.requestAccessibility()
                }
            }

            MicPanel {
                MicRow(title: "接收器", subtitle: "USB 3547:0411") {
                    Text(engine.connected ? "已连接 · 固件 \(engine.firmware.isEmpty ? "—" : engine.firmware)" : "未连接")
                        .font(.system(size: 12.5)).foregroundStyle(.secondary)
                }
                MicRow(title: "接收器 ID") { mono(engine.rxID.isEmpty ? "—" : engine.rxID) }
                MicRow(title: "TX1 序列号") { mono(engine.txSerial.isEmpty ? "—" : engine.txSerial) }
                MicRow(title: "系统录音状态", subtitle: "默认输入设备是否在收音(拾忆或输入法录音时为开)") {
                    HStack(spacing: 6) {
                        Circle().fill(engine.micActive ? Color.red : Color.gray.opacity(0.4)).frame(width: 9, height: 9)
                        Text(engine.micActive ? "收音中" : "空闲").font(.system(size: 12.5)).foregroundStyle(.secondary)
                    }
                }
                MicRow(title: "三击通道", subtitle: engine.consumerSeized ? "已独占:三击不会同时调高系统音量" : "共享模式:三击可能会同时调高系统音量") {
                    Image(systemName: engine.consumerSeized ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(engine.consumerSeized ? Color.green : Color.orange)
                }
                MicRow(title: "心跳原始数据", divider: false) { mono(engine.heart.rawHex.isEmpty ? "—" : engine.heart.rawHex) }
            }

            MicPanel {
                VStack(alignment: .leading, spacing: 6) {
                    Text("最近事件").font(.system(size: 13.5, weight: .medium))
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
                .padding(18)
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
        MicRow(title: title, subtitle: subtitle, divider: divider) {
            HStack(spacing: 10) {
                Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(ok ? Color.green : Color.red)
                    .font(.system(size: 17))
                if !ok {
                    Button("授权", action: request).buttonStyle(.borderedProminent).controlSize(.small)
                    Button("系统设置") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .controlSize(.small)
                }
            }
        }
    }
}
