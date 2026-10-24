import SwiftUI

/// 休息时计时环右边的内容：做一个小动作（内置微运动库，可以跟练倒计时）、听歌（遥控本机的音乐 / Spotify，其他播放器一键打开）、环境音（程序合成的白噪音）。
/// 整块是一张玻璃卡（和「专注什么」一致），里面用分隔线分段；听歌和环境音都是图标按钮。
struct BreakPanel: View {
    @ObservedObject var focus: FocusStore
    /// 两栏时高度由左边的计时环决定，放不下的在卡片里滚动；单列时全部列出
    var fill: Bool

    @ObservedObject private var session = BreakSession.shared
    @ObservedObject private var music = BreakSession.shared.music
    @ObservedObject private var sound = AmbientSound.shared

    private let green = Color(red: 0x4F / 255, green: 0xAE / 255, blue: 0x8B / 255)
    /// 封面做底时：整张卡片用浅色字，强调色换成更亮的薄荷绿，才看得清
    private var onCover: Bool { music.track != nil && music.cover != nil }
    private var secondaryStyle: AnyShapeStyle { onCover ? AnyShapeStyle(Color.white.opacity(0.94)) : AnyShapeStyle(.secondary) }
    private var tertiaryStyle: AnyShapeStyle { onCover ? AnyShapeStyle(Color.white.opacity(0.74)) : AnyShapeStyle(.tertiary) }
    private var accent: Color { onCover ? Color(red: 0.62, green: 0.96, blue: 0.82) : green }

    private var isLong: Bool { focus.shownKind == .longBreak }
    private var move: BreakMove { session.move(for: focus) }
    private var practiceEnd: Date? { session.practiceEnd }

