import Charts
import SwiftUI

/// 洞察：围绕「少花时间、提高效率、知道时间值多少钱」重做（思路来自《每周工作 4 小时》《要钱还是要生活》）。
/// 结构：AI 洞察（可折叠）→ 时间价格 → 工作时间 → 时间花在哪（80/20）→ 效率 → 该消除的 → 记录节奏。
/// 工作时间 = 结审里的任务 + 带「工作」标签的待办；其余是普通时间。
struct InsightsView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("tp.pay") private var pay = 0.0
    @AppStorage("tp.paidHours") private var paidHours = 40.0
    @AppStorage("tp.unpaidHours") private var unpaidHours = 0.0
    @AppStorage("tp.jobCost") private var jobCost = 0.0
    @AppStorage("tp.workTag") private var workTag = "工作"
    @AppStorage("insights.aiFold") private var aiFold = false
    @State private var showPriceForm = false
    @State private var ledgerRev = 0

    private var noData: Bool { !model.hasIdeashell && !model.hasDida }

    private let noteColor = Color.blue
    private let doneColor = Color.green
    private let hourColor = Color.indigo
    private var workColor: Color { Brand.orange }
    private let normalColor = Color.secondary

    private var price: TimePrice {
        TimePrice(monthlyPay: pay, paidHoursPerWeek: paidHours, unpaidHoursPerWeek: unpaidHours, monthlyJobCost: jobCost)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if noData {
                    EmptyHint(icon: "key", title: "先到「设置」填写凭证").frame(height: 300)
                } else if let r = model.review {
                    content(r)
                } else if model.reviewLoading {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 240)
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 14)
            .padding(.bottom, 34)
            .frame(maxWidth: 780, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(AmbientBackground())
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Picker("范围", selection: $model.reviewDays) {
                    Text("7 天").tag(7)
                    Text("14 天").tag(14)
                    Text("30 天").tag(30)
                }
                .pickerStyle(.segmented)
                .help("统计范围")
            }
        }
        .task(id: model.reviewDays) {
            await model.loadReview(ifStale: true)
            FocusLedger.shared.seedIfNeeded(model: model)
            ledgerRev += 1
        }
    }

    // MARK: - 内容

    @ViewBuilder private func content(_ r: ReviewData) -> some View {
        let _ = ledgerRev
        let stats = WorkStats.compute(days: r.days, entries: FocusLedger.shared.items)
        let done = doneCounts(r)

        if let e = model.reviewError { ErrorBanner(text: e) { Task { await model.loadReview() } } }
        if let e = r.todoError { ErrorBanner(text: "待办读取失败：" + e) { Task { await model.loadReview() } } }

        section("AI 洞察") { aiCard(r) }

        section("时间价格") { priceCard() }

        section("最近 \(r.days) 天的工作时间") { workCard(stats) }

        if !stats.projects.isEmpty {
            section("时间花在哪") { whereCard(stats) }
        }

        section("效率") { efficiencyCard(r, stats, done) }

        let stale = staleTasks()
        section("该消除的") { eliminateCard(stale) }

        if r.totalNotes + r.totalDone > 0 {
            section("记录节奏") { rhythmCard(r) }
        }
        if r.truncated {
            Text("某个时段笔记过多，统计可能不完整").font(.caption).foregroundStyle(.tertiary)
        }
    }

    private func section<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title3.weight(.bold))
            content()
        }
    }

    // MARK: - 小件

    private func fmtMin(_ m: Int) -> String {
        if m < 60 { return "\(m) 分钟" }
        return m % 60 == 0 ? "\(m / 60) 小时" : "\(m / 60) 小时 \(m % 60) 分"
    }

    private func cardHeader(_ title: String, icon: String, tint: Color, trailing: String? = nil) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(title).foregroundStyle(tint)
            Spacer(minLength: 8)
            if let trailing { Text(trailing).font(.caption).foregroundStyle(.tertiary) }
        }
        .font(.subheadline.weight(.semibold))
    }

    /// 大数字 + 小单位 + 一行说明，几张并排时各占一份
    private func metric(_ label: String, value: String, unit: String? = nil, note: String? = nil, tint: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(tint).lineLimit(1).minimumScaleFactor(0.6)
                if let unit { Text(unit).font(.callout).foregroundStyle(.secondary).lineLimit(1) }
            }
            Text(note ?? " ").font(.caption2).foregroundStyle(.tertiary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func dayAxis(step: Int) -> some AxisContent {
        AxisMarks(values: .stride(by: .day, count: step)) { v in
            AxisValueLabel(centered: true) {
                if let d = v.as(Date.self) { Text(shortDay(Day.string(d))).font(.caption2).fixedSize() }
            }
        }
    }

    private func shortDay(_ s: String) -> String {
        let p = s.split(separator: "-")
        guard p.count == 3, let m = Int(p[1]), let d = Int(p[2]) else { return s }
        return "\(m)/\(d)"
    }

    // MARK: - 时间价格

    private func priceCard() -> some View {
        let p = price
        return InsightCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 6) {
                    Image(systemName: "yensign.circle.fill").foregroundStyle(workColor)
                    Text("你的时间值多少钱").foregroundStyle(workColor)
                    Spacer(minLength: 8)
                    Button { showPriceForm = true } label: {
                        Label(p.configured ? "调整" : "去填写", systemImage: "slider.horizontal.3").font(.caption)
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                    .popover(isPresented: $showPriceForm, arrowEdge: .bottom) { priceForm }
                }
                .font(.subheadline.weight(.semibold))

                if p.configured {
                    HStack(alignment: .top, spacing: 16) {
                        metric("真实时薪", value: TimePrice.money(p.realHourly), unit: "/ 小时",
                               note: p.shrink > 0.005 ? "名义 \(TimePrice.money(p.nominalHourly))，被无薪时间和工作花费吃掉 \(Int((p.shrink * 100).rounded()))%" : "与名义时薪一致", tint: workColor)
                        Divider().frame(height: 62)
                        metric("每分钟", value: TimePrice.money(p.perMinute), unit: "/ 分钟", note: "刷 10 分钟手机 ≈ \(TimePrice.money(p.cost(minutes: 10)))")
                        Divider().frame(height: 62)
                        metric("一个番茄", value: TimePrice.money(p.cost(minutes: 25)), unit: "/ 25 分钟", note: "一小时 ≈ \(TimePrice.money(p.realHourly))")
                    }
                    Text("每月实际投入 \(Int(p.totalMonthlyHours.rounded())) 小时（含通勤 / 加班），到手 \(TimePrice.money(p.monthlyPay))\(jobCost > 0 ? "，工作花费 \(TimePrice.money(jobCost))" : "")")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("填上每月到手收入、每周工时、通勤加班和工作花费，算出你每小时、每分钟的真实价格。之后每一段专注、每一件待办都能换算成钱，才知道哪些事值得做、哪些该外包或砍掉。")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var priceForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("时间价格").font(.headline)
            priceField("每月到手收入", unit: "元", value: $pay)
            priceField("每周有薪工时", unit: "小时", value: $paidHours)
            priceField("每周通勤 / 加班等无薪工时", unit: "小时", value: $unpaidHours)
            priceField("每月为工作付出的花费", unit: "元", value: $jobCost, hint: "交通、工作餐、置装、通勤租房溢价等")
            HStack {
                Text("「工作」标签").font(.callout)
                Spacer()
                TextField("工作", text: $workTag).textFieldStyle(.roundedBorder).frame(width: 110).multilineTextAlignment(.trailing)
            }
            Divider()
            Text("真实时薪 = (收入 − 工作花费) ÷ (有薪工时 + 无薪工时)。结审里的任务一律算工作；其他待办带上「\(workTag.trimmed.isEmpty ? "工作" : workTag)」标签才算工作，其余是普通时间。数据只存在这台电脑上。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 340)
    }

    private func priceField(_ title: String, unit: String, value: Binding<Double>, hint: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(title).font(.callout)
                Spacer(minLength: 4)
                TextField("0", value: value, format: .number)
                    .textFieldStyle(.roundedBorder).frame(width: 92).multilineTextAlignment(.trailing)
                Text(unit).font(.caption).foregroundStyle(.secondary).frame(width: 30, alignment: .leading)
            }
            if let hint { Text(hint).font(.caption2).foregroundStyle(.tertiary) }
        }
    }

    // MARK: - 工作时间

    private func workCard(_ s: WorkStats) -> some View {
        let p = price
        let total = max(s.totalMin, 1)
        let step = s.days <= 8 ? 1 : Int((Double(s.days) / 6).rounded(.up))
        let paidMin = p.paidHoursPerWeek * 60 * Double(s.days) / 7
        return InsightCard {
            VStack(alignment: .leading, spacing: 14) {
                cardHeader("专注时间", icon: "timer", tint: workColor, trailing: "工作 = 结审任务 + 「\(model.workTag)」标签")
                if s.totalMin == 0 {
                    Text("这段时间还没有专注记录。从现在起，每次专注都会记进来，并按工作 / 普通时间分开统计。")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    HStack(alignment: .top, spacing: 16) {
                        metric("工作", value: fmtMin(s.workMin), note: p.configured ? "价值约 \(TimePrice.money(p.cost(minutes: s.workMin)))" : nil, tint: workColor)
                        Divider().frame(height: 62)
                        metric("普通时间", value: fmtMin(s.normalMin), note: p.configured ? "约 \(TimePrice.money(p.cost(minutes: s.normalMin)))" : nil)
                    }
                    // 工作 / 普通时间的占比条
                    GeometryReader { g in
                        HStack(spacing: 2) {
                            if s.workMin > 0 { Capsule().fill(workColor).frame(width: max(6, g.size.width * CGFloat(s.workMin) / CGFloat(total))) }
                            if s.normalMin > 0 { Capsule().fill(normalColor.opacity(0.35)).frame(maxWidth: .infinity) }
                        }
                    }
                    .frame(height: 8)

                    Chart {
                        ForEach(s.daily) { d in
                            let x = Day.parse(d.day) ?? Date()
                            BarMark(x: .value("日期", x, unit: .day), y: .value("分钟", d.work))
                                .foregroundStyle(by: .value("类型", "工作"))
                            BarMark(x: .value("日期", x, unit: .day), y: .value("分钟", d.normal))
                                .foregroundStyle(by: .value("类型", "普通"))
                        }
                    }
                    .chartForegroundStyleScale(["工作": workColor, "普通": normalColor.opacity(0.4)])
                    .chartLegend(position: .bottom, alignment: .leading, spacing: 8)
                    .chartXAxis { dayAxis(step: step) }
                    .chartYAxis {
                        AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { v in
                            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Color.primary.opacity(0.1))
                            AxisValueLabel {
                                if let m = v.as(Int.self) { Text(m >= 60 ? "\(m / 60)h" : "\(m)m").font(.caption2) }
                            }
                        }
                    }
                    .frame(height: 170)

                    HStack(alignment: .top, spacing: 16) {
                        metric("日均专注", value: fmtMin(s.totalMin / max(s.days, 1)), note: "共 \(s.sessions) 次，平均 \(s.avgSessionMin) 分钟")
                        Divider().frame(height: 50)
                        if p.configured, paidMin > 0 {
                            let ratio = Double(s.workMin) / paidMin
                            metric("专注占比", value: "\(Int((ratio * 100).rounded()))%", note: "工作专注 ÷ 有薪工时；有薪工时里真正产出的部分", tint: ratio >= 0.4 ? .green : .primary)
                        } else {
                            metric("专注占比", value: "–", note: "填写时间价格后显示")
                        }
                    }
                }
            }
        }
    }

    // MARK: - 时间花在哪（80/20）

    private func whereCard(_ s: WorkStats) -> some View {
        let p = price
        let rows = Array(s.projects.prefix(6))
        let maxMin = max(rows.first?.minutes ?? 1, 1)
        return InsightCard {
            VStack(alignment: .leading, spacing: 14) {
                cardHeader("按项目", icon: "chart.bar.doc.horizontal.fill", tint: noteColor, trailing: p.configured ? "时长 · 价值" : "时长")
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(rows) { it in projectRow(it, maxMin: maxMin, total: s.totalMin, price: p) }
                }
                if let share = s.paretoShare {
                    Divider()
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "scope").foregroundStyle(workColor)
                        Text("80/20：最费时间的前 \(s.paretoTop) 件事（共 \(s.tasks.count) 件）占了 \(Int((share * 100).rounded()))% 的专注时间。\(share >= 0.7 ? "时间高度集中，把这几件做好、其余能砍就砍。" : "时间比较分散，试试砍掉几件小事，把省下的时间给最重要的。")")
                            .font(.callout).fixedSize(horizontal: false, vertical: true)
                    }
                } else if let top = s.tasks.first {
                    Divider()
                    Text("最费时间的是「\(top.name)」，\(fmtMin(top.minutes))\(p.configured ? "，约 \(TimePrice.money(p.cost(minutes: top.minutes)))" : "")。")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func projectRow(_ it: WorkStats.Item, maxMin: Int, total: Int, price p: TimePrice) -> some View {
        let tint = it.work ? workColor : normalColor.opacity(0.5)
        let share = Int((Double(it.minutes) / Double(max(total, 1)) * 100).rounded())
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: it.work ? "briefcase.fill" : "person.fill").font(.system(size: 11)).foregroundStyle(it.work ? workColor : Color.secondary)
                Text(it.name).font(.callout.weight(.medium)).lineLimit(1)
                Spacer(minLength: 8)
                Text(fmtMin(it.minutes)).font(.callout).monospacedDigit()
                Text("\(share)%").font(.caption).foregroundStyle(.tertiary).monospacedDigit().frame(width: 34, alignment: .trailing)
                if p.configured {
                    Text(TimePrice.money(p.cost(minutes: it.minutes))).font(.callout.weight(.semibold)).monospacedDigit()
                        .foregroundStyle(it.work ? workColor : Color.secondary).frame(minWidth: 56, alignment: .trailing)
                }
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.07))
                    Capsule().fill(tint).frame(width: max(5, g.size.width * CGFloat(it.minutes) / CGFloat(max(maxMin, 1))))
                }
            }
            .frame(height: 6)
        }
    }

    // MARK: - 效率

    private struct DoneCounts { var work = 0; var all = 0 }

    /// 这段时间完成的待办：工作的（结审 + 带工作标签）和全部
    private func doneCounts(_ r: ReviewData) -> DoneCounts {
        let today = Day.today()
        let first = Day.add(today, days: -(r.days - 1))
        var c = DoneCounts()
        c.all = r.totalDone
        for t in model.reviewDoneTasks {
            guard let when = t.completedDate else { continue }
            let day = Day.string(when)
            if day >= first, day <= today, model.isWorkTask(t) { c.work += 1 }
        }
        let projects = model.sjzOverview?.projects.map(\.name) ?? []
        for i in 0 ..< r.days {
            let d = Day.add(first, days: i)
            for name in projects {
                let n = SjzDaily.get(name, "done", day: d)
                c.work += n
                c.all += n
            }
        }
        return c
    }

    private func efficiencyCard(_ r: ReviewData, _ s: WorkStats, _ done: DoneCounts) -> some View {
        let p = price
        let workHours = Double(s.workMin) / 60
        let perHour: String? = s.workMin >= 30 && done.work > 0 ? String(format: "%.1f", Double(done.work) / workHours) : nil
        let high = r.donePriority[3]
        let highShare = r.totalDone > 0 ? Int((Double(high) / Double(r.totalDone) * 100).rounded()) : nil
        return InsightCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 16) {
                    metric("工作待办完成", value: "\(done.work)", unit: "个", note: "全部完成 \(done.all) 个")
                    Divider().frame(height: 62)
                    metric("每专注小时完成", value: perHour ?? "–", unit: perHour == nil ? nil : "个", note: perHour == nil ? "工作专注不足 30 分钟或还没完成" : "工作专注 \(fmtMin(s.workMin))")
                    Divider().frame(height: 62)
                    if p.configured, done.work > 0, s.workMin > 0 {
                        metric("每个待办的时间成本", value: TimePrice.money(p.cost(minutes: s.workMin) / Double(done.work)), note: "工作专注价值 ÷ 完成数")
                    } else {
                        metric("每个待办的时间成本", value: "–", note: "需要时间价格和工作专注记录")
                    }
                }
                HStack(alignment: .top, spacing: 16) {
                    metric("高优先级占比", value: highShare.map { "\($0)%" } ?? "–", note: highShare == nil ? nil : "完成 \(r.totalDone) 个里有 \(high) 个高优先级。越高说明时间越花在重要的事上",
                           tint: (highShare ?? 0) >= 30 ? .green : .primary)
                    Divider().frame(height: 62)
                    goldenCard(s)
                }
            }
        }
    }

    private func goldenCard(_ s: WorkStats) -> some View {
        let maxH = max(s.hours.max() ?? 1, 1)
        return VStack(alignment: .leading, spacing: 5) {
            Text("黄金时段").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(s.goldenStart.map { "\($0)–\($0 + 2) 点" } ?? "–")
                .font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit()
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0 ..< 24, id: \.self) { h in
                    let inWin = s.goldenStart.map { h >= $0 && h <= $0 + 2 } ?? false
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(inWin ? workColor : Color.primary.opacity(0.16))
                        .frame(maxWidth: .infinity)
                        .frame(height: max(2, 26 * CGFloat(s.hours[h]) / CGFloat(maxH)))
                }
            }
            .frame(height: 26, alignment: .bottom)
            Text(s.goldenStart == nil ? "专注记录还不够" : "把最难的事放在这个时段")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 该消除的

    /// 逾期 7 天以上的待办，拖得最久的在前
    private struct Stale: Identifiable {
        let task: DidaTask
        let days: Int
        var id: String { task.id }
    }

    private func staleTasks() -> [Stale] {
        guard let ov = model.overview else { return [] }
        let today = Day.today()
        return ov.overdue.compactMap { t -> Stale? in
            guard let d = t.date else { return nil }
            let n = Day.diff(d, today)
            return n >= 7 ? Stale(task: t, days: n) : nil
        }
        .sorted { $0.days > $1.days }
    }

    private func eliminateCard(_ stale: [Stale]) -> some View {
        let p = price
        return InsightCard {
            VStack(alignment: .leading, spacing: 12) {
                cardHeader("逾期超过 7 天", icon: "scissors", tint: .red, trailing: stale.isEmpty ? nil : "共 \(stale.count) 件")
                if stale.isEmpty {
                    Text("没有拖了很久的待办，清爽。").font(.callout).foregroundStyle(.secondary)
                } else {
                    Text("拖了这么久还没做，多半不重要：删掉、推迟到明确的日子，或者交给别人。").font(.callout).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(stale.prefix(5))) { item in
                            Button { model.openTask(item.task) } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: SjzTasks.owns(item.task.id) ? "briefcase.fill" : "circle.dashed")
                                        .font(.system(size: 11)).foregroundStyle(SjzTasks.owns(item.task.id) ? workColor : Color.secondary)
                                    Text(item.task.cleanTitle).font(.callout).lineLimit(1)
                                    Spacer(minLength: 8)
                                    Text("逾期 \(item.days) 天").font(.caption.weight(.medium)).foregroundStyle(.red)
                                }
                                .padding(.vertical, 4)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    if stale.count > 5 {
                        Button("在「待办」里查看全部 \(stale.count) 件") { model.section = .todos }.buttonStyle(.link).font(.callout)
                    }
                }
                if p.configured {
                    Divider()
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "lightbulb.fill").foregroundStyle(.yellow)
                        Text("按你的真实时薪 \(TimePrice.money(p.realHourly))/小时：一件事如果花钱外包、或用工具自动化的成本低于这个数，就别自己做；做不做都行的，直接消除。给任务设更短的期限——任务会膨胀到占满你给它的时间（帕金森定律）。")
                            .font(.callout).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    // MARK: - 记录节奏

    private func rhythmCard(_ r: ReviewData) -> some View {
        InsightCard {
            HStack(spacing: 0) {
                rhythm(icon: "doc.text.fill", tint: noteColor, value: "\(r.totalNotes)", unit: "条", label: "笔记", trend: trend(r.totalNotes, r.prev?.notes))
                Divider().frame(height: 62)
                rhythm(icon: "checkmark.circle.fill", tint: doneColor, value: "\(r.totalDone)", unit: "个", label: "完成待办", trend: trend(r.totalDone, r.prev?.done))
                Divider().frame(height: 62)
                rhythm(icon: "calendar", tint: hourColor, value: "\(r.activeDays)", unit: "/ \(r.days) 天", label: "有记录", trend: trend(r.activeDays, r.prev?.activeDays))
                Divider().frame(height: 62)
                rhythm(icon: "flame.fill", tint: .orange, value: "\(r.streak)", unit: "天", label: "连续记录",
                       trend: r.longestStreak > 0 ? ("最长 \(r.longestStreak) 天", .secondary) : nil)
            }
        }
    }

    private func rhythm(icon: String, tint: Color, value: String, unit: String, label: String, trend: (String, Color)?) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(label, systemImage: icon).font(.caption.weight(.semibold)).foregroundStyle(tint)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(.system(size: 28, weight: .semibold, design: .rounded)).monospacedDigit()
                Text(unit).font(.callout).foregroundStyle(.secondary)
            }
            Text(trend?.0 ?? " ").font(.caption2.weight(.medium)).foregroundStyle(trend?.1 ?? .clear).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
    }

    /// 和上一个同样长度的时间段比：↑ 12% / ↓ 8% / 持平
    private func trend(_ cur: Int, _ prev: Int?) -> (String, Color)? {
        guard let prev else { return nil }
        if prev == 0 { return cur > 0 ? ("上期没有", .secondary) : nil }
        let pct = Int((Double(cur - prev) / Double(prev) * 100).rounded())
        if pct == 0 { return ("与上期持平", .secondary) }
        return (pct > 0 ? "↑ \(pct)% 较上期" : "↓ \(-pct)% 较上期", pct > 0 ? .green : .orange)
    }

    // MARK: - AI 洞察（可折叠）

    private func aiCard(_ r: ReviewData) -> some View {
        let ins = model.aiInsights[model.reviewDays]
        let busy = model.aiInsightLoading
        return InsightCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Button { withAnimation(.easeOut(duration: 0.18)) { aiFold.toggle() } } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                                .rotationEffect(.degrees(aiFold ? 0 : 90))
                            Image(systemName: "sparkles").foregroundStyle(Brand.orange)
                            Text("读一读你最近 \(r.days) 天写的东西").font(.subheadline.weight(.semibold))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(aiFold ? "展开" : "折叠")
                    Spacer(minLength: 8)
                    if busy { ProgressView().controlSize(.small) }
                    if !aiFold {
                        Button { Task { await model.generateAIInsight() } } label: {
                            Label(ins == nil ? "生成洞察" : "重新生成", systemImage: ins == nil ? "wand.and.stars" : "arrow.clockwise")
                        }
                        .buttonStyle(.bordered).controlSize(.small)
                        .disabled(busy || !model.hasLlm)
                    }
                }

                if aiFold {
                    if let ins {
                        Text(ins.summary).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                    } else {
                        Text(model.hasLlm ? "已折叠，点开可生成或查看" : "需要先配置 AI 模型").font(.callout).foregroundStyle(.tertiary)
                    }
                } else {
                    if !model.hasLlm {
                        HStack(spacing: 8) {
                            Text("需要先配置 AI 模型").font(.callout).foregroundStyle(.secondary)
                            Button("去设置") { SettingsWindow.show(.account) }.buttonStyle(.link)
                        }
                    }
                    if let e = model.aiInsightError { ErrorBanner(text: e) { Task { await model.generateAIInsight() } } }

                    if let ins {
                        aiBody(ins)
                    } else if busy {
                        Text("正在阅读笔记、Daily Note 和完成的待办，大约需要十几秒…").font(.callout).foregroundStyle(.secondary)
                    } else if model.hasLlm {
                        Text("AI 会帮你看看：这段时间在关注什么、有哪些反复出现的主题、状态有什么变化、哪些想法值得回头再看，以及接下来可以怎么做。")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    @ViewBuilder private func aiBody(_ ins: AIInsight) -> some View {
        Text(ins.summary).font(.body.weight(.medium)).fixedSize(horizontal: false, vertical: true)

        if !ins.themes.isEmpty {
            aiBlock("反复出现的主题", icon: "number", tint: noteColor) {
                ForEach(ins.themes) { t in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(t.name).font(.callout.weight(.semibold))
                        if !t.detail.isEmpty { Text(t.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                        if !t.notes.isEmpty {
                            FlowRow(spacing: 6) { ForEach(t.notes) { noteChip($0) } }
                        }
                    }
                }
            }
        }
        if !ins.mood.isEmpty {
            aiBlock("状态观察", icon: "face.smiling", tint: .pink) {
                Text(ins.mood).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
        }
        if !ins.revisit.isEmpty {
            aiBlock("值得回头看", icon: "arrow.uturn.backward.circle", tint: hourColor) {
                ForEach(ins.revisit) { v in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        noteChip(v.note)
                        if !v.reason.isEmpty { Text(v.reason).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                    }
                }
            }
        }
        if !ins.suggestions.isEmpty {
            aiBlock("可以试试", icon: "lightbulb.fill", tint: .yellow) {
                ForEach(ins.suggestions, id: \.self) { s in
                    Text("· " + s).font(.callout).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        if !ins.questions.isEmpty {
            aiBlock("想一想", icon: "questionmark.bubble.fill", tint: .teal) {
                ForEach(ins.questions, id: \.self) { q in
                    Text(q).font(.callout).italic().fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        Text("分析了 \(ins.noteCount) 条笔记、\(ins.doneCount) 个完成的待办 · 生成于 \(ins.madeAt.formatted(date: .abbreviated, time: .shortened))")
            .font(.caption).foregroundStyle(.tertiary)
    }

    private func aiBlock<C: View>(_ title: String, icon: String, tint: Color, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon).font(.caption.weight(.bold)).foregroundStyle(tint)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func noteChip(_ n: AIInsight.NoteRef) -> some View {
        Button { model.openNote(n.id, title: n.title) } label: {
            HStack(spacing: 4) {
                Image(systemName: "doc.text").font(.system(size: 10))
                Text(n.title).font(.caption).lineLimit(1).frame(maxWidth: 220, alignment: .leading)
            }
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Color.primary.opacity(0.07), in: Capsule())
        }
        .buttonStyle(.plain)
        .help("打开这条笔记")
    }
}

/// 洞察页的卡片：玻璃圆角底。`height` 给了就固定高度
private struct InsightCard<Content: View>: View {
    var height: CGFloat?
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .frame(height: height)
            .glassCard(radius: 18)
    }
}
