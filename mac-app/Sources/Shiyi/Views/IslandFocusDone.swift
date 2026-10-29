import AppKit
import SwiftUI

/*
 * 番茄完成后的「专注终端」：岛左右拉宽到 780pt，整座岛是一台复古终端。
 * 左仓：出纸口 + 在岛里打印出来的成果小票（右键可保存图片 / 复制）。
 * 右仓：休息一下的跟练卡——动作 + 绿色读数 + 进度线、三步说明、开始跟练 / 换一个 / 开始休息。
 * 跟练进行中岛不会自动收起；收起后再点岛（或悬停）会回到这里（见 IslandController.expand）。
 */

struct IslandFocusDoneView: View {
    @ObservedObject var state: IslandState
    @ObservedObject var focus: FocusStore
    let ticket: Celebration
    let activity: IslandActivity

    @ObservedObject private var session = BreakSession.shared
    @State private var printed: Bool

    static let ticketWidth: CGFloat = 310
    static let ticketRecords = 1

    private typealias P = TicketPalette
    private let keyTop = Color(hex: 0x3A322B)
    private let keyBottom = Color(hex: 0x241E19)
    private let keyEdge = Color(hex: 0x4A4037)
    private let keyShadow = Color(hex: 0x0C0A08)
    /// 磷光绿：读数、进度线、主键都用它，接近「休息」的状态
    private let phosphor = Color(hex: 0x6FDC9A)

    init(state: IslandState, focus: FocusStore, ticket: Celebration, activity: IslandActivity) {
        self.state = state
        self.focus = focus
        self.ticket = ticket
        self.activity = activity
        // 从收起状态点回来时，小票已经打印过了，不再重放
        _printed = State(initialValue: state.printedTicketId == ticket.id)
    }

