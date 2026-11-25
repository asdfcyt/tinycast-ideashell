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
    @AppStorage("tp.goalHours") private var goalHours = 4.0
    @AppStorage("tp.workDays") private var workDays = 5.0
    /// 统计范围（天）：0 = 全部。AI 洞察和笔记节奏最多读 30 天，其余按本机账本统计
    @AppStorage("insights.scope") private var scope = 14
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
        TimePrice(monthlyPay: pay, paidHoursPerWeek: paidHours, unpaidHoursPerWeek: unpaidHours, monthlyJobCost: jobCost, goalHoursPerDay: goalHours, workDaysPerWeek: workDays)
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
                Picker("范围", selection: $scope) {
                    Text("7 天").tag(7)
                    Text("14 天").tag(14)
                    Text("30 天").tag(30)
                    Text("90 天").tag(90)
                    Text("全部").tag(0)
                }
                .pickerStyle(.segmented)
                .help("统计范围")
            }
        }
        .task(id: scope) {
            let review = scope == 0 ? 30 : min(scope, 30)
            if model.reviewDays != review { model.reviewDays = review }
            await model.loadReview(ifStale: true)
            FocusLedger.shared.seedIfNeeded(model: model)
            ledgerRev += 1
            await model.refreshOutputLedger()
            ledgerRev += 1
        }
    }

    // MARK: - 内容

    /// 统计范围的天数：「全部」= 从最早的记录到今天
    private var scopeDays: Int {
        if scope != 0 { return scope }
        let today = Day.today()
        let first = [FocusLedger.shared.items.first?.day, OutputLedger.shared.firstDay].compactMap { $0 }.min() ?? today
        return max(Day.diff(first, today) + 1, 7)
    }

    @ViewBuilder private func content(_ r: ReviewData) -> some View {
        let _ = ledgerRev
        let items = FocusLedger.shared.items
        let days = scopeDays
        let stats = WorkStats.compute(days: days, entries: items)
        let perf = stats.perf(price: price)
        let prevStats: WorkStats? = scope == 0 ? nil : WorkStats.compute(days: days, entries: items, ending: Day.add(Day.today(), days: -days))
        let prevPerf = prevStats?.perf(price: price)
        let rate = price.effectiveHourly(workMin: stats.workMin, days: days)
        let prevRate = prevStats.flatMap { price.effectiveHourly(workMin: $0.workMin, days: days) }

        if let e = model.reviewError { ErrorBanner(text: e) { Task { await model.loadReview() } } }
        if let e = r.todoError { ErrorBanner(text: "待办读取失败：" + e) { Task { await model.loadReview() } } }

        section("我比以前快了吗") { heroCard(stats, perf: perf, prevPerf: prevPerf, rate: rate) }

        section("时间价格") { priceCard(stats, rate: rate, prevRate: prevRate) }

        section("时薪日历") { RateCalendar(price: price, items: items, tag: model.workTag, rev: ledgerRev) }

        section("长期趋势") { longTermCard(items) }

        section("AI 洞察") { aiCard(r) }

        section(scope == 0 ? "全部时间的工作时间" : "最近 \(days) 天的工作时间") { workCard(stats, rate: rate) }

        if !stats.projects.isEmpty {
            section("时间花在哪") { whereCard(stats, rate: rate) }
        }

        section("效率细节") { efficiencyCard(stats, perf: perf) }

        let stale = staleTasks()
        section("该消除的") { eliminateCard(stale, rate: rate) }

        if r.totalNotes + r.totalDone > 0 {
            section("记录节奏（最近 \(r.days) 天）") { rhythmCard(r) }
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

    // MARK: - 我比以前快了吗

    private func change(_ cur: Double?, _ prev: Double?) -> (text: String, up: Bool)? {
        guard let cur, let prev, prev > 0 else { return nil }
        let d = Int(((cur / prev - 1) * 100).rounded())
        if d == 0 { return ("与上期持平", true) }
        return (d > 0 ? "比上期高 \(d)%" : "比上期低 \(-d)%", d > 0)
    }

    private func heroCard(_ s: WorkStats, perf: WorkPerf, prevPerf: WorkPerf?, rate: Double?) -> some View {
        let p = price
        let eff = change(perf.perHour, prevPerf?.perHour)
        let timeCut: (text: String, up: Bool)? = prevPerf.flatMap { pp in
            guard pp.workMin > 0 else { return nil }
            let d = Int(((Double(perf.workMin) / Double(pp.workMin) - 1) * 100).rounded())
            return d == 0 ? ("与上期持平", true) : (d < 0 ? "比上期少 \(-d)%" : "比上期多 \(d)%", d < 0)
        }
        let goal = p.goalHoursPerDay
        return InsightCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        metric("工作效率", value: perf.perHour.map { String(format: "%.1f", $0) } ?? "–", unit: perf.perHour == nil ? nil : "项 / 小时",
                               note: eff?.text ?? "每专注工作 1 小时完成的产出", tint: eff.map { $0.up ? .green : .orange } ?? workColor)
                    }
                    Divider().frame(height: 62)
                    metric("工作用时", value: fmtMin(s.workMin), note: timeCut?.text ?? "日均 \(fmtMin(s.workMin / max(s.days, 1)))",
                           tint: timeCut.map { $0.up ? .green : .orange } ?? .primary)
                    Divider().frame(height: 62)
                    if goal > 0 {
                        metric("省下的时间", value: fmtMin(perf.savedMin), note: p.configured ? "≈ \(TimePrice.money(Double(perf.savedMin) / 60 * p.realHourly))（按在岗时薪）· 目标 \(trimmed(goal)) 小时 / 天" : "目标 \(trimmed(goal)) 小时 / 天",
                               tint: perf.savedMin > 0 ? .green : .primary)
                    } else {
                        metric("省下的时间", value: "–", note: "在「调整」里填每天目标专注工作时长")
                    }
                }
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "lightbulb.fill").foregroundStyle(.yellow)
                    Text(heroSentence(s, perf: perf, prevPerf: prevPerf)).font(.callout).fixedSize(horizontal: false, vertical: true)
                }
                Text("产出 = 完成的工作待办（结审任务 + 「\(model.workTag)」标签的待办），高优先级算 2 项；用时 = 这些工作的专注时间。省下的时间 = 工作日里，当天有产出、又比每天目标少花的那部分。")
                    .font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func trimmed(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v) }

    private func heroSentence(_ s: WorkStats, perf: WorkPerf, prevPerf: WorkPerf?) -> String {
        guard let cur = perf.perHour else {
            return "还没有足够的数据：用专注去做工作任务，并把它们完成，这里就会开始算你的效率。"
        }
        if let prev = prevPerf?.perHour {
            let expected = Double(perf.out) / prev
            let actual = Double(perf.workMin) / 60
            let diff = expected - actual
            if diff >= 0.5 { return "按上期的效率，这期的产出要花 \(String(format: "%.1f", expected)) 小时，实际只花了 \(String(format: "%.1f", actual)) 小时——省下 \(String(format: "%.1f", diff)) 小时，可以拿去做自己想做的事。" }
            if diff <= -0.5 { return "按上期的效率，这期的产出只需 \(String(format: "%.1f", expected)) 小时，实际花了 \(String(format: "%.1f", actual)) 小时，多花了 \(String(format: "%.1f", -diff)) 小时。看看「时间花在哪」里是不是被零碎的事拖住了。" }
            return "效率和上期差不多。想再快一点：砍掉不重要的、把最难的放进黄金时段、给任务定更短的期限。"
        }
        return "现在平均每专注工作 1 小时完成 \(String(format: "%.1f", cur)) 项。下一个周期开始，就能和这个数比较，看有没有越来越快。"
    }

    // MARK: - 长期趋势

    private struct MonthRow: Identifiable {
        let id: String
        let label: String
        let workMin: Int
        let rate: Double?
        let perHour: Double?
    }

    private func monthRows(_ items: [FocusLedgerEntry]) -> [MonthRow] {
        let today = Day.today()
        guard let firstRecord = [items.first?.day, OutputLedger.shared.firstDay].compactMap({ $0 }).min() else { return [] }
        let p = price
        let cal = Day.cal
        let curMonth = cal.date(from: cal.dateComponents([.year, .month], from: Date())) ?? Date()
        var rows: [MonthRow] = []
        for back in stride(from: 11, through: 0, by: -1) {
            guard let ms = cal.date(byAdding: .month, value: -back, to: curMonth),
                  let nextMs = cal.date(byAdding: .month, value: 1, to: ms),
                  let lastDate = cal.date(byAdding: .day, value: -1, to: nextMs) else { continue }
            let startDay = max(Day.string(ms), firstRecord)
            let endDay = min(Day.string(lastDate), today)
            guard startDay <= endDay else { continue }
            let n = Day.diff(startDay, endDay) + 1
            let st = WorkStats.compute(days: n, entries: items, ending: endDay)
            let pf = st.perf(price: p)
            let label = "\(cal.component(.month, from: ms))月"
            rows.append(MonthRow(id: Day.string(ms), label: label, workMin: st.workMin, rate: p.effectiveHourly(workMin: st.workMin, days: n), perHour: pf.perHour))
        }
        return rows
    }

    private func longTermCard(_ items: [FocusLedgerEntry]) -> some View {
        let p = price
        let rows = monthRows(items)
        let today = Day.today()
        let first = [items.first?.day, OutputLedger.shared.firstDay].compactMap { $0 }.min() ?? today
        let totalDays = max(Day.diff(first, today) + 1, 1)
        let all = WorkStats.compute(days: totalDays, entries: items)
        let ap = all.perf(price: p)
        let rateRows = rows.filter { $0.rate != nil }
        let perRows = rows.filter { $0.perHour != nil }
        return InsightCard {
            VStack(alignment: .leading, spacing: 16) {
                cardHeader("不随上面的范围变化 · 最近 12 个月", icon: "chart.line.uptrend.xyaxis", tint: hourColor, trailing: "从 \(shortDay(first)) 起")
                HStack(alignment: .top, spacing: 16) {
                    metric("累计专注工作", value: fmtMin(all.workMin), note: "共 \(all.sessions) 次专注")
                    Divider().frame(height: 62)
                    metric("累计完成", value: "\(ap.count)", unit: "个", note: "工作待办；全部 \(ap.all) 个")
                    Divider().frame(height: 62)
                    metric("累计省下", value: fmtMin(ap.savedMin), note: p.configured ? "≈ \(TimePrice.money(Double(ap.savedMin) / 60 * p.realHourly))" : nil, tint: ap.savedMin > 0 ? .green : .primary)
                }
                if rateRows.count >= 1 || perRows.count >= 1 {
                    HStack(alignment: .top, spacing: 16) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("有效时薪（元 / 小时）").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            if rateRows.isEmpty {
                                Text("填写时间价格后显示").font(.caption).foregroundStyle(.tertiary).frame(height: 120, alignment: .center)
                            } else {
                                Chart(rateRows) { r in
                                    BarMark(x: .value("月", r.label), y: .value("有效时薪", r.rate ?? 0))
                                        .foregroundStyle(workColor.gradient)
                                        .annotation(position: .top) { Text(TimePrice.money(r.rate ?? 0)).font(.system(size: 9)).foregroundStyle(.secondary) }
                                }
                                .chartYAxis(.hidden)
                                .frame(height: 120)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("每工作小时完成（项）").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            if perRows.isEmpty {
                                Text("完成工作待办后显示").font(.caption).foregroundStyle(.tertiary).frame(height: 120, alignment: .center)
                            } else {
                                Chart(perRows) { r in
                                    LineMark(x: .value("月", r.label), y: .value("效率", r.perHour ?? 0))
                                        .foregroundStyle(Color.green).interpolationMethod(.catmullRom)
                                    PointMark(x: .value("月", r.label), y: .value("效率", r.perHour ?? 0))
                                        .foregroundStyle(Color.green)
                                        .annotation(position: .top) { Text(String(format: "%.1f", r.perHour ?? 0)).font(.system(size: 9)).foregroundStyle(.secondary) }
                                }
                                .chartYAxis(.hidden)
                                .frame(height: 120)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let a = rateRows.first, let b = rateRows.last, a.id != b.id, let ra = a.rate, let rb = b.rate, ra > 0 {
                        let d = Int(((rb / ra - 1) * 100).rounded())
                        Text("有效时薪从 \(a.label)的 \(TimePrice.money(ra)) 到 \(b.label)的 \(TimePrice.money(rb))，\(d >= 0 ? "高了" : "低了") \(abs(d))%。")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                } else {
                    Text("数据还不够画趋势：持续用专注做工作任务、完成待办，一两个月后这里会显示你是不是越来越快。")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - 时间价格

    /// 把一段分钟数按有效时薪折成钱
    private func worth(_ minutes: Int, _ rate: Double?) -> String? {
        rate.map { TimePrice.money($0 * Double(minutes) / 60) }
    }

    private func rateNote(_ p: TimePrice, _ s: WorkStats, rate: Double, prevRate: Double?) -> String {
        var t = "净收入 \(TimePrice.money(p.periodNet(days: s.days))) ÷ 专注工作 \(fmtMin(s.workMin))"
        if let pr = prevRate, pr > 0 {
            let d = Int(((rate / pr - 1) * 100).rounded())
            t += d == 0 ? "，与上期持平" : "，较上期\(d > 0 ? "高" : "低") \(abs(d))%"
        }
        return t
    }

    private func priceCard(_ s: WorkStats, rate: Double?, prevRate: Double?) -> some View {
        let p = price
        let onDuty = p.onDutyMinutes(days: s.days)
        let idleMin = max(Int(onDuty) - s.workMin, 0)
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
                        if let rate {
                            let trend = rateNote(p, s, rate: rate, prevRate: prevRate)
                            metric("有效时薪", value: TimePrice.money(rate), unit: "/ 小时", note: trend, tint: workColor)
                        } else {
                            metric("有效时薪", value: "–", note: "最近 \(s.days) 天的工作时间不足 30 分钟，用结审任务或「\(model.workTag)」标签的任务专注、或在结审便签里工作后才能算", tint: workColor)
                        }
                        Divider().frame(height: 62)
                        metric("在岗时薪", value: TimePrice.money(p.realHourly), unit: "/ 小时",
                               note: "按在岗 \(Int(p.totalMonthlyHours.rounded())) 小时 / 月算的底价（含通勤 / 加班，扣工作花费）")
                        Divider().frame(height: 62)
                        if let rate {
                            metric("每分钟", value: TimePrice.money(rate / 60), unit: "/ 分钟", note: "一个番茄 25 分钟 ≈ \(TimePrice.money(rate * 25 / 60))；刷 10 分钟手机 ≈ \(TimePrice.money(rate / 6))")
                        } else {
                            metric("每分钟", value: TimePrice.money(p.realHourly / 60), unit: "/ 分钟", note: "按在岗时薪折算")
                        }
                    }
                    if onDuty > 0 {
                        let ratio = Double(s.workMin) / onDuty
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "lightbulb.fill").foregroundStyle(.yellow)
                            Text("最近 \(s.days) 天在岗约 \(fmtMin(Int(onDuty)))，真正专注工作 \(fmtMin(s.workMin))（\(Int((ratio * 100).rounded()))%），其余 \(fmtMin(idleMin)) 没有专注产出，按底价折合 \(TimePrice.money(Double(idleMin) / 60 * p.realHourly))。有效时薪的关键：同样的活，花的时间越少，这个数就越高。")
                                .font(.callout).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Text("统计专注记录里的工作时间（结审任务 + 「\(model.workTag)」标签），再加上结审便签在前台的时间（\(fmtMin(s.stickyMin))，没点专注时便签标题栏的计时自动记入）；在其他地方做的工作不会算进去。")
                        .font(.caption).foregroundStyle(.tertiary)
                } else {
                    Text("填上每月到手收入、每周工时和工作花费：有效时薪 = 净收入 ÷ 你真正专注工作的时间，做同样的事花得越少、时间越值钱；在岗时薪是按坐在岗位上的时间算的底价，两者的差距就是时间的浪费。")
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
            priceField("每周工作几天", unit: "天", value: $workDays, hint: "周一起算；决定哪些天算工作日、时薪日历里每天分到多少收入")
            priceField("每天目标专注工作", unit: "小时", value: $goalHours, hint: "比它少花、又把事做完，省下的时间就记在「省下的时间」里")
            HStack {
                Text("「工作」标签").font(.callout)
                Spacer()
                TextField("工作", text: $workTag).textFieldStyle(.roundedBorder).frame(width: 110).multilineTextAlignment(.trailing)
            }
            Divider()
            Text("有效时薪 = (收入 − 工作花费) ÷ 实际专注工作的时间；在岗时薪 = 同样的净收入 ÷ (有薪 + 无薪工时)。结审里的任务一律算工作；其他待办带上「\(workTag.trimmed.isEmpty ? "工作" : workTag)」标签才算工作，其余是普通时间。数据只存在这台电脑上。")
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

    private func workCard(_ s: WorkStats, rate: Double?) -> some View {
        let p = price
        let total = max(s.totalMin, 1)
        let step = s.days <= 8 ? 1 : Int((Double(s.days) / 6).rounded(.up))
        let paidMin = p.paidHoursPerWeek * 60 * Double(s.days) / 7
        return InsightCard {
            VStack(alignment: .leading, spacing: 14) {
                cardHeader("专注时间", icon: "timer", tint: workColor, trailing: "工作 = 结审任务 + 「\(model.workTag)」标签")
                if s.totalMin == 0 {
                    Text("这段时间还没有专注记录。从现在起，每次专注、以及在结审便签里工作的时间都会记进来，并按工作 / 普通时间分开统计。")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    HStack(alignment: .top, spacing: 16) {
                        metric("工作", value: fmtMin(s.workMin), note: rate != nil ? "对应本期净收入 \(TimePrice.money(p.periodNet(days: s.days)))" : nil, tint: workColor)
                        Divider().frame(height: 62)
                        metric("普通时间", value: fmtMin(s.normalMin), note: worth(s.normalMin, rate).map { "按有效时薪折算 \($0)" })
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
                            metric("专注占比", value: "\(Int((ratio * 100).rounded()))%", note: "工作专注 ÷ 在岗时间，越高越不浪费", tint: ratio >= 0.4 ? .green : .primary)
                        } else {
                            metric("专注占比", value: "–", note: "填写时间价格后显示")
                        }
                    }
                }
            }
        }
    }

    // MARK: - 时间花在哪（80/20）

    private func whereCard(_ s: WorkStats, rate: Double?) -> some View {
        let rows = Array(s.projects.prefix(6))
        let maxMin = max(rows.first?.minutes ?? 1, 1)
        return InsightCard {
            VStack(alignment: .leading, spacing: 14) {
                cardHeader("按项目", icon: "chart.bar.doc.horizontal.fill", tint: noteColor, trailing: rate != nil ? "时长 · 价值" : "时长")
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(rows) { it in projectRow(it, maxMin: maxMin, total: s.totalMin, rate: rate) }
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
                    Text("最费时间的是「\(top.name)」，\(fmtMin(top.minutes))\(worth(top.minutes, rate).map { "，约 \($0)" } ?? "")。")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func projectRow(_ it: WorkStats.Item, maxMin: Int, total: Int, rate: Double?) -> some View {
        let tint = it.work ? workColor : normalColor.opacity(0.5)
        let share = Int((Double(it.minutes) / Double(max(total, 1)) * 100).rounded())
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: it.work ? "briefcase.fill" : "person.fill").font(.system(size: 11)).foregroundStyle(it.work ? workColor : Color.secondary)
                Text(it.name).font(.callout.weight(.medium)).lineLimit(1)
                Spacer(minLength: 8)
                Text(fmtMin(it.minutes)).font(.callout).monospacedDigit()
                Text("\(share)%").font(.caption).foregroundStyle(.tertiary).monospacedDigit().frame(width: 34, alignment: .trailing)
                if let w = worth(it.minutes, rate) {
                    Text(w).font(.callout.weight(.semibold)).monospacedDigit()
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

    private func efficiencyCard(_ s: WorkStats, perf: WorkPerf) -> some View {
        let highShare = perf.count > 0 ? Int((Double(perf.high) / Double(perf.count) * 100).rounded()) : nil
        return InsightCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 16) {
                    metric("工作待办完成", value: "\(perf.count)", unit: "个", note: "全部完成 \(perf.all) 个；高优先级算 2 份产出")
                    Divider().frame(height: 62)
                    if perf.count > 0, perf.workMin > 0 {
                        metric("每个待办用时", value: fmtMin(perf.workMin / perf.count), note: "工作专注 ÷ 完成数，越短越高效")
                    } else {
                        metric("每个待办用时", value: "–", note: "需要工作专注记录和已完成的工作待办")
                    }
                    Divider().frame(height: 62)
                    metric("高优先级占比", value: highShare.map { "\($0)%" } ?? "–", note: highShare == nil ? nil : "完成的工作里有 \(perf.high) 个高优先级",
                           tint: (highShare ?? 0) >= 30 ? .green : .primary)
                }
                goldenCard(s)
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

    private func eliminateCard(_ stale: [Stale], rate: Double?) -> some View {
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
                        Text("按你的\(rate != nil ? "有效" : "在岗")时薪 \(TimePrice.money(rate ?? p.realHourly))/小时：一件事如果花钱外包、或用工具自动化的成本低于这个数，就别自己做；做不做都行的，直接消除。给任务设更短的期限——任务会膨胀到占满你给它的时间（帕金森定律）。")
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


// MARK: - 时薪日历

/// 每天一格：当天有效时薪 = 当天分到的净收入 ÷ 当天专注工作的时间。颜色越深越值钱；休息日只显示工作时长
private struct RateCalendar: View {
    @EnvironmentObject var model: AppModel
    let price: TimePrice
    let items: [FocusLedgerEntry]
    let tag: String
    let rev: Int
    @State private var month = Date()
    @State private var selected: String?

    private struct Cell {
        let day: String
        let inMonth: Bool
        let workMin: Int
        let rate: Double?
        let out: Int
    }

    private let workColor = Brand.orange
    private let minMin = 15

    private var monthStart: Date { Day.cal.date(from: Day.cal.dateComponents([.year, .month], from: month)) ?? month }

    private func cells() -> [Cell] {
        let _ = rev
        var work: [String: Int] = [:]
        for e in items where e.work { work[e.day, default: 0] += e.minutes }
        let mStart = monthStart
        let grid = AppModel.calendarGrid(for: mStart)
        let today = Day.today()
        let ms = Day.string(mStart)
        let me = Day.string(Day.cal.date(byAdding: .day, value: -1, to: Day.cal.date(byAdding: .month, value: 1, to: mStart) ?? mStart) ?? mStart)
        var out: [Cell] = grid.map { d in
            let inM = d >= ms && d <= me
            let m = work[d] ?? 0
            var rate: Double?
            if inM, d <= today, price.configured, price.isWorkday(d), m >= minMin { rate = price.dailyNet / (Double(m) / 60) }
            return Cell(day: d, inMonth: inM, workMin: m, rate: rate, out: OutputLedger.shared.out(d).weighted)
        }
        // 最后一整行都不在本月就不画
        while out.count > 35, !out.suffix(7).contains(where: { $0.inMonth }) { out.removeLast(7) }
        return out
    }

    private func money(_ v: Double) -> String {
        v >= 10000 ? String(format: "¥%.1f万", v / 10000) : (v >= 1000 ? String(format: "¥%.1fk", v / 1000) : "¥" + String(format: "%.0f", v))
    }

    private func hours(_ m: Int) -> String {
        m < 60 ? "\(m)分" : (m % 60 == 0 ? "\(m / 60)h" : String(format: "%.1fh", Double(m) / 60))
    }

    var body: some View {
        let cs = cells()
        let rates = cs.compactMap(\.rate).sorted()
        let ref = rates.isEmpty ? 1 : max(rates[min(Int(Double(rates.count) * 0.9), rates.count - 1)], 1)
        let today = Day.today()
        let monthCells = cs.filter { $0.inMonth && $0.day <= today }
        let monthWork = monthCells.reduce(0) { $0 + $1.workMin }
        let elapsed = monthCells.count
        let monthRate = price.configured && monthWork >= 30 ? price.periodNet(days: elapsed) / (Double(monthWork) / 60) : nil
        let monthOut = monthCells.reduce(0) { $0 + $1.out }
        let best = cs.compactMap { c in c.rate.map { (c.day, $0) } }.max { $0.1 < $1.1 }
        let weekdays = ["一", "二", "三", "四", "五", "六", "日"]
        return InsightCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Text(monthTitle).font(.headline)
                    Spacer(minLength: 8)
                    Button { shift(-1) } label: { Image(systemName: "chevron.left") }.buttonStyle(.borderless)
                    Button("本月") { month = Date(); selected = nil }.buttonStyle(.bordered).controlSize(.small)
                    Button { shift(1) } label: { Image(systemName: "chevron.right") }.buttonStyle(.borderless)
                }

                if !price.configured {
                    Text("先在上面的「时间价格」里填好每月收入，日历才能算出每天的时薪。下面显示的是每天的工作时长。")
                        .font(.caption).foregroundStyle(.secondary)
                }

                HStack(alignment: .top, spacing: 16) {
                    stat("本月有效时薪", monthRate.map { money($0) + " / 小时" } ?? "–")
                    stat("工作时长", hours(monthWork))
                    stat("完成产出", "\(monthOut) 项")
                    stat("最高的一天", best.map { "\(shortDay($0.0)) \(money($0.1))" } ?? "–")
                }

                VStack(spacing: 4) {
                    HStack(spacing: 4) {
                        ForEach(weekdays, id: \.self) { w in
                            Text(w).font(.caption2.weight(.medium)).foregroundStyle(.tertiary).frame(maxWidth: .infinity)
                        }
                    }
                    ForEach(0 ..< cs.count / 7, id: \.self) { row in
                        HStack(spacing: 4) {
                            ForEach(0 ..< 7, id: \.self) { col in cell(cs[row * 7 + col], ref: ref, today: today) }
                        }
                    }
                }

                if let sel = selected { detail(sel) }
            }
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 17, weight: .semibold, design: .rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func cell(_ c: Cell, ref: Double, today: String) -> some View {
        let isToday = c.day == today
        let sel = selected == c.day
        let strength = c.rate.map { min($0 / ref, 1) } ?? 0
        let n = Int(c.day.suffix(2)) ?? 0
        return Button {
            selected = selected == c.day ? nil : c.day
        } label: {
            VStack(spacing: 2) {
                HStack {
                    Text("\(n)").font(.system(size: 10, weight: isToday ? .bold : .regular)).foregroundStyle(isToday ? workColor : Color.secondary)
                    Spacer(minLength: 0)
                    if c.out > 0 { Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.green) }
                }
                Spacer(minLength: 0)
                if let r = c.rate {
                    Text(money(r)).font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                    Text(hours(c.workMin)).font(.system(size: 9)).foregroundStyle(.secondary)
                } else if c.workMin > 0 {
                    Text(hours(c.workMin)).font(.system(size: 11)).foregroundStyle(.secondary)
                    Text(price.isWorkday(c.day) ? "太短" : "休息日").font(.system(size: 9)).foregroundStyle(.tertiary)
                } else {
                    Text(" ").font(.system(size: 13))
                    Text(" ").font(.system(size: 9))
                }
            }
            .padding(.horizontal, 6).padding(.vertical, 5)
            .frame(maxWidth: .infinity).frame(height: 58)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(c.rate != nil ? workColor.opacity(0.12 + 0.5 * strength) : Color.primary.opacity(c.inMonth ? 0.05 : 0.0))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(sel ? Color.accentColor : (isToday ? workColor.opacity(0.6) : Color.clear), lineWidth: sel ? 2 : 1)
            )
            .opacity(c.inMonth ? 1 : 0.0)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!c.inMonth)
    }

    private func detail(_ day: String) -> some View {
        let list = items.filter { $0.day == day }.sorted { $0.startMs < $1.startMs }
        let o = OutputLedger.shared.out(day)
        let wm = list.filter(\.work).reduce(0) { $0 + $1.minutes }
        return VStack(alignment: .leading, spacing: 6) {
            Divider()
            HStack {
                Text(Day.label(day)).font(.callout.weight(.semibold))
                Spacer()
                Text("完成工作 \(o.count) 个 · 工作专注 \(hours(wm))").font(.caption).foregroundStyle(.secondary)
            }
            if list.isEmpty {
                Text("这天没有专注记录").font(.caption).foregroundStyle(.tertiary)
            } else {
                ForEach(Array(list.prefix(10).enumerated()), id: \.offset) { _, e in
                    HStack(spacing: 8) {
                        Image(systemName: e.work ? "briefcase.fill" : "person.fill").font(.system(size: 10)).foregroundStyle(e.work ? workColor : Color.secondary)
                        Text(clock(e.startDate)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        Text(e.title.isEmpty ? "自由专注" : e.title).font(.callout).lineLimit(1)
                        if e.isSticky { Text("便签").font(.system(size: 9.5, weight: .medium)).foregroundStyle(.secondary).padding(.horizontal, 4).padding(.vertical, 1).background(Color.primary.opacity(0.07), in: Capsule()) }
                        Spacer(minLength: 8)
                        Text(hours(e.minutes)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                if list.count > 10 { Text("还有 \(list.count - 10) 次").font(.caption).foregroundStyle(.tertiary) }
            }
        }
    }

    private func clock(_ d: Date) -> String {
        let c = Day.cal.dateComponents([.hour, .minute], from: d)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    private func shortDay(_ s: String) -> String {
        let p = s.split(separator: "-")
        guard p.count == 3, let m = Int(p[1]), let d = Int(p[2]) else { return s }
        return "\(m)/\(d)"
    }

    private var monthTitle: String {
        let c = Day.cal.dateComponents([.year, .month], from: month)
        return "\(c.year ?? 0) 年 \(c.month ?? 0) 月"
    }

    private func shift(_ n: Int) {
        month = Day.cal.date(byAdding: .month, value: n, to: month) ?? month
        selected = nil
    }
}
