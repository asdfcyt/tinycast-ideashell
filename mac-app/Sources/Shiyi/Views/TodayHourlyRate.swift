import AppKit
import SwiftUI

// MARK: - 侧栏：时薪

/// 洞察里「你的时间值多少钱」的精简版：最近 7 天的有效时薪（较上一个 7 天的变化）、在岗时薪、每天的工作专注，点一下进洞察
struct HourlyRateCard: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var focus: FocusStore
    @AppStorage("tp.pay") private var pay = 0.0
    @AppStorage("tp.paidHours") private var paidHours = 40.0
    @AppStorage("tp.unpaidHours") private var unpaidHours = 0.0
    @AppStorage("tp.jobCost") private var jobCost = 0.0
    @AppStorage("tp.goalHours") private var goalHours = 4.0
    @AppStorage("tp.workDays") private var workDays = 5.0
    @AppStorage("tp.startHour") private var startHour = 9.0
    @AppStorage("tp.endHour") private var endHour = 18.0

    private let days = 7

    var body: some View {
        let price = TimePrice(monthlyPay: pay, paidHoursPerWeek: paidHours, unpaidHoursPerWeek: unpaidHours, monthlyJobCost: jobCost, goalHoursPerDay: goalHours, workDaysPerWeek: workDays)
        let items = FocusLedger.shared.items
        let stats = WorkStats.compute(days: days, entries: items)
        let prev = WorkStats.compute(days: days, entries: items, ending: Day.add(Day.today(), days: -days))
        let rate = price.effectiveHourly(workMin: stats.workMin, days: days)
        let prevRate = price.effectiveHourly(workMin: prev.workMin, days: days)
        let todayMin = stats.daily.last?.work ?? 0
        let _ = focus.summary
        // 每半分钟刷新一次（倒计时、此刻的位置）
        TimelineView(.periodic(from: .now, by: 30)) { ctx in
            let p = WorkPace.compute(price: price, entries: items, holidays: model.holidays, startHour: startHour, endHour: endHour, now: ctx.date)
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("时薪").font(.subheadline.weight(.bold)).foregroundStyle(.secondary)
                    if price.configured {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(rate.map { TimePrice.money($0) } ?? "–").font(.system(size: 26, weight: .bold)).monospacedDigit()
                            Text("/ 小时").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            if let rate, let pr = prevRate, pr > 0 { trend(rate, pr) }
                            Spacer(minLength: 6)
                            Text("底价 " + TimePrice.money(price.realHourly)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                    } else {
                        Text("填上每月收入和每周工时，就能算出你的时间值多少钱")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    // 距下班 / 周末 / 放假：和时薪合在一起
                    countdown(p).padding(.top, 2)
                    if p.goalMin > 0, p.personalToday || p.weekQuotaMin > 0 {
                        VStack(alignment: .leading, spacing: 16) {
                            if p.personalToday { todayChart(p) }
                            if p.weekQuotaMin > 0 { weekChart(p) }
                        }
                        .help(p.insights.prefix(2).map(\.text).joined(separator: "\n\n"))
                    }
                }
                .padding(16)
                .contentShape(Rectangle())
                .onTapGesture { model.section = .insights }
                .help("在洞察里查看详细的时间价格")
            }
        }
        .task {
            if model.holidays.isEmpty {
                let h = await HolidayStore.load()
                if !h.isEmpty { model.holidays = h }
            }
        }
    }

    // MARK: 今天 / 本周图表

    /// 离下班 / 离周末 / 离放假
    private func countdown(_ p: WorkPace) -> some View {
        HStack(alignment: .top, spacing: 0) {
            switch p.phase {
            case .working: countStat(WorkPace.clock(p.minutesToOff), "距下班")
            case .before: countStat(WorkPace.clock(p.minutesToStart), "距上班")
            case .after: countStat("已下班", "今天的班结束了", small: true)
            case .off: countStat("休息中", p.daysToWork > 0 ? "\(p.daysToWork) 天后上班" : "好好休息", small: true)
            }
            if let o = p.nextOff {
                countStat(o.days == 1 ? "明天" : "\(o.days) 天", "距" + o.name + (o.length > 2 ? "（连休 \(o.length) 天）" : ""))
            }
            if let h = p.nextHoliday, h.name != p.nextOff?.name || h.days != p.nextOff?.days {
                countStat("\(h.days) 天", "距" + h.name + "（连休 \(h.length) 天）")
            }
        }
    }

    private func countStat(_ value: String, _ label: String, small: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: small ? 14 : 17, weight: .bold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                .frame(height: 22, alignment: .bottomLeading)
            Text(label).font(.caption2).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }


    private static func hm(_ m: Int) -> String { String(format: "%d:%02d", m / 60, m % 60) }

    /// 今天：上班到下班的时间轴。深色块 = 已经专注的时段，浅色块 = 还差的量从现在往后铺；铺过 12 点线变红 = 上午装不下
    private func todayChart(_ p: WorkPace) -> some View {
        let remain = max(p.goalMin - p.todayMin, 0)
        let span = Double(max(p.endMin - p.startMin, 1))
        let from = max(p.nowMin, p.startMin)
        let toNoon = max(WorkPace.noon - from, 0)
        let late = p.phase != .after && p.nowMin < WorkPace.noon && remain > toNoon
        return VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("今天").font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if remain == 0 {
                    Label("已做完 \(WorkPace.clock(p.todayMin))", systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.semibold)).foregroundStyle(.green)
                } else {
                    Text("还差 \(WorkPace.clock(remain))").font(.caption.weight(.bold)).monospacedDigit()
                    if p.phase != .after, p.nowMin < WorkPace.noon {
                        Text("离 12 点 \(WorkPace.clock(toNoon))").font(.caption.weight(.semibold)).monospacedDigit()
                            .foregroundStyle(late ? Color.red : Color.secondary)
                    }
                }
            }
            GeometryReader { g in
                let w = g.size.width
                let x = { (m: Int) -> CGFloat in w * CGFloat(min(max(Double(m - p.startMin) / span, 0), 1)) }
                let seg = { (a: Int, b: Int, c: Color) -> AnyView in
                    AnyView(RoundedRectangle(cornerRadius: 3, style: .continuous).fill(c)
                        .frame(width: max(x(b) - x(a), 0)).offset(x: x(a)))
                }
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.primary.opacity(0.06))
                    seg(p.startMin, WorkPace.noon, Brand.orange.opacity(0.10))
                    if remain > 0, p.phase != .after {
                        let to = min(from + remain, p.endMin)
                        if from < WorkPace.noon {
                            seg(from, min(to, WorkPace.noon), Brand.orange.opacity(0.35))
                            if to > WorkPace.noon { seg(WorkPace.noon, to, Color.red.opacity(0.35)) }
                        } else {
                            seg(from, to, Brand.orange.opacity(0.35))
                        }
                    }
                    ForEach(p.todayBlocks) { b in seg(b.start, b.start + max(b.len, 4), Brand.orange) }
                    Rectangle().fill(Color.primary.opacity(0.28)).frame(width: 1).offset(x: x(WorkPace.noon))
                    if p.phase == .working {
                        Capsule().fill(Color.primary).frame(width: 2.5, height: 20).offset(x: x(p.nowMin) - 1.25)
                    }
                }
            }
            .frame(height: 16)
            GeometryReader { g in
                let w = g.size.width
                let noonX = w * CGFloat(Double(WorkPace.noon - p.startMin) / Double(max(p.endMin - p.startMin, 1)))
                ZStack(alignment: .leading) {
                    Text(Self.hm(p.startMin)).frame(maxWidth: .infinity, alignment: .leading)
                    Text("12:00").position(x: noonX, y: 6)
                    Text(Self.hm(p.endMin)).frame(maxWidth: .infinity, alignment: .trailing)
                }
                .font(.system(size: 10)).monospacedDigit().foregroundStyle(.tertiary)
            }
            .frame(height: 12)
        }
    }

    /// 本周：累计专注曲线。虚线 = 按「趁早做完」到此刻该有的累计，橙线 = 实际；两条线之间的缺口就是落后
    private func weekChart(_ p: WorkPace) -> some View {
        var planM: [Int] = [], actualM: [Int?] = []
        var cp = 0, ca = 0
        for d in p.weekDays {
            if d.quota { cp += p.goalMin }
            ca += d.work
            planM.append(d.isToday && p.personalToday ? p.weekExpectedMin : cp)
            actualM.append(d.future ? nil : ca)
        }
        let plan = planM, actual = actualM
        let gap = p.weekDoneMin - p.weekExpectedMin
        let finished = p.weekDoneMin >= p.weekQuotaMin
        let peak = Double(max(p.weekQuotaMin, p.weekDoneMin, 1))
        let count = max(p.weekDays.count, 1)
        return VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("本周").font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if finished {
                    Label("已做完", systemImage: "checkmark.circle.fill").font(.caption.weight(.semibold)).foregroundStyle(.green)
                } else if abs(gap) >= 15 {
                    Text("\(gap < 0 ? "落后" : "领先") \(WorkPace.clock(abs(gap)))")
                        .font(.caption.weight(.bold)).monospacedDigit().foregroundStyle(gap < 0 ? Color.red : Color.green)
                }
                Text("\(WorkPace.clock(p.weekDoneMin)) / \(WorkPace.clock(p.weekQuotaMin))")
                    .font(.caption.weight(.semibold)).monospacedDigit()
            }
            GeometryReader { g in
                let w = g.size.width, h = g.size.height
                let px = { (i: Int) -> CGFloat in w * (CGFloat(i) + 0.5) / CGFloat(count) }
                let py = { (v: Int) -> CGFloat in 4 + (h - 8) * (1 - CGFloat(Double(v) / peak)) }
                let planPath = Path { path in
                    path.move(to: CGPoint(x: 0, y: py(0)))
                    for (i, v) in plan.enumerated() { path.addLine(to: CGPoint(x: px(i), y: py(v))) }
                }
                let pts: [CGPoint] = actual.enumerated().compactMap { i, v in v.map { CGPoint(x: px(i), y: py($0)) } }
                ZStack(alignment: .topLeading) {
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: py(p.weekQuotaMin)))
                        path.addLine(to: CGPoint(x: w, y: py(p.weekQuotaMin)))
                    }
                    .stroke(Color.primary.opacity(0.12), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                    planPath.stroke(Color.primary.opacity(0.4), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round, dash: [4, 3]))
                    if let last = pts.last {
                        Path { path in
                            path.move(to: CGPoint(x: 0, y: py(0)))
                            for q in pts { path.addLine(to: q) }
                            path.addLine(to: CGPoint(x: last.x, y: py(0)))
                            path.closeSubpath()
                        }
                        .fill(LinearGradient(colors: [Brand.orange.opacity(0.22), Brand.orange.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                        Path { path in
                            path.move(to: CGPoint(x: 0, y: py(0)))
                            for q in pts { path.addLine(to: q) }
                        }
                        .stroke(Brand.orange, style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
                        Circle().fill(Brand.orange).frame(width: 7, height: 7).position(last)
                        if p.personalToday, gap <= -15, let ti = p.weekDays.firstIndex(where: \.isToday) {
                            Path { path in
                                path.move(to: CGPoint(x: px(ti), y: py(plan[ti])))
                                path.addLine(to: CGPoint(x: px(ti), y: last.y))
                            }
                            .stroke(Color.red.opacity(0.7), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        }
                    }
                }
            }
            .frame(height: 52)
            HStack(spacing: 0) {
                ForEach(p.weekDays) { d in
                    Text(d.label).font(.system(size: 10, weight: d.isToday ? .bold : .regular))
                        .foregroundStyle(d.isToday ? Brand.orange : (d.quota ? Color.secondary : Color.secondary.opacity(0.45)))
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func trend(_ rate: Double, _ prev: Double) -> some View {
        let d = Int(((rate / prev - 1) * 100).rounded())
        let color: Color = d > 0 ? .green : (d < 0 ? .red : .secondary)
        return HStack(spacing: 1) {
            if d != 0 { Image(systemName: d > 0 ? "arrow.up" : "arrow.down").font(.system(size: 9, weight: .bold)) }
            Text(d == 0 ? "持平" : "\(abs(d))%").font(.caption.weight(.semibold)).monospacedDigit()
        }
        .foregroundStyle(color)
        .help("较上一个 \(days) 天")
    }
}
