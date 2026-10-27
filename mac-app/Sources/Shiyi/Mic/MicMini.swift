import SwiftUI

/// 小发射器徽标:有光晕、录音时的红色涟漪、按键时的黄色涟漪。
/// 菜单栏弹窗和语音面板里用,和「猛犸麦克风」设置页是同一套动画语言。
struct MicMiniTX: View {
    @ObservedObject private var engine = MicEngine.shared
    var height: CGFloat = 32
    @State private var rippleStart = Date.distantPast
    @State private var rippleKind: MicGesture = .single
    @State private var rippling = false
    @State private var rippleTask: Task<Void, Never>?

    private var online: Bool { engine.connected && engine.heart.anyOnline }
    private var recording: Bool { engine.state == .recording }

    private var glow: Color {
        if !online { return .gray }
        if recording { return .red }
        if engine.heart.anyMuted { return .orange }
        return MicTheme.accent
    }

    var body: some View {
        let w = height * 732 / 1352
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !(recording || rippling))) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            ZStack {
                Circle()
                    .fill(glow.opacity(online ? 0.40 : 0.18))
                    .frame(width: height * 0.95, height: height * 0.95)
                    .blur(radius: height * 0.22)
                    .scaleEffect(recording ? 1 + 0.08 * sin(t * 5) : 1)
                if recording {
                    ForEach(0..<2, id: \.self) { i in
                        let p = (t * 0.8 + Double(i) / 2).truncatingRemainder(dividingBy: 1)
                        Circle()
                            .stroke(Color.red.opacity((1 - p) * 0.55), lineWidth: 1.5)
                            .frame(width: height * (0.7 + 0.9 * p), height: height * (0.7 + 0.9 * p))
                    }
                }
                ZStack(alignment: .topLeading) {
                    if let img = MicTheme.txImage {
                        Image(nsImage: img).resizable().interpolation(.high)
                            .frame(width: w, height: height)
                            .opacity(online ? 1 : 0.45)
                    } else {
                        RoundedRectangle(cornerRadius: 5).fill(.black).frame(width: w, height: height)
                    }
                    let ax = w * MicTheme.buttonAnchor.x
                    let ay = height * MicTheme.buttonAnchor.y
                    let count = rippleKind == .single ? 1 : (rippleKind == .double ? 2 : 3)
                    ForEach(0..<count, id: \.self) { i in
                        let p = ctx.date.timeIntervalSince(rippleStart) / 0.8 - Double(i) * 0.22
                        if p >= 0 && p <= 1 {
                            Circle()
                                .stroke(MicTheme.yellow.opacity(1 - p), lineWidth: 2)
                                .frame(width: 4 + height * 0.7 * p, height: 4 + height * 0.7 * p)
                                .position(x: ax, y: ay)
                        }
                    }
                }
                .frame(width: w, height: height)
            }
            .frame(width: height * 1.5, height: height * 1.2)
        }
        .frame(width: height * 1.5, height: height * 1.2)
        .onChange(of: engine.lastGesture) { g in
            guard let g else { return }
            rippleKind = g.kind
            rippleStart = Date()
            rippling = true
            rippleTask?.cancel()
            rippleTask = Task {
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                if !Task.isCancelled { rippling = false }
            }
        }
    }
}

/// 菜单栏弹窗顶部的一条:发射器 + 状态 + 电量 + 降噪。接收器没插时不显示。
struct MicStrip: View {
    @ObservedObject private var engine = MicEngine.shared
    @ObservedObject private var settings = MicSettingsStore.shared

    private var online: Bool { engine.connected && engine.heart.anyOnline }

    private var statusText: String {
        if !engine.heart.anyOnline { return "发射器未开机" }
        if engine.state == .recording { return "录音中" }
        if engine.heart.anyMuted { return "已静音" }
        return "收音中"
    }

    private var statusColor: Color {
        if !online { return .secondary }
        if engine.state == .recording { return .red }
        if engine.heart.anyMuted { return .orange }
        return MicTheme.accent
    }

    var body: some View {
        if engine.connected {
            HStack(spacing: 8) {
                MicMiniTX(height: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text("LARK A2").font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    HStack(spacing: 4) {
                        Circle().fill(statusColor).frame(width: 6, height: 6)
                        Text(statusText).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    .animation(.easeInOut(duration: 0.25), value: statusText)
                }
                Spacer(minLength: 4)
                if online {
                    HStack(spacing: 4) {
                        Image(systemName: engine.heart.tx1Charging ? "battery.100.bolt" : "battery.75")
                            .foregroundStyle(engine.heart.tx1Battery > 20 || engine.heart.tx1Charging ? Color.green : Color.red)
                        Text("\(engine.heart.tx1Battery)%").monospacedDigit()
                    }
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    MicStripLevel(level: engine.heart.noise)
                }
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        settings.cfg.backend = settings.cfg.backend == .shiyi ? .external : .shiyi
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: settings.cfg.backend == .shiyi ? "waveform" : "keyboard").font(.system(size: 10, weight: .semibold))
                        Text(settings.cfg.backend == .shiyi ? "拾忆" : "外部").font(.system(size: 11, weight: .semibold))
                    }
                    .fixedSize()
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(Capsule().fill(MicTheme.accent.opacity(0.14)))
                    .foregroundStyle(MicTheme.accent)
                }
                .buttonStyle(.plain)
                .help(settings.cfg.backend == .shiyi ? "语音输入:拾忆(点击切换到外部输入法)" : "语音输入:外部输入法(点击切换到拾忆)")
                Button { MicWindow.show() } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .background(Color.primary.opacity(0.06), in: Circle())
                }
                .buttonStyle(.plain)
                .help("猛犸麦克风按键设置")
            }
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background(MicTheme.accent.opacity(0.06))
            Divider()
        }
    }
}

/// 菜单栏小条里的降噪档位:三根小柱子
private struct MicStripLevel: View {
    let level: Int
    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<3, id: \.self) { i in
                Capsule()
                    .fill(i < level ? MicTheme.accent : Color.primary.opacity(0.2))
                    .frame(width: 3, height: CGFloat(6 + i * 3))
            }
        }
        .frame(width: 13, height: 12, alignment: .bottom)
        .help("降噪档位")
    }
}
