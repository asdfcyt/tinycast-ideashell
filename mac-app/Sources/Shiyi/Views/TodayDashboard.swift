import AppKit
import SwiftUI

// MARK: - 侧栏：仪表

/// 仪表盘顶部：倒计时（离下班 / 周末 / 放假）+ 一组环形仪表
struct PaceDashboard: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var focus: FocusStore
    let loaded: Bool
    let remaining: Int
    let todoDone: Int
    let todoTotal: Int
    var extraRings: [AnyView] = []
    @AppStorage("tp.pay") private var pay = 0.0
    @AppStorage("tp.paidHours") private var paidHours = 40.0
    @AppStorage("tp.unpaidHours") private var unpaidHours = 0.0
    @AppStorage("tp.jobCost") private var jobCost = 0.0
    @AppStorage("tp.goalHours") private var goalHours = 4.0
    @AppStorage("tp.workDays") private var workDays = 5.0
    @AppStorage("tp.startHour") private var startHour = 9.0
    @AppStorage("tp.endHour") private var endHour = 18.0

    var body: some View {
        let price = TimePrice(monthlyPay: pay, paidHoursPerWeek: paidHours, unpaidHoursPerWeek: unpaidHours, monthlyJobCost: jobCost, goalHoursPerDay: goalHours, workDaysPerWeek: workDays)
        let items = FocusLedger.shared.items
        let _ = focus.summary
        // 每半分钟刷新一次（倒计时、在岗进度）
        TimelineView(.periodic(from: .now, by: 30)) { ctx in
            let p = WorkPace.compute(price: price, entries: items, holidays: model.holidays, startHour: startHour, endHour: endHour, now: ctx.date)
            VStack(alignment: .leading, spacing: 0) {
                DashboardCard(focus: focus, loaded: loaded, remaining: remaining, todoDone: todoDone, todoTotal: todoTotal, pace: p, extraRings: extraRings)
            }
        }
    }
}