    var body: some View {
        let chassis = RoundedRectangle(cornerRadius: 22, style: .continuous)
        VStack(spacing: 0) {
            header.frame(height: state.topInset)
            HStack(spacing: 0) {
                leftBay.frame(maxWidth: .infinity)
                divider
                rightBay.frame(maxWidth: .infinity)
            }
            .frame(height: state.terminalBodyHeight)
            .background(chassis.fill(LinearGradient(colors: [P.termTop, P.termBottom], startPoint: .top, endPoint: .bottom)))
            .clipShape(chassis)
            .overlay(chassis.strokeBorder(P.termEdge, lineWidth: 1))
            .padding(.horizontal, 14).padding(.bottom, 14)
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .task {
            guard !printed else { return }
            // 等岛拉宽、停稳，再出纸
            try? await Task.sleep(nanoseconds: 450_000_000)
            TicketController.shared.playPrintSound()
            withAnimation(.timingCurve(0.1, 0.55, 0.2, 1, duration: 1.1)) { printed = true }
            state.printedTicketId = ticket.id
        }
    }

    // MARK: 顶部（刘海两侧）

    private var header: some View {
        HStack(spacing: 0) {
            Text("拾忆 × 专注终端")
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced)).tracking(1.2)
                .foregroundStyle(P.termMute)
                .padding(.leading, 30)
            Spacer(minLength: state.notchWidth)
            HStack(spacing: 8) {
                Circle().fill(P.termGreen).frame(width: 6, height: 6)
                Text("番茄完成 · \(ticket.minutes) 分钟").font(.system(size: 12, weight: .bold)).foregroundStyle(P.termGreen)
                if focus.run == nil, focus.pendingBreak != nil {
                    // 休息前再多专注几分钟：直接接着再专注选定的分钟数
                    Menu {
                        ForEach([5, 10, 15, 25], id: \.self) { m in
                            Button("再专注 \(m) 分钟") { state.onActivityAction?(activity, .extend(m)) }
                        }
                    } label: {
                        Label("多专注", systemImage: "plus.circle")
                            .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(P.termMute)
                            .padding(.horizontal, 8).frame(height: 20)
                            .background(Color.white.opacity(0.08), in: Capsule())
                            .contentShape(Capsule())
                    }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                    .help("先不休息，再多专注几分钟")
                    Button { state.onActivityAction?(activity, .secondary) } label: {
                        Label("跳过休息", systemImage: "forward.fill")
                            .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(P.termMute)
                            .padding(.horizontal, 8).frame(height: 20)
                            .background(Color.white.opacity(0.08), in: Capsule())
                    }
                    .buttonStyle(.plain).help("跳过休息，继续专注")
                }
            }
            .padding(.trailing, 30)
        }
    }

    /// 两仓之间一根细线，上下渐隐
    private var divider: some View {
        Rectangle()
            .fill(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: Color(hex: 0x3A3028), location: 0.12),
                                         .init(color: Color(hex: 0x3A3028), location: 0.88), .init(color: .clear, location: 1)],
                                 startPoint: .top, endPoint: .bottom))
            .frame(width: 1)
    }

    // MARK: 左仓：出纸 + 小票

    private var leftBay: some View {
        VStack(spacing: 0) {
            Capsule().fill(Color(hex: 0x030202))
                .overlay(Capsule().strokeBorder(Color(hex: 0x3A3028), lineWidth: 0.5))
                .frame(width: 200, height: 6)
                .shadow(color: .black.opacity(0.8), radius: 2.5, y: 2)
                .zIndex(1)
            // 裁剪区：小票从出纸口下面一点点滑出来，上沿始终藏在出纸口后面
            ResultTicketView(c: ticket, width: Self.ticketWidth, maxRecords: Self.ticketRecords, compact: true)
                .shadow(color: .black.opacity(0.4), radius: 7, y: 4)
                .offset(y: printed ? 0 : -(state.ticketH + 24))
                .frame(width: Self.ticketWidth + 24, height: state.ticketH + 10, alignment: .top)
                .clipped()
                .padding(.top, -3)
                .contextMenu {
                    Button("保存图片") { _ = TicketExporter.save(ticket) }
                    Button("复制") { _ = TicketExporter.copy(ticket) }
                }
            Spacer(minLength: 0)
        }
        .padding(.top, 12).padding(.bottom, 10)
    }

    /// 键帽：26pt 高，一圈细边加底部 1.5pt 的厚度，够认出是实体键又不压过内容
    private func keycap() -> some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        return ZStack {
            shape.fill(keyShadow).offset(y: 1.5)
            shape.fill(LinearGradient(colors: [keyTop, keyBottom], startPoint: .top, endPoint: .bottom))
            shape.strokeBorder(keyEdge, lineWidth: 1)
        }
    }

    private func keyLabel(_ icon: String?, _ text: String, muted: Bool = false) -> some View {
        HStack(spacing: 5) {
            if let icon { Image(systemName: icon).font(.system(size: 10, weight: .semibold)) }
            Text(text).font(.system(size: 11.5, weight: .semibold)).monospacedDigit()
        }
        .foregroundStyle(muted ? P.termMute : Color(hex: 0xE8DFD3))
        .padding(.horizontal, 11).frame(height: 28)
        .background(keycap())
        .padding(.bottom, 1.5)
        .contentShape(Rectangle())
    }

    // MARK: 右仓：休息一下 · 跟练

    private var rightBay: some View {
        let m = session.move(for: focus)
        let pool = BreakMoves.pool(long: focus.shownKind == .longBreak)
        let idx = (pool.firstIndex(of: m) ?? 0) + 1
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Circle().fill(phosphor).frame(width: 5, height: 5)
                Text("BREAK · \(focus.shownKind.label)")
                Spacer(minLength: 0)
                Text(String(format: "%02d / %02d", idx, pool.count))
            }
            .font(.system(size: 10, weight: .semibold, design: .monospaced)).tracking(0.6).foregroundStyle(P.termMute)
            hero(m).padding(.top, 12)
            steps(m).padding(.top, 14)
            Spacer(minLength: 10)
            cta(m)
        }
        .padding(.horizontal, 22).padding(.top, 15).padding(.bottom, 14)
    }

    /// 动作 + 读数 + 进度线：左边图标和动作名，右边绿色读数和状态，下面一根进度线（跟练时从满到空）
    private func hero(_ m: BreakMove) -> some View {
        VStack(spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: m.icon).font(.system(size: 16, weight: .semibold)).foregroundStyle(phosphor)
                    .frame(width: 40, height: 40)
                    .background(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(LinearGradient(colors: [phosphor.opacity(0.20), phosphor.opacity(0.08)], startPoint: .top, endPoint: .bottom))
                    )
                    .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(phosphor.opacity(0.28), lineWidth: 0.5))
                VStack(alignment: .leading, spacing: 3) {
                    Text(m.title).font(.system(size: 17, weight: .bold)).foregroundStyle(.white).lineLimit(1)
                    Text("\(m.area) · \(m.seconds >= 120 ? "\(m.seconds / 60) 分钟" : "\(m.seconds) 秒")")
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced)).foregroundStyle(P.termMute)
                }
                Spacer(minLength: 8)
                if let end = session.practiceEnd {
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        let left = max(Int(end.timeIntervalSince(ctx.date).rounded(.up)), 0)
                        readout(left, live: left > 0, total: m.seconds)
                    }
                } else {
                    readout(m.seconds, live: false, total: m.seconds)
                }
            }
            progress(m)
        }
    }

    /// 终端读数屏：深绿黑底、细扫描线、等宽磷光绿数字，待机时数字后面有一个闪烁的光标块
    private func readout(_ sec: Int, live: Bool, total: Int) -> some View {
        let idle = session.practiceEnd == nil
        let tag = idle ? "STANDBY" : (live ? "RUNNING" : "DONE")
        let screen = RoundedRectangle(cornerRadius: 8, style: .continuous)
        return VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 0) {
                Text("$ timer")
                Spacer(minLength: 8)
                Text(tag).foregroundStyle(idle ? phosphor.opacity(0.45) : phosphor)
            }
            .font(.system(size: 8.5, weight: .semibold, design: .monospaced)).tracking(0.5)
            .foregroundStyle(phosphor.opacity(0.45))
            HStack(spacing: 2) {
                Text(String(format: "%02d:%02d", sec / 60, sec % 60))
                    .font(.system(size: 24, weight: .bold, design: .monospaced)).monospacedDigit()
                    .foregroundStyle(phosphor)
                    .shadow(color: phosphor.opacity(0.55), radius: 4)
                if idle {
                    TimelineView(.periodic(from: .now, by: 0.55)) { ctx in
                        let on = Int(ctx.date.timeIntervalSinceReferenceDate / 0.55) % 2 == 0
                        Rectangle().fill(phosphor).frame(width: 8, height: 3)
                            .opacity(on ? 0.9 : 0.1).padding(.top, 14)
                    }
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .frame(width: 128, alignment: .leading)
        .background(screen.fill(Color(hex: 0x06100A)))
        .overlay {
            Canvas { ctx, size in
                var y: CGFloat = 1
                while y < size.height {
                    ctx.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1)), with: .color(.black.opacity(0.28)))
                    y += 3
                }
            }
            .clipShape(screen).allowsHitTesting(false)
        }
        .overlay(screen.strokeBorder(phosphor.opacity(0.22), lineWidth: 0.75))
    }

    private func progress(_ m: BreakMove) -> some View {
        Group {
            if let end = session.practiceEnd {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    bar(CGFloat(max(min(end.timeIntervalSince(ctx.date) / Double(max(m.seconds, 1)), 1), 0)))
                }
            } else {
                bar(1, idle: true)
            }
        }
    }

    private func bar(_ f: CGFloat, idle: Bool = false) -> some View {
        Capsule().fill(Color(hex: 0x1F2A22))
            .frame(height: 2)
            .overlay(alignment: .leading) {
                GeometryReader { g in
                    Capsule().fill(idle ? phosphor.opacity(0.28) : phosphor).frame(width: g.size.width * f)
                        .animation(.linear(duration: 1), value: f)
                }
            }
    }

    private func steps(_ m: BreakMove) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(m.steps.enumerated()), id: \.offset) { i, s in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("\(i + 1)").font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundStyle(phosphor)
                        .frame(width: 16, height: 16)
                        .overlay(Circle().strokeBorder(phosphor.opacity(0.4), lineWidth: 0.75))
                    Text(s).font(.system(size: 12)).foregroundStyle(Color(hex: 0xD6CDC0)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func cta(_ m: BreakMove) -> some View {
        HStack(spacing: 7) {
            practiceKey(m)
            Button {
                session.practiceEnd = nil
                session.offset += 1
            } label: { keyLabel("arrow.triangle.2.circlepath", "换一个") }
            .buttonStyle(.plain)
            Spacer(minLength: 0)
            restKey
        }
    }

    /// 绿色色的主键：开始跟练 / 停止跟练 / 做完了（和普通键帽一样高，靠颜色突出）
    @ViewBuilder private func practiceKey(_ m: BreakMove) -> some View {
        if let end = session.practiceEnd {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                let done = end.timeIntervalSince(ctx.date) <= 0
                greenKey(done ? "checkmark" : "stop.fill", done ? "做完了" : "停止跟练") { session.practiceEnd = nil }
            }
        } else {
            greenKey("play.fill", "开始跟练") {
                session.practiceEnd = Date().addingTimeInterval(Double(m.seconds))
                // 跟练就是在休息：还没开始休息的话，同时进入休息状态
                if focus.run == nil, focus.pendingBreak != nil { state.onActivityAction?(activity, .primary) }
            }
        }
    }

    private func greenKey(_ icon: String, _ label: String, action: @escaping () -> Void) -> some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        return Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 9, weight: .bold))
                Text(label).font(.system(size: 12, weight: .bold))
            }
            .foregroundStyle(Color(hex: 0x06301B))
            .padding(.horizontal, 14).frame(height: 28)
            .background {
                ZStack {
                    shape.fill(Color(hex: 0x1C6B40)).offset(y: 1.5)
                    shape.fill(LinearGradient(colors: [Color(hex: 0x86EBAE), Color(hex: 0x45C47E)], startPoint: .top, endPoint: .bottom))
                    shape.strokeBorder(Color(hex: 0xB4F5CD), lineWidth: 1)
                }
            }
            .padding(.bottom, 1.5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 第三个键：开始休息 / 休息中 / 再来一个
    @ViewBuilder private var restKey: some View {
        if let r = focus.run, r.kind.isBreak {
            FocusTick(clock: focus.clock) { now in
                let left = max(Int(r.remainingMs(now) / 1000), 0)
                keyLabel(nil, "休息中 " + String(format: "%d:%02d", left / 60, left % 60), muted: true)
            }
        } else if focus.run == nil, focus.pendingBreak != nil {
            Button { state.onActivityAction?(activity, .primary) } label: { keyLabel(nil, "开始休息 \(focus.minutes)′") }
                .buttonStyle(.plain)
        } else if focus.run == nil {
            Button { state.onActivityAction?(activity, .primary) } label: { keyLabel(nil, "再来一个") }
                .buttonStyle(.plain)
        }
    }
}
