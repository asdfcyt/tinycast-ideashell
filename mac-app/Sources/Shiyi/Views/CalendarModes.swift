import SwiftUI

/// 日历的四种视图（和系统日历一样：日 / 周 / 月 / 年）
enum CalendarMode: String, CaseIterable, Identifiable {
    case day = "日", week = "周", month = "月", year = "年"
    var id: String { rawValue }
}

// MARK: - 日 / 周：按小时排开的时间格

/// 日视图 = 一列，周视图 = 七列。上面是「全天」（没有具体时间的待办、节假日、笔记数），下面是 24 小时的格子，
/// 有具体时间的待办按时间点落在格子里（同一时段撞车的并排）。双击格子里的空白处（和系统日历一样），在那一天、那个时间（按 15 分钟取整）新建待办：
/// 轴上先出现一块「新建待办」，右侧面板填标题再确认。单击待办在右侧展开详情。拖动待办到别的日子的列里可以改期（保留时间点）。
struct HourGridView: View {
    @EnvironmentObject var model: AppModel
    let days: [String]

    @State private var dropTarget: String?

    private let rowH: CGFloat = 52
    private let gutter: CGFloat = 46
    /// 待办没有时长，画成 45 分钟高的色块
    private let blockMinutes = 45

    var body: some View {
        VStack(spacing: 0) {
            if days.count > 1 {
                dayHeaders
                Divider()
            }
            allDayRow
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    HStack(alignment: .top, spacing: 0) {
                        hourLabels.frame(width: gutter)
                        ForEach(days, id: \.self) { d in
                            column(d)
                            if d != days.last { Divider() }
                        }
                    }
                    .frame(height: rowH * 24)
                }
                .onAppear { proxy.scrollTo(startHour, anchor: .top) }
                .onChange(of: days) { _, _ in proxy.scrollTo(startHour, anchor: .top) }
            }
        }
    }

    private var startHour: Int {
        if days.contains(Day.today()) { return max(Date().hourOfDay - 2, 0) }
        return 7
    }

    // MARK: 头部

    private var dayHeaders: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: gutter, height: 1)
            ForEach(days, id: \.self) { d in
                let isToday = d == Day.today()
                let selected = d == model.calendarDay
                let info = DayInfo.of(d, holiday: model.holidays[d])
                VStack(spacing: 2) {
                    Text(weekdayName(d)).font(.system(size: 11)).foregroundStyle(.secondary)
                    Text("\(Int(d.suffix(2)) ?? 0)")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(isToday ? Color.white : Color.primary)
                        .frame(minWidth: 30, minHeight: 30)
                        .background(isToday ? Color.red : (selected ? Color.accentColor.opacity(0.18) : .clear), in: Circle())
                    Text(info.label).font(.system(size: 10))
                        .foregroundStyle(info.highlight ? Brand.orangeDeep : Color.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
                .onTapGesture { model.selectCalendarDay(d) }
            }
        }
    }

    private func weekdayName(_ d: String) -> String {
        guard let date = Day.parse(d) else { return "" }
        return "周" + ["日", "一", "二", "三", "四", "五", "六"][max(0, Day.cal.component(.weekday, from: date) - 1)]
    }

    private var allDayRow: some View {
        HStack(alignment: .top, spacing: 0) {
            Text("全天").font(.system(size: 10)).foregroundStyle(.secondary)
                .frame(width: gutter, alignment: .trailing).padding(.trailing, 6).padding(.top, 6)
            ForEach(days, id: \.self) { d in
                let allDay = model.calendarTasks(on: d).filter { $0.time == nil }
                let notes = model.calendarNotes[d]?.count ?? 0
                let holiday = model.holidays[d]
                VStack(alignment: .leading, spacing: 2) {
                    if let h = holiday {
                        let tone = Color(red: 0.12, green: 0.55, blue: 0.86)
                        Text(h.name + (h.off ? "（休）" : "（班）"))
                            .font(.system(size: 11)).foregroundStyle(tone).lineLimit(1)
                            .padding(.horizontal, 5).frame(maxWidth: .infinity, alignment: .leading).frame(height: 16)
                            .background(tone.opacity(0.18), in: RoundedRectangle(cornerRadius: 4))
                    }
                    ForEach(allDay.prefix(4)) { t in chip(t) }
                    if allDay.count > 4 {
                        Text("+\(allDay.count - 4)").font(.system(size: 10, weight: .heavy)).foregroundStyle(Brand.orangeDeep)
                    }
                    if notes > 0 {
                        HStack(spacing: 4) {
                            Image(systemName: "triangle.fill").font(.system(size: 7))
                            Text("\(notes) 条笔记").font(.system(size: 11))
                        }
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).frame(height: 16)
                        .padding(.horizontal, 5)
                    }
                }
                .padding(.horizontal, 2).padding(.vertical, 4)
                .frame(maxWidth: .infinity, minHeight: 30, alignment: .topLeading)
                .background(d == model.calendarDay && days.count > 1 ? Color.accentColor.opacity(0.06) : .clear)
            }
        }
    }

    private func chip(_ t: DidaTask) -> some View {
        Text(t.cleanTitle)
            .font(.system(size: 11)).lineLimit(1).strikethrough(t.done)
            .foregroundStyle(t.done ? Color.secondary : Color.primary)
            .padding(.horizontal, 5)
            .frame(maxWidth: .infinity, alignment: .leading).frame(height: 16)
            .background(CalendarPalette.color(t).opacity(t.done ? 0.12 : 0.26), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .modifier(DraggableWhenOpen(task: t))
            .onTapGesture { model.openTask(t) }
    }

    // MARK: 小时格

    private var hourLabels: some View {
        VStack(spacing: 0) {
            ForEach(0 ..< 24, id: \.self) { h in
                Text(h == 0 ? "" : String(format: "%02d:00", h))
                    .font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, 6)
                    .frame(height: rowH, alignment: .top)
                    .offset(y: -6)
                    .id(h)
            }
        }
    }

    private struct Placed: Identifiable {
        let task: DidaTask
        let start: Int
        let lane: Int
        var id: String { task.id }
    }

    private func minutes(_ time: String) -> Int {
        let p = time.split(separator: ":").compactMap { Int($0) }
        return (p.first ?? 0) * 60 + (p.count > 1 ? p[1] : 0)
    }

    /// 同一时段撞车的待办分到不同的车道，并排显示
    private func place(_ tasks: [DidaTask]) -> (placed: [Placed], lanes: Int) {
        var ends: [Int] = []
        var out: [Placed] = []
        for t in tasks.sorted(by: { minutes($0.time ?? "") < minutes($1.time ?? "") }) {
            let s = minutes(t.time ?? "")
            let lane = ends.firstIndex { $0 <= s } ?? ends.count
            if lane == ends.count { ends.append(0) }
            ends[lane] = s + blockMinutes
            out.append(Placed(task: t, start: s, lane: lane))
        }
        return (out, max(ends.count, 1))
    }

    private func column(_ d: String) -> some View {
        let timed = model.calendarTasks(on: d).filter { $0.time != nil }
        let layout = place(timed)
        let selected = d == model.calendarDay && days.count > 1
        return GeometryReader { geo in
            let laneW = geo.size.width / CGFloat(layout.lanes)
            ZStack(alignment: .topLeading) {
                Rectangle().fill(dropTarget == d ? Brand.orange.opacity(0.2) : (selected ? Color.accentColor.opacity(0.06) : .clear))
                // 接收点击的底层：双击新建待办，单击选中这一天（点空白处也会收起右侧的详情）
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(SpatialTapGesture(count: 2).onEnded { v in
                        model.selectCalendarDay(d)
                        let mins = min(max(Int(v.location.y / rowH * 4), 0), 95) * 15
                        model.startCalendarDraft(date: d, minutes: mins)
                    })
                    .simultaneousGesture(TapGesture().onEnded {
                        model.selectCalendarDay(d)
                        model.calPane.clear()
                    })
                ForEach(0 ..< 24, id: \.self) { h in
                    Rectangle().fill(Color.primary.opacity(0.09)).frame(height: 0.5).offset(y: CGFloat(h) * rowH).allowsHitTesting(false)
                }
                if d == Day.today() {
                    let c = Day.cal.dateComponents([.hour, .minute], from: Date())
                    let y = (CGFloat(c.hour ?? 0) + CGFloat(c.minute ?? 0) / 60) * rowH
                    HStack(spacing: 0) {
                        Circle().fill(Color.red).frame(width: 7, height: 7)
                        Rectangle().fill(Color.red).frame(height: 1)
                    }
                    .offset(x: -3, y: y - 3.5)
                    .allowsHitTesting(false)
                }
                ForEach(layout.placed) { p in
                    block(p.task)
                        .frame(width: max(laneW - 3, 10), height: rowH * CGFloat(blockMinutes) / 60 - 2, alignment: .topLeading)
                        .offset(x: CGFloat(p.lane) * laneW + 1, y: CGFloat(p.start) / 60 * rowH + 1)
                }
                // 双击出来的新建草稿（跟随右侧面板里改的时间）
                if let dr = model.calendarDraft, dr.date == d, let t = dr.time {
                    draftBlock(dr, time: t)
                        .frame(width: max(geo.size.width - 4, 10), height: rowH * CGFloat(blockMinutes) / 60 - 2, alignment: .topLeading)
                        .offset(x: 2, y: CGFloat(minutes(t)) / 60 * rowH + 1)
                        .allowsHitTesting(false)
                }
            }
            .dropDestination(for: String.self) { ids, _ in
                guard let id = ids.first else { return false }
                Task { await model.moveTask(id, to: d) }
                return true
            } isTargeted: { over in
                if over { dropTarget = d } else if dropTarget == d { dropTarget = nil }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: rowH * 24)
    }

    /// 新建中的待办：橙色实心块，标题还没写时显示「新建待办」
    private func draftBlock(_ dr: CalendarDraft, time: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(dr.title.trimmed.isEmpty ? "新建待办" : dr.title).font(.system(size: 11, weight: .semibold)).lineLimit(2)
            Text(time).font(.system(size: 10)).monospacedDigit().opacity(0.85)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Brand.orange, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        .shadow(color: Brand.orange.opacity(0.4), radius: 4, y: 1)
    }

    private func block(_ t: DidaTask) -> some View {
        let color = CalendarPalette.color(t)
        return VStack(alignment: .leading, spacing: 0) {
            Text(t.cleanTitle).font(.system(size: 11, weight: .semibold)).lineLimit(2).strikethrough(t.done)
            Text(t.time ?? "").font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
        }
        .padding(.horizontal, 5).padding(.vertical, 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(color.opacity(t.done ? 0.14 : 0.28), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay(alignment: .leading) { Rectangle().fill(color).frame(width: 3).clipShape(RoundedRectangle(cornerRadius: 1.5)) }
        .foregroundStyle(t.done ? Color.secondary : Color.primary)
        .overlay {
            // 在右侧展开了详情的那一块描一圈边
            PaneSelection(pane: model.calPane, match: { $0.isTask(t.id) }) { on in
                RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(color, lineWidth: on ? 2 : 0)
            }
            .allowsHitTesting(false)
        }
        .modifier(DraggableWhenOpen(task: t))
        .onTapGesture { model.openTask(t) }
    }
}

// MARK: - 年视图：十二个月的小日历

struct YearView: View {
    @EnvironmentObject var model: AppModel

    private var year: Int { Day.cal.component(.year, from: model.calendarMonth) }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 18, alignment: .top)], spacing: 22) {
                ForEach(1 ... 12, id: \.self) { m in
                    MiniMonth(year: year, month: m)
                }
            }
            .padding(20)
        }
    }
}