/// 一组环形仪表：专注 / 待办 / 项目 / 本周 / 在岗 / 记录
struct DashboardCard: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var focus: FocusStore
    let loaded: Bool
    let remaining: Int
    let todoDone: Int
    let todoTotal: Int
    let pace: WorkPace
    /// 审计项目的几个环（有结审时由 AuditProjectCard 提供），接在后面一起排
    var extraRings: [AnyView] = []
    @State private var showTodo = false
    @State private var showFocus = false
    @State private var showProject = false

    private var goal: Int { model.focusGoalMin }
    /// 今天结审便签在前台的分钟（没点专注时便签标题栏自动计时，记在时间账本里）：和专注一起算「今天的专注」
    private var stickyToday: Int { WorkStats.compute(days: 1, entries: FocusLedger.shared.items).stickyMin }
    private var focusMin: Int? {
        let sticky = stickyToday
        guard let s = focus.summary else { return sticky > 0 ? sticky : nil }
        return s.todayMin + sticky
    }
    private let amber = Color(red: 0.96, green: 0.71, blue: 0.25)
    private let green = Color(red: 0.20, green: 0.70, blue: 0.40)
    private let indigo = Color(red: 0.42, green: 0.45, blue: 0.92)
    private let teal = Color(red: 0.16, green: 0.66, blue: 0.72)
    private let pink = Color(red: 0.92, green: 0.34, blue: 0.55)

    static func fmt(_ m: Int) -> String {
        m < 60 ? "\(m)m" : (m % 60 == 0 ? "\(m / 60)h" : "\(m / 60)h\(m % 60)m")
    }

    private func ratio(_ a: Int, _ b: Int) -> Double { b <= 0 ? 0 : min(max(Double(a) / Double(b), 0), 1) }

    /// 本月（到今天）有 Daily Note 记录的天数 / 本月已过天数
    private var noteDays: (done: Int, total: Int) {
        let today = Day.today()
        let prefix = String(today.prefix(7))
        let done = model.heat.filter { $0.key.hasPrefix(prefix) && $0.key <= today && $0.value > 0 }.count
        return (done, Int(today.suffix(2)) ?? 1)
    }

    private func ringButton<L: View>(_ help: String, action: @escaping () -> Void, @ViewBuilder label: () -> L) -> some View {
        Button(action: action) { label().contentShape(Rectangle()) }
            .buttonStyle(.plain)
            .help(help)
    }

    private static let clockFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    /// 专注环弹出的小窗：今天的进度 + 每一次专注
    private var focusPeek: some View {
        let sum = focus.summary
        let today = Day.today()
        let list = (sum?.sessions ?? []).filter { Day.string(Date(timeIntervalSince1970: Double($0.startMs) / 1000)) == today }.reversed()
        let sticky = stickyToday
        let done = (sum?.todayMin ?? 0) + sticky
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("今天的专注").font(.subheadline.weight(.semibold))
                Spacer(minLength: 8)
                Text("\(Self.fmt(done)) / 目标 \(Self.fmt(goal))").font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Brand.orange.opacity(0.16))
                    Capsule().fill(Brand.orange).frame(width: g.size.width * ratio(done, goal))
                }
            }
            .frame(height: 6)
            if list.isEmpty && sticky == 0 {
                Text("今天还没有专注记录").font(.callout).foregroundStyle(.secondary)
            } else {
                Divider()
                if sticky > 0 {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.shield").font(.caption).foregroundStyle(Brand.orange).frame(width: 40, alignment: .leading)
                        Text("结审便签在前台").font(.system(size: 13)).lineLimit(1)
                        Spacer(minLength: 6)
                        Text(Self.fmt(sticky)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                ForEach(Array(list)) { s in
                    HStack(spacing: 8) {
                        Text(Self.clockFmt.string(from: Date(timeIntervalSince1970: Double(s.startMs) / 1000)))
                            .font(.caption).monospacedDigit().foregroundStyle(.secondary).frame(width: 40, alignment: .leading)
                        Text(s.title ?? s.taskId.flatMap { sum?.titles[$0] } ?? "自由专注").font(.system(size: 13)).lineLimit(1)
                        Spacer(minLength: 6)
                        Text(Self.fmt(s.minutes)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(14).frame(width: 300)
    }

    /// 项目环弹出的小窗：每个项目的任务完成率
    private var projectPeek: some View {
        let ov = model.overview
        let open = (ov?.overdue ?? []) + (ov?.upcoming ?? []) + (ov?.undated ?? [])
        let rows: [(name: String, open: Int, done: Int)] = model.projects.filter { $0.projectStatus != .PAUSED }.compactMap { p in
            let o = open.filter { p.matches($0.title, tags: $0.tags) }.count
            let d = (ov?.done ?? []).filter { p.matches($0.title, tags: $0.tags) }.count
            return o + d == 0 ? nil : (p.keyword, o, d)
        }.sorted { ratio($0.done, $0.done + $0.open) < ratio($1.done, $1.done + $1.open) }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("项目进度").font(.subheadline.weight(.semibold))
                Spacer(minLength: 8)
                Text(model.projectProgress.map { "平均 \(Int($0 * 100))%" } ?? "").font(.caption).foregroundStyle(.secondary)
            }
            let audits = model.auditStages
            if rows.isEmpty && audits.isEmpty {
                Text("还没有可统计的项目任务").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(rows, id: \.name) { r in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(r.name).font(.system(size: 13)).lineLimit(1)
                        Spacer(minLength: 6)
                        Text("完成 \(r.done) / 共 \(r.done + r.open)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(amber.opacity(0.18))
                            Capsule().fill(amber).frame(width: g.size.width * ratio(r.done, r.done + r.open))
                        }
                    }
                    .frame(height: 5)
                }
            }
            // 审计项目：按所处阶段算进度
            ForEach(audits, id: \.name) { a in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Image(systemName: "checkmark.shield").font(.system(size: 10)).foregroundStyle(Brand.orange)
                        Text(a.title).font(.system(size: 13)).lineLimit(1)
                        Spacer(minLength: 6)
                        Text("\(a.label) · 第 \(a.index + 1) / \(a.total) 阶段").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Brand.orange.opacity(0.18))
                            Capsule().fill(Brand.orange).frame(width: g.size.width * a.ratio)
                        }
                    }
                    .frame(height: 5)
                }
            }
        }
        .padding(14).frame(width: 300)
    }

    /// 待办环弹出的列表：日常 / 结审（今天的 + 还没排到今天的）/ 逾期，点一条打开
    private var todoPeek: some View {
        let d = model.todayData()
        let today = Day.today()
        let plain = d.todayTasks.filter { !SjzTasks.owns($0.id) }
        let sjzToday = d.todayTasks.filter { SjzTasks.owns($0.id) }
        let sjzLater: [DidaTask] = (model.overview.map { $0.upcoming + $0.undated } ?? [])
            .filter { SjzTasks.owns($0.id) && ($0.date == nil || ($0.date ?? "") > today) }
            .sorted { ($0.date ?? "9999") < ($1.date ?? "9999") }
        let sjz = sjzToday + sjzLater
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if plain.isEmpty && sjz.isEmpty && d.overdue.isEmpty {
                    Text("没有未完成的待办").font(.callout).foregroundStyle(.secondary).padding(14)
                }
                if !plain.isEmpty { peekHead("日常", plain.count, .secondary) }
                ForEach(plain) { t in peekRow(t, tail: t.time ?? "", tint: .secondary) }
                if !sjz.isEmpty { peekHead("结审", sjz.count, Brand.orange) }
                ForEach(sjz) { t in
                    peekRow(t, tail: (t.date ?? "") == today ? (t.time ?? "今天") : (t.date.map { Day.label($0) } ?? "未排期"), tint: .secondary)
                }
                if !d.overdue.isEmpty { peekHead("逾期", d.overdue.count, .red) }
                ForEach(d.overdue) { t in peekRow(t, tail: t.date.map { Day.label($0) } ?? "", tint: .red) }
            }
            .padding(.vertical, 6)
        }
        .frame(width: 320).frame(maxHeight: 380)
    }

    private func peekHead(_ title: String, _ n: Int, _ tint: Color) -> some View {
        HStack(spacing: 5) {
            Text(title)
            Text("\(n)").foregroundStyle(.tertiary)
        }
        .font(.caption.weight(.semibold)).foregroundStyle(tint)
        .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 2)
    }

    private func peekRow(_ t: DidaTask, tail: String, tint: Color) -> some View {
        Button { showTodo = false; model.openTask(t) } label: {
            HStack(spacing: 8) {
                Text(t.cleanTitle).font(.system(size: 13)).lineLimit(1)
                Spacer(minLength: 6)
                Text(tail).font(.caption).monospacedDigit().foregroundStyle(tint)
            }
            .padding(.horizontal, 14).padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 今日综合完成度：专注、待办、项目三项完成率的平均（没有数据的项不计）
    private var composite: Double {
        var v = [ratio(focusMin ?? 0, goal)]
        if todoTotal > 0 { v.append(ratio(todoDone, todoTotal)) }
        if let p = model.projectProgress { v.append(min(max(p, 0), 1)) }
        return v.reduce(0, +) / Double(v.count)
    }

    var body: some View {
        let score = composite
        VStack(alignment: .leading, spacing: 16) {
            // 半圆表盘：今日综合完成度
            DialGauge(progress: score, title: "今日综合完成度")
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .onTapGesture { model.selectedProject = nil; model.section = .focus }
            // 六个环：专注 / 待办 / 项目 + 审计项目的三个；每个都能点
            let over = model.todayData().overdue.count
            let rings: [AnyView] = [
                AnyView(ringButton("今天的专注：点一下看每一次") { showFocus.toggle() } label: {
                    MiniRing(color: Brand.orange, progress: ratio(focusMin ?? 0, goal), value: focusMin.map(Self.fmt) ?? "–", label: "专注")
                }
                .popover(isPresented: $showFocus, arrowEdge: .bottom) { focusPeek }),
                AnyView(ringButton("今天的待办、结审待办和逾期的：点一下看看") { showTodo.toggle() } label: {
                    MiniRing(color: over > 0 ? .red : green, progress: ratio(todoDone, todoTotal), value: loaded ? "\(todoDone)/\(todoTotal)" : "–", label: "待办")
                        .overlay(alignment: .topTrailing) {
                            if over > 0 {
                                Text("逾期 \(over)").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                                    .padding(.horizontal, 5).padding(.vertical, 1.5).background(Color.red, in: Capsule()).offset(x: -2, y: -2)
                            }
                        }
                }
                .popover(isPresented: $showTodo, arrowEdge: .bottom) { todoPeek }),
                AnyView(ringButton("项目的整体进度：点一下看每个项目") { showProject.toggle() } label: {
                    MiniRing(color: amber, progress: model.projectProgress ?? 0, value: model.projectProgress.map { "\(Int($0 * 100))%" } ?? "–", label: "项目")
                }
                .popover(isPresented: $showProject, arrowEdge: .bottom) { projectPeek }),
            ] + extraRings
            VStack(spacing: 14) {
                ForEach(Array(stride(from: 0, to: rings.count, by: 3)), id: \.self) { i in
                    HStack(alignment: .top, spacing: 0) {
                        ForEach(i ..< min(i + 3, rings.count), id: \.self) { rings[$0] }
                        // 不满一行时补空位，环不会被拉宽
                        ForEach(0 ..< max(0, i + 3 - rings.count), id: \.self) { _ in Color.clear.frame(maxWidth: .infinity, maxHeight: 1) }
                    }
                }
            }
            FocusRunBar(focus: focus)
        }
        .padding(16)
    }
}

/// 半圆表盘：渐变弧 + 刻度 + 弧上的游标，中间是百分比
struct DialGauge: View {
    let progress: Double
    let title: String

    private let w: CGFloat = 232, h: CGFloat = 132, r: CGFloat = 92
    private var cx: CGFloat { w / 2 }
    private var cy: CGFloat { h - 16 }

    private func point(_ t: Double, _ radius: CGFloat) -> CGPoint {
        let a = Double.pi * (1 - t)
        return CGPoint(x: cx + radius * CGFloat(cos(a)), y: cy - radius * CGFloat(sin(a)))
    }

    private func arc(_ upTo: Double) -> Path {
        var path = Path()
        let n = 80
        for i in 0 ... n {
            let pt = point(upTo * Double(i) / Double(n), r)
            if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
        }
        return path
    }

    var body: some View {
        let p = min(max(progress, 0), 1)
        let grad = Gradient(colors: [Color(red: 0.16, green: 0.66, blue: 0.72), Color(red: 0.96, green: 0.71, blue: 0.25), Brand.orange])
        ZStack {
            Canvas { ctx, _ in
                let style = StrokeStyle(lineWidth: 12, lineCap: .round, lineJoin: .round)
                ctx.stroke(arc(1), with: .color(Color.primary.opacity(0.08)), style: style)
                if p > 0 {
                    ctx.stroke(arc(max(p, 0.02)), with: .linearGradient(grad, startPoint: CGPoint(x: cx - r, y: cy), endPoint: CGPoint(x: cx + r, y: cy)), style: style)
                }
                // 刻度
                for k in 0 ... 40 {
                    let t = Double(k) / 40
                    let major = k % 10 == 0
                    var tick = Path()
                    tick.move(to: point(t, r + 12))
                    tick.addLine(to: point(t, r + 12 - (major ? 11 : 6)))
                    ctx.stroke(tick, with: .color(Color.primary.opacity(major ? 0.35 : 0.18)), lineWidth: major ? 1.5 : 1)
                }
                // 游标
                let m = point(max(p, 0.0), r)
                let dot = Path(ellipseIn: CGRect(x: m.x - 8, y: m.y - 8, width: 16, height: 16))
                ctx.fill(dot, with: .color(.white))
                ctx.stroke(dot, with: .color(Color.primary.opacity(0.85)), lineWidth: 3)
            }
            .frame(width: w, height: h)
            VStack(spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text("\(Int((p * 100).rounded()))").font(.system(size: 34, weight: .heavy, design: .rounded)).monospacedDigit()
                    Text("%").font(.system(size: 13, weight: .bold)).foregroundStyle(.secondary)
                }
                Text(title).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary)
            }
            .offset(y: 12)
        }
        .frame(width: w, height: h)
        .help("专注、待办、项目三项完成率的平均")
    }
}

