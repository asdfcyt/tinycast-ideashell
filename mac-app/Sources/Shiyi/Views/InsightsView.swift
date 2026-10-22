import Charts
import SwiftUI

/// 洞察：参考 Apple 健康 / 屏幕使用时间——浅灰底、白色圆角卡片、每张卡片「小标题 → 一个大数字 → 图表」，
/// 一种数据一种颜色（笔记蓝、待办绿、专注橙、时段靛），图表只留必要的坐标；鼠标移到柱子上看当天的具体数字。
struct InsightsView: View {
    @EnvironmentObject var model: AppModel
    @State private var selectedDate: Date?

    private var noData: Bool { !model.hasIdeashell && !model.hasDida }

    private let noteColor = Color.blue
    private let doneColor = Color.green
    private let focusColor = Color.orange
    private let hourColor = Color.indigo

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
        .task(id: model.reviewDays) { await model.loadReview(ifStale: true) }
    }

    // MARK: - 内容

    @ViewBuilder private func content(_ r: ReviewData) -> some View {
        if let e = model.reviewError { ErrorBanner(text: e) { Task { await model.loadReview() } } }
        if let e = r.todoError { ErrorBanner(text: "待办读取失败：" + e) { Task { await model.loadReview() } } }

        if r.totalNotes + r.totalDone == 0 {
            EmptyHint(icon: "chart.bar", title: "这段时间还没有记录").frame(height: 240)
        } else {
            section("AI 洞察") { aiCard(r) }

            let notes = highlights(r)
            if !notes.isEmpty {
                section("发现") { highlightsCard(notes) }
            }

            section("最近 \(r.days) 天") {
                summaryCard(r)
                activityCard(r)
            }

            section("习惯") {
                pair {
                    if r.peakLabel != nil { hoursCard(r) }
                    if r.weekdays.contains(where: { $0.total > 0 }) { weekdayCard(r) }
                }
            }

            if r.onTime + r.lateDone > 0 || !r.projects.isEmpty {
                section("进展") {
                    pair {
                        if r.onTime + r.lateDone > 0 { completionCard(r) }
                        if !r.projects.isEmpty { projectsCard(r) }
                    }
                }
            }

            if r.donePriority.reduce(0, +) > 0 || r.focusTotalMin > 0 {
                section("待办与专注") {
                    pair {
                        if r.donePriority.reduce(0, +) > 0 { priorityCard(r) }
                        if r.focusTotalMin > 0 { focusHoursCard(r) }
                    }
                }
            }

            if !r.topTags.isEmpty || r.focusTotalMin > 0 {
                section("主题与专注") {
                    pair {
                        if !r.topTags.isEmpty { tagsCard(r) }
                        if r.focusTotalMin > 0 { focusCard(r) }
                    }
                }
            }
            if r.truncated {
                Text("某个时段笔记过多，统计可能不完整").font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    private func section<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title3.weight(.bold))
            content()
        }
    }

    /// 两张卡片并排；只有一张时占满一行。卡片等高
    private func pair<C: View>(@ViewBuilder content: () -> C) -> some View {
        HStack(alignment: .top, spacing: 16) { content() }
    }

    // MARK: - 概览

    private func summaryCard(_ r: ReviewData) -> some View {
        InsightCard {
            HStack(spacing: 0) {
                metric(icon: "doc.text.fill", tint: noteColor, value: "\(r.totalNotes)", unit: "条", label: "笔记",
                       trend: trend(r.totalNotes, r.prev?.notes))
                Divider().frame(height: 62)
                metric(icon: "checkmark.circle.fill", tint: doneColor, value: "\(r.totalDone)", unit: "个", label: "完成待办",
                       trend: trend(r.totalDone, r.prev?.done))
                Divider().frame(height: 62)
                metric(icon: "calendar", tint: hourColor, value: "\(r.activeDays)", unit: "/ \(r.days) 天", label: "有记录",
                       trend: trend(r.activeDays, r.prev?.activeDays))
                Divider().frame(height: 62)
                metric(icon: "flame.fill", tint: .orange, value: "\(r.streak)", unit: "天", label: "连续记录",
                       trend: r.longestStreak > 0 ? ("最长 \(r.longestStreak) 天", .secondary) : nil)
            }
        }
    }

    /// 和上一个同样长度的时间段比：↑ 12% / ↓ 8% / 持平
    private func trend(_ cur: Int, _ prev: Int?) -> (String, Color)? {
        guard let prev else { return nil }
        if prev == 0 { return cur > 0 ? ("上期没有", .secondary) : nil }
        let pct = Int((Double(cur - prev) / Double(prev) * 100).rounded())
        if pct == 0 { return ("与上期持平", .secondary) }
        return (pct > 0 ? "↑ \(pct)% 较上期" : "↓ \(-pct)% 较上期", pct > 0 ? .green : .orange)
    }

    private func metric(icon: String, tint: Color, value: String, unit: String, label: String, trend: (String, Color)?) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(label, systemImage: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit()
                Text(unit).font(.callout).foregroundStyle(.secondary)
            }
            Text(trend?.0 ?? " ").font(.caption2.weight(.medium)).foregroundStyle(trend?.1 ?? .clear).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
    }

    // MARK: - 发现

    private func highlights(_ r: ReviewData) -> [(icon: String, tint: Color, text: String)] {
        var out: [(String, Color, String)] = []
        if let b = r.bestDay, r.days > 1 {
            out.append(("star.fill", .yellow, "最活跃的一天是 \(Day.label(b.day))：\(b.notes) 条笔记，完成 \(b.done) 个待办"))
        }
        if let w = r.weekdays.max(by: { $0.avg < $1.avg }), w.avg > 0, w.occurrences >= 2 {
            out.append(("calendar.badge.clock", hourColor, "\(w.label)最活跃，平均每个\(w.label)约 \(String(format: "%.1f", w.avg)) 项"))
        }
        if let p = r.prev {
            let changes: [(String, Int, Int)] = [("笔记", r.totalNotes, p.notes), ("完成的待办", r.totalDone, p.done)]
            if let big = changes.filter({ $0.2 > 0 }).max(by: { abs($0.1 - $0.2) * 1000 / $0.2 < abs($1.1 - $1.2) * 1000 / $1.2 }), big.1 != big.2 {
                let pct = Int((Double(abs(big.1 - big.2)) / Double(big.2) * 100).rounded())
                out.append((big.1 > big.2 ? "arrow.up.right" : "arrow.down.right", big.1 > big.2 ? .green : .orange,
                            "\(big.0)比上一个 \(r.days) 天\(big.1 > big.2 ? "多" : "少")了 \(pct)%（\(big.2) → \(big.1)）"))
            }
        }
        if let p = r.projects.first {
            var parts: [String] = []
            if p.notes > 0 { parts.append("笔记 \(p.notes)") }
            if p.done > 0 { parts.append("待办 \(p.done)") }
            if p.focusMin > 0 { parts.append("专注 \(FocusParser.formatMinutes(p.focusMin))") }
            out.append(("folder.fill", noteColor, "投入最多的项目是「\(p.keyword)」：" + parts.joined(separator: " · ")))
        }
        if r.focusStats.sessions > 0 {
            out.append(("timer", focusColor, "专注了 \(r.focusStats.sessions) 次，平均 \(r.focusStats.avgMin) 分钟，最长一次 \(r.focusStats.longestMin) 分钟"))
        }
        if let t = r.topTags.first, t.count >= 2 {
            out.append(("number", noteColor, "最常写的话题是 #\(t.tag)，出现 \(t.count) 次"))
        }
        if r.longestGap >= 3, r.days >= 7 {
            out.append(("moon.zzz.fill", .secondary, "最长有 \(r.longestGap) 天没有记录，之后又重新捡了起来"))
        }
        if r.focusStats.sessions >= 3, let h = bestFocusStart(r) {
            out.append(("scope", focusColor, "你最容易进入专注的时段是 \(h)–\(h + 2) 点"))
        }
        let high = r.donePriority[3]
        if high > 0 {
            out.append(("flag.fill", .red, "完成了 \(high) 个高优先级待办，占已完成的 \(Int((Double(high) / Double(max(r.totalDone, 1)) * 100).rounded()))%"))
        }
        return Array(out.prefix(7))
    }

    /// 专注分钟最多的连续 3 小时的起点
    private func bestFocusStart(_ r: ReviewData) -> Int? {
        guard r.focusHours.reduce(0, +) > 0 else { return nil }
        var best = -1, at: Int?
        for s in 0 ... 21 {
            let sum = r.focusHours[s] + r.focusHours[s + 1] + r.focusHours[s + 2]
            if sum > best { best = sum; at = s }
        }
        return at
    }

    private func highlightsCard(_ items: [(icon: String, tint: Color, text: String)]) -> some View {
        InsightCard {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .center, spacing: 12) {
                        Image(systemName: item.icon)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(item.tint)
                            .frame(width: 28, height: 28)
                            .background(item.tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        Text(item.text).font(.callout).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    // MARK: - 卡片头

    private func cardHeader(_ title: String, icon: String, tint: Color, trailing: String? = nil) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(title).foregroundStyle(tint)
            Spacer(minLength: 8)
            if let trailing { Text(trailing).font(.caption).foregroundStyle(.tertiary) }
        }
        .font(.subheadline.weight(.semibold))
    }

    private func bigValue(_ value: String, _ unit: String? = nil, size: CGFloat = 28) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(value).font(.system(size: size, weight: .bold, design: .rounded)).monospacedDigit()
            if let unit { Text(unit).font(.callout.weight(.medium)).foregroundStyle(.secondary) }
        }
    }

    // MARK: - 每日活动

    private func activityCard(_ r: ReviewData) -> some View {
        let avg = Double(r.totalNotes + r.totalDone) / Double(max(r.days, 1))
        let picked: DayCount? = selectedDate.flatMap { d in
            let key = Day.string(d)
            return r.counts.first { $0.day == key }
        }
        let step = r.days <= 8 ? 1 : Int((Double(r.days) / 6).rounded(.up))
        return InsightCard {
            VStack(alignment: .leading, spacing: 12) {
                cardHeader("每日活动", icon: "chart.bar.fill", tint: noteColor, trailing: "笔记 + 完成待办")
                if let p = picked {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        bigValue("\(p.total)", "项")
                        Text(Day.label(p.day)).font(.callout).foregroundStyle(.secondary)
                        Text("笔记 \(p.notes) · 待办 \(p.done)").font(.callout).foregroundStyle(.tertiary)
                    }
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        bigValue(String(format: "%.1f", avg), "项 / 天")
                        Text("日均").font(.callout).foregroundStyle(.secondary)
                    }
                }
                Chart {
                    ForEach(r.counts) { c in
                        let d = Day.parse(c.day) ?? Date()
                        BarMark(x: .value("日期", d, unit: .day), y: .value("数量", c.notes))
                            .foregroundStyle(by: .value("类型", "笔记"))
                        BarMark(x: .value("日期", d, unit: .day), y: .value("数量", c.done))
                            .foregroundStyle(by: .value("类型", "完成待办"))
                    }
                    if let d = selectedDate {
                        RuleMark(x: .value("日期", d, unit: .day))
                            .foregroundStyle(Color.secondary.opacity(0.35))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    }
                }
                .chartForegroundStyleScale(["笔记": noteColor, "完成待办": doneColor])
                .chartLegend(position: .bottom, alignment: .leading, spacing: 8)
                .chartXSelection(value: $selectedDate)
                .chartXAxis { dayAxis(step: step) }
                .chartYAxis {
                    AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { _ in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Color.primary.opacity(0.1))
                        AxisValueLabel().font(.caption2)
                    }
                }
                .frame(height: 190)

                if r.streak == 0, let b = r.breakDay {
                    Text("最近一次有记录是 \(Day.label(b))").font(.caption).foregroundStyle(.secondary)
                } else if let b = r.breakDay, r.streak > 0 {
                    Text("连续记录 \(r.streak) 天，\(Day.label(b)) 那天断过").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// 日期横轴：按天取点（不会挤在一起），短格式「10/9」
    private func dayAxis(step: Int) -> some AxisContent {
        AxisMarks(values: .stride(by: .day, count: step)) { v in
            AxisValueLabel(centered: true) {
                if let d = v.as(Date.self) { Text(shortDay(Day.string(d))).font(.caption2).fixedSize() }
            }
        }
    }

    // MARK: - 记录时刻

    private func hoursCard(_ r: ReviewData) -> some View {
        InsightCard(height: 250) {
            VStack(alignment: .leading, spacing: 10) {
                cardHeader("记录时刻", icon: "clock.fill", tint: hourColor, trailing: "笔记 + 完成待办")
                VStack(alignment: .leading, spacing: 2) {
                    bigValue(r.peakLabel ?? "")
                    Text("你最常在这个时段\(r.peakVerb)").font(.callout).foregroundStyle(.secondary)
                }
                Chart {
                    if let s = r.peakStart {
                        RectangleMark(xStart: .value("起", Double(s) - 0.5), xEnd: .value("止", Double(s) + 2.5))
                            .foregroundStyle(hourColor.opacity(0.1))
                    }
                    ForEach(r.hoursSplit) { h in
                        BarMark(x: .value("小时", h.hour), y: .value("数量", h.notes), width: .fixed(6))
                            .foregroundStyle(by: .value("类型", "笔记"))
                        BarMark(x: .value("小时", h.hour), y: .value("数量", h.done), width: .fixed(6))
                            .foregroundStyle(by: .value("类型", "完成待办"))
                    }
                }
                .chartForegroundStyleScale(["笔记": noteColor, "完成待办": doneColor])
                .chartLegend(.hidden)
                .chartXScale(domain: 0 ... 23)
                .chartXAxis {
                    AxisMarks(values: [0, 6, 12, 18]) { v in
                        AxisValueLabel {
                            if let h = v.as(Int.self) { Text("\(h)时").font(.caption2) }
                        }
                    }
                }
                .chartYAxis(.hidden)
                .frame(maxHeight: .infinity)
            }
        }
    }

    // MARK: - 星期分布

    private func weekdayCard(_ r: ReviewData) -> some View {
        let best = r.weekdays.max(by: { $0.avg < $1.avg })
        let weekend = r.weekdays.filter { $0.index >= 5 }
        let weekendAvg = weekend.map(\.avg).reduce(0, +) / 2
        let weekdayAvg = r.weekdays.filter { $0.index < 5 }.map(\.avg).reduce(0, +) / 5
        return InsightCard(height: 250) {
            VStack(alignment: .leading, spacing: 10) {
                cardHeader("星期分布", icon: "calendar.day.timeline.left", tint: hourColor, trailing: "平均每天")
                VStack(alignment: .leading, spacing: 2) {
                    bigValue(best?.label ?? "–")
                    Text(weekendAvg > weekdayAvg * 1.2 ? "周末比工作日更活跃" : (weekdayAvg > weekendAvg * 1.2 ? "工作日比周末更活跃" : "工作日和周末差不多"))
                        .font(.callout).foregroundStyle(.secondary)
                }
                Chart(r.weekdays) { w in
                    BarMark(x: .value("星期", w.short), y: .value("平均", w.avg))
                        .foregroundStyle(w.index == best?.index ? hourColor : hourColor.opacity(0.28))
                        .cornerRadius(4)
                }
                .chartXAxis { AxisMarks { _ in AxisValueLabel().font(.caption2) } }
                .chartYAxis(.hidden)
                .frame(maxHeight: .infinity)
            }
        }
    }

    // MARK: - 按时完成

    private func completionCard(_ r: ReviewData) -> some View {
        let total = r.onTime + r.lateDone
        let ratio = Double(r.onTime) / Double(max(total, 1))
        return InsightCard(height: 250) {
            VStack(alignment: .leading, spacing: 10) {
                cardHeader("按时完成", icon: "checkmark.circle.fill", tint: doneColor)
                Spacer(minLength: 0)
                HStack(spacing: 20) {
                    ZStack {
                        Circle().stroke(doneColor.opacity(0.15), lineWidth: 13)
                        Circle()
                            .trim(from: 0, to: ratio)
                            .stroke(doneColor, style: StrokeStyle(lineWidth: 13, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        Text("\(Int((ratio * 100).rounded()))%")
                            .font(.system(size: 22, weight: .bold, design: .rounded)).monospacedDigit()
                    }
                    .frame(width: 104, height: 104)

                    VStack(alignment: .leading, spacing: 8) {
                        legendRow(color: doneColor, text: "按时", value: r.onTime)
                        legendRow(color: Color.primary.opacity(0.25), text: "过了计划日", value: r.lateDone)
                    }
                    Spacer(minLength: 0)
                }
                Spacer(minLength: 0)
                if let o = model.overview, !o.overdue.isEmpty {
                    Label("目前还有 \(o.overdue.count) 个逾期待办", systemImage: "exclamationmark.circle.fill")
                        .font(.callout).foregroundStyle(.red)
                } else {
                    Text("有计划日的 \(total) 个已完成待办").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func legendRow(color: Color, text: String, value: Int) -> some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text).font(.callout).foregroundStyle(.secondary)
            Text("\(value)").font(.callout.weight(.semibold)).monospacedDigit()
        }
    }

    // MARK: - 话题

    private func tagsCard(_ r: ReviewData) -> some View {
        let tags = Array(r.topTags.prefix(5))
        return InsightCard(height: 250) {
            VStack(alignment: .leading, spacing: 10) {
                cardHeader("话题", icon: "number", tint: noteColor, trailing: "按标签")
                if let top = tags.first {
                    VStack(alignment: .leading, spacing: 2) {
                        bigValue("#" + top.tag)
                        Text("出现 \(top.count) 次，最多").font(.callout).foregroundStyle(.secondary)
                    }
                }
                Chart(tags) { t in
                    BarMark(x: .value("次数", t.count), y: .value("标签", "#" + t.tag), height: .fixed(14))
                        .foregroundStyle(noteColor.gradient)
                        .cornerRadius(4)
                        .annotation(position: .trailing, spacing: 4) {
                            Text("\(t.count)").font(.caption2).foregroundStyle(.secondary)
                        }
                }
                .chartYScale(domain: tags.map { "#" + $0.tag })
                .chartXAxis(.hidden)
                .chartYAxis { AxisMarks { _ in AxisValueLabel().font(.caption) } }
                .frame(maxHeight: .infinity)
            }
        }
    }

    // MARK: - 项目投入

    private func projectsCard(_ r: ReviewData) -> some View {
        InsightCard(height: 250) {
            VStack(alignment: .leading, spacing: 10) {
                cardHeader("项目投入", icon: "folder.fill", tint: noteColor, trailing: "笔记 + 待办")
                if let top = r.projects.first {
                    VStack(alignment: .leading, spacing: 2) {
                        bigValue(top.keyword)
                        Text(top.focusMin > 0 ? "投入最多 · 专注 \(FocusParser.formatMinutes(top.focusMin))" : "投入最多").font(.callout).foregroundStyle(.secondary)
                    }
                }
                Chart {
                    ForEach(r.projects) { p in
                        BarMark(x: .value("数量", p.notes), y: .value("项目", p.keyword), height: .fixed(14))
                            .foregroundStyle(by: .value("类型", "笔记"))
                        BarMark(x: .value("数量", p.done), y: .value("项目", p.keyword), height: .fixed(14))
                            .foregroundStyle(by: .value("类型", "完成待办"))
                            .annotation(position: .trailing, spacing: 4) {
                                Text("\(p.total)").font(.caption2).foregroundStyle(.secondary)
                            }
                    }
                }
                .chartForegroundStyleScale(["笔记": noteColor, "完成待办": doneColor])
                .chartLegend(.hidden)
                .chartYScale(domain: r.projects.map(\.keyword))
                .chartXAxis(.hidden)
                .chartYAxis { AxisMarks { _ in AxisValueLabel().font(.caption) } }
                .frame(maxHeight: .infinity)
            }
        }
    }

    // MARK: - 专注

    private func focusCard(_ r: ReviewData) -> some View {
        let h = r.focusTotalMin / 60, m = r.focusTotalMin % 60
        let step = r.days <= 8 ? 1 : Int((Double(r.days) / 4).rounded(.up))
        let fs = r.focusStats
        return InsightCard(height: 250) {
            VStack(alignment: .leading, spacing: 10) {
                cardHeader("专注", icon: "timer", tint: focusColor, trailing: "来自手机备份")
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        if h > 0 { bigValue("\(h)", "小时") }
                        bigValue("\(m)", "分钟")
                        if let t = trend(r.focusTotalMin, r.prev?.focusMin) {
                            Text(t.0).font(.caption2.weight(.medium)).foregroundStyle(t.1).padding(.leading, 4)
                        }
                    }
                    Text(fs.sessions > 0 ? "\(fs.sessions) 次 · 平均 \(fs.avgMin) 分 · 最长 \(fs.longestMin) 分" : " ")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Chart(r.focus) { f in
                    BarMark(x: .value("日期", Day.parse(f.day) ?? Date(), unit: .day), y: .value("分钟", f.minutes))
                        .foregroundStyle(focusColor.gradient)
                        .cornerRadius(3)
                }
                .chartXAxis { dayAxis(step: step) }
                .chartYAxis(.hidden)
                .frame(maxHeight: .infinity)
            }
        }
    }

    // MARK: - 完成待办的优先级

    private func priorityCard(_ r: ReviewData) -> some View {
        let names = ["无", "低", "中", "高"]
        let colors: [Color] = [.gray, .blue, .orange, .red]
        let total = max(r.donePriority.reduce(0, +), 1)
        let top = r.donePriority.enumerated().filter { $0.offset > 0 }.max(by: { $0.element < $1.element })
        return InsightCard(height: 250) {
            VStack(alignment: .leading, spacing: 10) {
                cardHeader("完成的待办", icon: "flag.fill", tint: doneColor, trailing: "按优先级")
                VStack(alignment: .leading, spacing: 2) {
                    bigValue("\(r.donePriority[3] + r.donePriority[2])", "个重要待办")
                    Text(top.map { $0.element > 0 ? "其中「\(names[$0.offset])」优先级最多" : "还没有设置优先级的待办" } ?? " ")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Chart(0 ..< 4, id: \.self) { i in
                    BarMark(x: .value("优先级", names[3 - i]), y: .value("个数", r.donePriority[3 - i]))
                        .foregroundStyle(colors[3 - i].gradient)
                        .cornerRadius(4)
                        .annotation(position: .top, spacing: 2) {
                            Text("\(r.donePriority[3 - i])").font(.caption2).foregroundStyle(.secondary)
                        }
                }
                .chartXAxis { AxisMarks { _ in AxisValueLabel().font(.caption2) } }
                .chartYAxis(.hidden)
                .frame(maxHeight: .infinity)
                Text("共完成 \(total) 个").font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - 专注时段

    private func focusHoursCard(_ r: ReviewData) -> some View {
        let start = bestFocusStart(r)
        return InsightCard(height: 250) {
            VStack(alignment: .leading, spacing: 10) {
                cardHeader("专注时段", icon: "scope", tint: focusColor, trailing: "按开始时间")
                VStack(alignment: .leading, spacing: 2) {
                    bigValue(start.map { "\($0)–\($0 + 2) 点" } ?? "–")
                    Text("你最常在这个时段开始专注").font(.callout).foregroundStyle(.secondary)
                }
                Chart(0 ..< 24, id: \.self) { h in
                    BarMark(x: .value("小时", h), y: .value("分钟", r.focusHours[h]), width: .fixed(6))
                        .foregroundStyle(focusColor.gradient)
                }
                .chartXScale(domain: 0 ... 23)
                .chartXAxis {
                    AxisMarks(values: [0, 6, 12, 18]) { v in
                        AxisValueLabel {
                            if let h = v.as(Int.self) { Text("\(h)时").font(.caption2) }
                        }
                    }
                }
                .chartYAxis(.hidden)
                .frame(maxHeight: .infinity)
            }
        }
    }

    // MARK: - AI 洞察

    private func aiCard(_ r: ReviewData) -> some View {
        let ins = model.aiInsights[model.reviewDays]
        let busy = model.aiInsightLoading
        return InsightCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles").foregroundStyle(Brand.orange)
                    Text("读一读你最近 \(r.days) 天写的东西").font(.subheadline.weight(.semibold))
                    Spacer(minLength: 8)
                    if busy { ProgressView().controlSize(.small) }
                    Button { Task { await model.generateAIInsight() } } label: {
                        Label(ins == nil ? "生成洞察" : "重新生成", systemImage: ins == nil ? "wand.and.stars" : "arrow.clockwise")
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                    .disabled(busy || !model.hasLlm)
                }

                if !model.hasLlm {
                    HStack(spacing: 8) {
                        Text("需要先配置 AI 模型").font(.callout).foregroundStyle(.secondary)
                        Button("去设置") { model.section = .settings }.buttonStyle(.link)
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

    // MARK: - 小工具

    private func shortDay(_ s: String) -> String {
        let p = s.split(separator: "-")
        guard p.count == 3, let m = Int(p[1]), let d = Int(p[2]) else { return s }
        return "\(m)/\(d)"
    }

    private func inPeak(_ hour: Int, _ start: Int?) -> Bool {
        guard let s = start else { return false }
        return hour >= s && hour <= s + 2
    }
}

/// 洞察页的卡片：白色圆角底（深色模式下是系统的控件背景色）+ 极淡的描边和阴影。`height` 给了就固定高度（并排的卡片等高）
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