private struct MiniMonth: View {
    @EnvironmentObject var model: AppModel
    let year: Int
    let month: Int

    private var first: Date { Day.cal.date(from: DateComponents(year: year, month: month, day: 1)) ?? Date() }
    private var days: [String] { AppModel.calendarGrid(for: first) }
    private var isCurrentMonth: Bool {
        let c = Day.cal.dateComponents([.year, .month], from: Date())
        return c.year == year && c.month == month
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                model.selectCalendarDay(Day.string(first), mode: .month)
            } label: {
                Text("\(month)月").font(.system(size: 17, weight: .bold)).foregroundStyle(isCurrentMonth ? Color.red : Color.primary)
            }
            .buttonStyle(.plain)

            HStack(spacing: 0) {
                ForEach(["一", "二", "三", "四", "五", "六", "日"], id: \.self) { w in
                    Text(w).font(.system(size: 10)).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                }
            }
            let cells = days
            // 6 周里最后一周整行都不在本月时不画，省一行高度
            let rows = (0 ..< 6).filter { r in (0 ..< 7).contains { inMonth(cells[r * 7 + $0]) } }
            ForEach(rows, id: \.self) { r in
                HStack(spacing: 0) {
                    ForEach(0 ..< 7, id: \.self) { c in
                        cell(cells[r * 7 + c], weekend: c >= 5)
                    }
                }
            }
        }
    }

    private func inMonth(_ d: String) -> Bool { Int(d.dropFirst(5).prefix(2)) == month }

    @ViewBuilder private func cell(_ d: String, weekend: Bool) -> some View {
        if inMonth(d) {
            let isToday = d == Day.today()
            let selected = d == model.calendarDay
            let h = model.holidays[d]
            let color: Color = isToday ? .white : (h?.off == true ? Color.red : (weekend ? Color.primary.opacity(0.55) : Color.primary))
            Text("\(Int(d.suffix(2)) ?? 0)")
                .font(.system(size: 12, weight: isToday ? .bold : .regular)).monospacedDigit()
                .foregroundStyle(color)
                .frame(maxWidth: .infinity, minHeight: 24)
                .background {
                    if isToday { Circle().fill(Color.red).frame(width: 22, height: 22) }
                    else if selected { Circle().stroke(Color.accentColor, lineWidth: 1.5).frame(width: 22, height: 22) }
                }
                .contentShape(Rectangle())
                .onTapGesture { model.selectCalendarDay(d, mode: .day) }
                .help(DayInfo.of(d, holiday: h).detail())
        } else {
            Color.clear.frame(maxWidth: .infinity, minHeight: 24)
        }
    }
}