/// 小环：读数和名称都在环里（数字在上、名称在下），环外不再放字
struct MiniRing: View {
    let color: Color
    let progress: Double
    let value: String
    let label: String

    var body: some View {
        ZStack {
            ActivityRing(size: 72, line: 6.5, color: color, progress: progress)
            VStack(spacing: 1) {
                Text(value).font(.system(size: 13, weight: .bold, design: .rounded)).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.6)
                Text(label).font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            .padding(.horizontal, 10)
        }
        .frame(width: 72, height: 72)
        .frame(maxWidth: .infinity)
    }
}

/// 环：圆头 + 渐变，轨道是同色的淡色
struct ActivityRing: View {
    let size: CGFloat
    let line: CGFloat
    let color: Color
    let progress: Double

    var body: some View {
        let p = progress > 0 ? max(min(progress, 1), 0.02) : 0
        ZStack {
            Circle().stroke(color.opacity(0.16), lineWidth: line)
            Circle().trim(from: 0, to: p)
                .stroke(AngularGradient(colors: [color.opacity(0.55), color], center: .center, startAngle: .degrees(0), endAngle: .degrees(360 * max(p, 0.05))),
                        style: StrokeStyle(lineWidth: line, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.7), value: progress)
        }
        .frame(width: size - line, height: size - line)
        .frame(width: size, height: size)
    }
}