    var body: some View {
        let content = VStack(alignment: .leading, spacing: 16) {
            header
            if let t = music.track { musicCard(t) }
            moveSection
            listenSection
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        let card = Group {
            if fill {
                ScrollView(showsIndicators: false) { content }
            } else {
                content
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: fill ? .infinity : nil, alignment: .topLeading)

        // 有封面时：封面铺满整张「休息一下」卡片做底，上面压一层暗色渐变，里面的字统一用浅色；没有时是普通玻璃卡
        Group {
            if music.track != nil, let cover = music.cover {
                card
                    .foregroundStyle(.white, .white.opacity(0.84), .white.opacity(0.66))
                    .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
                    // 封面铺满后超出卡片的部分只是被裁掉了显示，点击区域还在：会盖住左边计时环右下角的「结束休息」，所以背景不接收点击
                    .background { coverBackground(cover).allowsHitTesting(false) }
                    .environment(\.colorScheme, .dark)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.16), lineWidth: 1))
                    .shadow(color: .black.opacity(0.16), radius: 10, y: 4)
            } else {
                card.glassCard(radius: 14)
            }
        }
        .task {
            session.attach(focus)
            music.refresh()
        }
    }

    /// 磨砂封面：封面放大后高斯模糊，再盖一层半透明的白雾和从上到下加深的暗色，文字才压得住
    private func coverBackground(_ cover: NSImage) -> some View {
        GeometryReader { g in
            ZStack {
                Image(nsImage: cover).resizable().scaledToFill()
                    .frame(width: g.size.width, height: g.size.height).clipped()
                    .scaleEffect(1.04).blur(radius: 7).saturation(1.15)
                    .frame(width: g.size.width, height: g.size.height).clipped()
                Color.white.opacity(0.03)
                LinearGradient(stops: [.init(color: .black.opacity(0.36), location: 0),
                                       .init(color: .black.opacity(0.52), location: 0.45),
                                       .init(color: .black.opacity(0.7), location: 1)],
                               startPoint: .top, endPoint: .bottom)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "leaf.fill").font(.system(size: 12, weight: .semibold)).foregroundStyle(accent)
            Text("休息一下").font(.callout.weight(.semibold))
            Spacer(minLength: 0)
            Text(isLong ? "活动活动身体" : "离开屏幕一会儿").font(.caption).foregroundStyle(tertiaryStyle).lineLimit(1)
        }
    }

    // MARK: - 做个小动作

    private var moveSection: some View {
        let m = move
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: m.icon).font(.system(size: 17, weight: .semibold)).foregroundStyle(accent)
                    .frame(width: 36, height: 36)
                    .background(accent.opacity(onCover ? 0.22 : 0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(m.title).font(.headline).lineLimit(1)
                    HStack(spacing: 6) {
                        TagChip(text: m.area, tint: accent)
                        Text(durationText(m.seconds)).font(.caption).foregroundStyle(tertiaryStyle)
                    }
                }
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(m.steps.enumerated()), id: \.offset) { i, s in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(i + 1)").font(.system(size: 10, weight: .bold)).foregroundStyle(accent)
                            .frame(width: 16, height: 16).background(accent.opacity(onCover ? 0.22 : 0.14), in: Circle())
                        Text(s).font(.callout.weight(onCover ? .medium : .regular)).foregroundStyle(secondaryStyle).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            HStack(spacing: 8) {
                practiceButton(m)
                Button { session.practiceEnd = nil; session.offset += 1 } label: {
                    Label("换一个", systemImage: "arrow.triangle.2.circlepath").font(.callout)
                }
                .buttonStyle(.bordered).tint(onCover ? Color.white : Color.accentColor)
                Spacer(minLength: 0)
            }
        }
    }

    private func durationText(_ s: Int) -> String { s >= 120 ? "\(s / 60) 分钟" : "\(s) 秒" }

    @ViewBuilder private func practiceButton(_ m: BreakMove) -> some View {
        if let end = practiceEnd {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                let left = Int(end.timeIntervalSince(ctx.date).rounded(.up))
                Button {
                    session.practiceEnd = nil
                } label: {
                    Label(left > 0 ? String(format: "%d:%02d", left / 60, left % 60) : "做完了", systemImage: left > 0 ? "stop.fill" : "checkmark")
                        .font(.callout.weight(.semibold)).monospacedDigit()
                }
                .buttonStyle(.borderedProminent).tint(green)
                .help(left > 0 ? "停止跟练" : "好的")
            }
        } else {
            Button {
                session.practiceEnd = Date().addingTimeInterval(Double(m.seconds))
            } label: {
                Label("跟练", systemImage: "play.fill").font(.callout.weight(.semibold))
            }
            .buttonStyle(.borderedProminent).tint(green)
            .help("开始 \(durationText(m.seconds)) 的倒计时")
        }
    }

    // MARK: - 听歌 + 环境音（图标；两个标题放在同一行，放不下时上下排）

    private var listenSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 8) {
                    musicHead
                    Spacer(minLength: 0)
                    soundHead
                }
                VStack(alignment: .leading, spacing: 6) {
                    musicHead
                    soundHead
                }
            }
            musicStatus
            if sound.current != nil {
                HStack(spacing: 6) {
                    Image(systemName: "speaker.fill").font(.caption2).foregroundStyle(tertiaryStyle)
                    Slider(value: $sound.volume, in: 0.05 ... 1).tint(accent).controlSize(.small)
                    Image(systemName: "speaker.wave.3.fill").font(.caption2).foregroundStyle(tertiaryStyle)
                }
            }
        }
    }

    private func sectionTitle(_ icon: String, _ text: String, trailing: String? = nil) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(accent)
            Text(text).font(.callout.weight(.semibold)).lineLimit(1).fixedSize()
            if let trailing { Text(trailing).font(.caption).foregroundStyle(accent).lineLimit(1) }
        }
    }

    /// 听歌：标题 + 本机已安装播放器的图标
    private var musicHead: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionTitle("music.note", "听歌")
            if music.installed.isEmpty {
                Text("没有找到音乐 App").font(.caption).foregroundStyle(tertiaryStyle)
            } else {
                HStack(spacing: 3) {
                    ForEach(music.installed) { a in
                        Button { music.open(a) } label: {
                            Group {
                                if let img = music.icons[a.bundleId] {
                                    Image(nsImage: img).resizable().interpolation(.high)
                                } else {
                                    Image(systemName: "music.note")
                                }
                            }
                            .frame(width: 26, height: 26)
                        }
                        .buttonStyle(.plain)
                        .help(a.script == nil ? "打开 \(a.name)（这个播放器不支持在这里控制）" : "打开 \(a.name)")
                    }
                }
            }
        }
    }

    /// 环境音：标题 + 四个圆形图标
    private var soundHead: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionTitle("waveform", "环境音", trailing: sound.current?.label)
            HStack(spacing: 3) {
                ForEach(AmbientKind.allCases) { k in
                    let on = sound.current == k
                    Button { sound.toggle(k) } label: {
                        Image(systemName: k.icon).font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(on ? Brand.brown : (onCover ? Color.white : Color.secondary))
                            .frame(width: 26, height: 26)
                            .background(on ? accent : (onCover ? Color.white.opacity(0.2) : Color.primary.opacity(0.07)), in: Circle())
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help(on ? "关闭\(k.label)" : "播放\(k.label)")
                }
            }
        }
    }

    /// 正在播放的歌 + 上一首 / 播放暂停 / 下一首
    @ViewBuilder private var musicStatus: some View {
        if music.track == nil, let a = music.idleApp {
            HStack(spacing: 8) {
                Text("\(a.name) 里没有在播放").font(.caption).foregroundStyle(secondaryStyle).lineLimit(1)
                Spacer(minLength: 4)
                mini("play.fill", big: true, help: "在 \(a.name) 里播放") { music.toggle(a) }
            }
        } else if music.denied {
            Text("要先允许「拾忆」控制音乐：系统设置 › 隐私与安全性 › 自动化。").font(.caption).foregroundStyle(secondaryStyle)
                .fixedSize(horizontal: false, vertical: true)
            Button("打开系统设置") { music.openAutomationSettings() }.buttonStyle(.link).font(.caption)
        }
    }

    /// 正在播放：封面已经是整张休息卡片的磨砂底，这里只放歌名、上一首 / 播放暂停 / 下一首和进度条，尽量矮
    private func musicCard(_ t: MusicTrack) -> some View {
        let hasCover = music.cover != nil
        let white: Color = hasCover ? .white : .primary
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(t.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(white).lineLimit(1)
                    .shadow(color: .black.opacity(hasCover ? 0.35 : 0), radius: 3)
                Spacer(minLength: 4)
                HStack(spacing: 4) {
                    mini("backward.fill", dark: hasCover, help: "上一首") { music.previous(t.app) }
                    mini(t.playing ? "pause.fill" : "play.fill", big: true, dark: hasCover, help: t.playing ? "暂停" : "播放") { music.toggle(t.app) }
                    mini("forward.fill", dark: hasCover, help: "下一首") { music.next(t.app) }
                }
            }
            // 进度随时间走：每半秒重画一次
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                let pos = t.position(at: ctx.date)
                if t.duration > 0 {
                    HStack(spacing: 7) {
                        Text(clock(pos))
                        GeometryReader { g in
                            ZStack(alignment: .leading) {
                                Capsule().fill(white.opacity(0.28))
                                Capsule().fill(white).frame(width: g.size.width * min(pos / t.duration, 1))
                            }
                        }
                        .frame(height: 3)
                        Text(clock(t.duration))
                    }
                    .font(.system(size: 9)).foregroundStyle(white.opacity(0.85)).monospacedDigit()
                }
            }
            if music.needsAccessibility {
                Button { music.openAccessibilitySettings() } label: {
                    Text("授权辅助功能以控制 ›").font(.system(size: 11)).foregroundStyle(.white)
                        .padding(.horizontal, 9).padding(.vertical, 3)
                        .background(Brand.orange.opacity(0.9), in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func clock(_ s: Double) -> String {
        let n = Int(max(s, 0))
        return String(format: "%d:%02d", n / 60, n % 60)
    }

    private func mini(_ icon: String, big: Bool = false, dark: Bool = false, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: big ? 8 : 7, weight: .bold))
                .foregroundStyle(dark ? (big ? Color.black.opacity(0.8) : Color.white) : (big ? Brand.brown : Color.primary))
                .frame(width: big ? 18 : 15, height: big ? 18 : 15)
                .background(dark ? (big ? Color.white : Color.white.opacity(0.2)) : (big ? green : Color.primary.opacity(0.08)), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
