import SwiftUI

/// 日历：版式参考系统「日历」的月视图（满铺的格子线、左上农历 / 节日 / 节气、右上日期、法定节假日整条标出），
/// 内容复刻安卓端：格子里按任务画色块（颜色按清单，和安卓端同一套配色），拖到别的日子改期，底部「无日期」托盘，点某一天看当天安排。
struct CalendarView: View {
    @EnvironmentObject var model: AppModel
    @State private var dropTarget: String?

    private let weekdays = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]

    private var selectedDay: String { model.calendarDay }

    private var grid: [String] { AppModel.calendarGrid(for: model.calendarMonth) }

    private var monthTitle: String {
        let cal = Day.cal
        switch model.calendarMode {
        case .year:
            return "\(cal.component(.year, from: model.calendarMonth))年"
        case .day:
            guard let d = Day.parse(model.calendarDay) else { return model.calendarDay }
            let c = cal.dateComponents([.year, .month, .day], from: d)
            return "\(c.year ?? 0)年\(c.month ?? 0)月\(c.day ?? 0)日"
        case .week:
            let w = AppModel.weekDays(of: model.calendarDay)
            guard let a = w.first.flatMap(Day.parse), let b = w.last.flatMap(Day.parse) else { return model.calendarDay }
            let ca = cal.dateComponents([.year, .month, .day], from: a), cb = cal.dateComponents([.year, .month, .day], from: b)
            let head = "\(ca.year ?? 0)年\(ca.month ?? 0)月\(ca.day ?? 0)日"
            return ca.month == cb.month ? "\(head)–\(cb.day ?? 0)日" : "\(head)–\(cb.month ?? 0)月\(cb.day ?? 0)日"
        case .month:
            let c = cal.dateComponents([.year, .month], from: model.calendarMonth)
            return "\(c.year ?? 0)年\(c.month ?? 0)月"
        }
    }

    private func inMonth(_ day: String) -> Bool {
        guard let d = Day.parse(day) else { return false }
        return Day.cal.isDate(d, equalTo: model.calendarMonth, toGranularity: .month)
    }

    var body: some View {
        Group { content }
            // 背景铺在整个窗口（含标题栏）后面，标题栏和页面是同一个底色，不再割裂
            .background(AmbientBackground())
    }

    @ViewBuilder private var content: some View {
        if !model.hasDida && !model.hasIdeashell {
            EmptyHint(icon: "key", title: "先到「设置」填写凭证")
        } else {
            // 不用 HSplitView：窗口缩小时右侧面板不肯收缩，内容就被挤出窗口。右侧面板占 1/3，夹在 280～380 之间。
            GeometryReader { geo in
                let showPanel = model.calendarMode != .year
                let panelW = showPanel ? min(max(geo.size.width / 3, 280), 380) : 0
                HStack(spacing: 0) {
                    monthPane.frame(width: max(geo.size.width - (showPanel ? panelW + 1 : 0), 0))
                    if showPanel {
                        Divider()
                        CalendarSide(pane: model.calPane) { dayPanel }.frame(width: panelW)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .clipped()
            }
            .toolbar {
                // 日 / 周 / 月 / 年 放在标题栏正中间（和系统日历一样）
                // 系统原生分段控件。工具栏里的分段控件按文字撑开宽度、忽略 .frame，所以在文字两边补空格，
                // 让每一段（和选中的那一块）比默认的宽一些（约 52pt）
                ToolbarItem(placement: .principal) {
                    Picker("视图", selection: Binding(get: { model.calendarMode }, set: { model.setCalendarMode($0) })) {
                        ForEach(CalendarMode.allCases) { Text("\u{3000}" + $0.rawValue + "\u{3000}").tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .help("日 / 周 / 月 / 年")
                }
            }
            .task { await model.loadCalendar(ifStale: true) }
            .task { await model.loadHolidays() }
        }
    }

    // MARK: - 月视图

    private var monthPane: some View {
        let byDay = Dictionary(grouping: model.calendarTasks.values) { model.taskDay($0) ?? "" }
            .mapValues { list in
                list.sorted {
                    if $0.done != $1.done { return !$0.done }
                    let a = $0.time ?? "99:99", b = $1.time ?? "99:99"
                    return a != b ? a < b : $0.priority > $1.priority
                }
            }
        let undated = model.overview?.undated ?? []
        return VStack(spacing: 0) {
            header
                .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)

            if let e = model.calendarError {
                ErrorBanner(text: e) { Task { await model.loadCalendar() } }.padding(.horizontal, 16).padding(.bottom, 8)
            }

            switch model.calendarMode {
            case .month: monthGrid(byDay)
            case .week: HourGridView(days: AppModel.weekDays(of: model.calendarDay))
            case .day: HourGridView(days: [model.calendarDay])
            case .year: YearView()
            }

            if !undated.isEmpty && model.calendarMode != .year { undatedTray(undated) }
        }
    }

    private func monthGrid(_ byDay: [String: [DidaTask]]) -> some View {
        VStack(spacing: 0) {
            weekdayRow
            Divider()

            GeometryReader { geo in
                let rowH = max(64, geo.size.height / 6)
                VStack(spacing: 0) {
                    ForEach(0 ..< 6, id: \.self) { row in
                        HStack(spacing: 0) {
                            ForEach(0 ..< 7, id: \.self) { col in
                                let day = grid[row * 7 + col]
                                DayCell(
                                    day: day,
                                    inMonth: inMonth(day),
                                    selected: day == selectedDay,
                                    weekend: col >= 5,
                                    height: rowH,
                                    tasks: byDay[day] ?? [],
                                    noteCount: model.calendarNotes[day]?.count ?? 0,
                                    holiday: model.holidays[day],
                                    holidayPrev: col > 0 ? model.holidays[grid[row * 7 + col - 1]] : nil,
                                    holidayNext: col < 6 ? model.holidays[grid[row * 7 + col + 1]] : nil,
                                    dropping: dropTarget == day
                                )
                                .frame(height: rowH)
                                .onTapGesture { model.selectCalendarDay(day) }
                                .dropDestination(for: String.self) { ids, _ in
                                    guard let id = ids.first else { return false }
                                    Task { await model.moveTask(id, to: day) }
                                    return true
                                } isTargeted: { over in
                                    if over { dropTarget = day } else if dropTarget == day { dropTarget = nil }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                Text(monthTitle).font(.system(size: 26, weight: .bold)).lineLimit(1).minimumScaleFactor(0.6)
                if model.calendarLoading { ProgressView().controlSize(.small) }
                Spacer(minLength: 8)
                HStack(spacing: 2) {
                    Button { model.stepCalendar(-1) } label: { Image(systemName: "chevron.left").frame(width: 24, height: 24) }
                    Button("今天") { model.calendarToday() }
                        .padding(.horizontal, 6)
                    Button { model.stepCalendar(1) } label: { Image(systemName: "chevron.right").frame(width: 24, height: 24) }
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .glassCapsule()
            }
            // 日视图：标题下面一行，左边星期、右边农历（干支年 + 月日）
            if model.calendarMode == .day {
                HStack {
                    Text(fullWeekday(model.calendarDay)).font(.title3).foregroundStyle(.secondary)
                    Spacer()
                    Text(LunarCalendar.yearAndDay(model.calendarDay)).font(.title3).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func fullWeekday(_ day: String) -> String {
        guard let d = Day.parse(day) else { return "" }
        return "星期" + ["日", "一", "二", "三", "四", "五", "六"][max(0, Day.cal.component(.weekday, from: d) - 1)]
    }

    private var weekdayRow: some View {
        HStack(spacing: 0) {
            ForEach(Array(weekdays.enumerated()), id: \.offset) { i, w in
                Text(w)
                    .font(.system(size: 12))
                    .foregroundStyle(i >= 5 ? Color.secondary.opacity(0.7) : Color.primary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, 8)
            }
        }
        .padding(.vertical, 5)
    }

    // MARK: - 无日期托盘（拖拽的起点）

    private func undatedTray(_ tasks: [DidaTask]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("无日期").font(.subheadline.weight(.heavy))
                Text("\(tasks.count)").font(.caption.weight(.bold)).foregroundStyle(Brand.orangeDeep)
                    .padding(.horizontal, 8).padding(.vertical, 1)
                    .background(Brand.orange.opacity(0.18), in: Capsule())
                Spacer()
                Text("拖到日期格子里安排").font(.caption).foregroundStyle(.secondary)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(tasks) { t in
                        HStack(spacing: 6) {
                            Circle().fill(CalendarPalette.color(t)).frame(width: 8, height: 8)
                            Text(t.cleanTitle).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .frame(maxWidth: 190)
                        .background(Color.primary.opacity(0.07), in: Capsule())
                        .draggable(t.id)
                        .onTapGesture { model.openTask(t) }
                    }
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.bar)
    }

    // MARK: - 当天面板

    private var dayPanel: some View {
        let tasks = model.calendarTasks(on: selectedDay)
        let notes = (model.calendarNotes[selectedDay] ?? []).sorted { ($0.createdAt ?? "") < ($1.createdAt ?? "") }
        let info = DayInfo.of(selectedDay, holiday: model.holidays[selectedDay])
        let isToday = selectedDay == Day.today()
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(panelTitle + (isToday ? " · 今天" : "")).font(.title2.bold())
                    Text(info.detail() + (tasks.isEmpty ? "" : " · \(tasks.count) 项"))
                        .font(.callout).foregroundStyle(.secondary)
                }

                Card {
                    VStack(alignment: .leading, spacing: 6) {
                        SectionTitle(text: "待办", count: tasks.count)
                        if !model.hasDida {
                            Text("填写滴答清单 API 口令后显示").foregroundStyle(.tertiary)
                        } else if tasks.isEmpty {
                            Text(model.calendarLoading ? "加载中…" : "这天没有安排").foregroundStyle(.secondary)
                        }
                        ForEach(tasks) { t in
                            TaskRow(task: t, overdue: !t.done && (t.date ?? "") < Day.today(), showProject: false)
                                .modifier(DraggableWhenOpen(task: t))
                        }
                        if tasks.contains(where: { !$0.done }) {
                            Text("拖动任务到日历格子可以改期").font(.caption).foregroundStyle(.tertiary).padding(.top, 2)
                        }
                    }
                }

                Card {
                    VStack(alignment: .leading, spacing: 6) {
                        SectionTitle(text: "笔记", count: notes.count)
                        if !model.hasIdeashell {
                            Text("填写闪念贝壳 API Key 后显示").foregroundStyle(.tertiary)
                        } else if notes.isEmpty {
                            Text(model.calendarLoading ? "加载中…" : "这天没有笔记").foregroundStyle(.secondary)
                        }
                        ForEach(notes) { n in
                            NoteRow(note: n).onTapGesture { model.openNote(n.id, title: n.title) }
                            if n.id != notes.last?.id { Divider() }
                        }
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var panelTitle: String {
        guard let d = Day.parse(selectedDay) else { return selectedDay }
        let c = Day.cal.dateComponents([.month, .day, .weekday], from: d)
        let w = ["日", "一", "二", "三", "四", "五", "六"][max(0, (c.weekday ?? 1) - 1)]
        return "\(c.month ?? 0)月\(c.day ?? 0)日 周\(w)"
    }
}

/// 没做完的任务才能拖
struct DraggableWhenOpen: ViewModifier {
    let task: DidaTask
    func body(content: Content) -> some View {
        if task.done { content } else { content.draggable(task.id) }
    }
}

// MARK: - 配色（和安卓端 `chipColor` 一致：同一个清单的任务颜色一致）

enum CalendarPalette {
    static let colors: [Color] = [
        Color(red: 0xE8 / 255, green: 0x79 / 255, blue: 0x4A / 255), Color(red: 0x3F / 255, green: 0xA3 / 255, blue: 0x7C / 255),
        Color(red: 0x5B / 255, green: 0x8D / 255, blue: 0xEF / 255), Color(red: 0x9B / 255, green: 0x7B / 255, blue: 0xE0 / 255),
        Color(red: 0xE8 / 255, green: 0x6F / 255, blue: 0x9A / 255), Color(red: 0x2F / 255, green: 0xAF / 255, blue: 0xC0 / 255),
        Color(red: 0xD9 / 255, green: 0xA5 / 255, blue: 0x2B / 255), Color(red: 0x8A / 255, green: 0x9A / 255, blue: 0x5B / 255),
    ]

    /// Java `String.hashCode()`，让颜色和安卓端一一对应
    private static func javaHash(_ s: String) -> Int32 {
        var h: Int32 = 0
        for u in s.utf16 { h = h &* 31 &+ Int32(u) }
        return h
    }

    static func color(_ t: DidaTask) -> Color {
        let h = Int(javaHash(t.projectId))
        return colors[((h % colors.count) + colors.count) % colors.count]
    }
}

// MARK: - 一格

private struct DayCell: View {
    let day: String
    let inMonth: Bool
    let selected: Bool
    let weekend: Bool
    let height: CGFloat
    let tasks: [DidaTask]
    let noteCount: Int
    let holiday: HolidayEntry?
    let holidayPrev: HolidayEntry?
    let holidayNext: HolidayEntry?
    let dropping: Bool

    private var isToday: Bool { day == Day.today() }
    private var info: DayInfo { DayInfo.of(day, holiday: holiday) }
    private var dayNum: Int { Int(day.suffix(2)) ?? 0 }
    private var monthNum: Int { Int(day.dropFirst(5).prefix(2)) ?? 0 }

    /// 日期文字：每月 1 号带月份（和系统日历一致）
    private var numberText: String { dayNum == 1 ? "\(monthNum)月1日" : "\(dayNum)日" }

    /// 除了日期行，每格还能放几条（节假日条、任务色块、笔记数各占一行）
    private var capacity: Int { max(Int((height - 30) / 18), 0) }

    private var fade: Double { inMonth ? 1 : 0.45 }

    private struct Item: Identifiable {
        enum Kind { case holiday, task(DidaTask), notes(Int) }
        let id: String
        let kind: Kind
    }

    private var items: [Item] {
        var out: [Item] = []
        if holiday != nil { out.append(Item(id: "h", kind: .holiday)) }
        for t in tasks { out.append(Item(id: t.id, kind: .task(t))) }
        if noteCount > 0 { out.append(Item(id: "n", kind: .notes(noteCount))) }
        return out
    }

    var body: some View {
        let all = items
        let shown = all.count <= capacity ? all : Array(all.prefix(max(capacity - 1, 0)))
        let hidden = all.count - shown.count

        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(info.label)
                    .font(.system(size: 11))
                    .foregroundStyle((info.highlight ? Brand.orangeDeep : Color.secondary).opacity(fade))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(numberText)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(numberColor)
                    .padding(.horizontal, isToday ? 6 : 0)
                    .padding(.vertical, isToday ? 1 : 0)
                    .background(isToday ? Color.red : .clear, in: Capsule())
            }
            .padding(.horizontal, 6)
            .padding(.top, 4)

            ForEach(shown) { item in
                switch item.kind {
                case .holiday: holidayBar
                case let .task(t): chip(t)
                case let .notes(n): notesChip(n)
                }
            }
            if hidden > 0 {
                Text("+\(hidden)")
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundStyle(Brand.orangeDeep.opacity(fade))
                    .padding(.horizontal, 8)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(cellFill)
        .overlay(Rectangle().strokeBorder(Color.primary.opacity(0.09), lineWidth: 0.5).allowsHitTesting(false))
        .overlay {
            if selected {
                Rectangle().strokeBorder(Color.accentColor, lineWidth: 1.5).allowsHitTesting(false)
            }
        }
        .clipped()
        .contentShape(Rectangle())
    }

    private var numberColor: Color {
        if isToday { return .white }
        if weekend { return Color.primary.opacity(0.55 * fade) }
        return Color.primary.opacity(fade)
    }

    private var cellFill: Color {
        if dropping { return Brand.orange.opacity(0.28) }
        if selected { return Color.accentColor.opacity(0.10) }
        if weekend { return Color.primary.opacity(inMonth ? 0.045 : 0.025) }
        return Color.clear
    }

    // 节假日整条标出：同一个假期连续的几天连成一条，只在起点（或每行第一格）写名字
    private var holidayBar: some View {
        let h = holiday!
        let startsHere = holidayPrev != h
        let endsHere = holidayNext != h
        let tone = Color(red: 0.12, green: 0.55, blue: 0.86)
        let label = h.name + (h.off ? "（休）" : "（班）")
        return HStack(spacing: 4) {
            if startsHere {
                Image(systemName: "star.circle.fill").font(.system(size: 11)).foregroundStyle(tone)
                Text(label).font(.system(size: 11)).foregroundStyle(tone.opacity(0.95)).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 3)
        .frame(height: 16)
        .background(
            tone.opacity(0.20 * fade),
            in: UnevenRoundedRectangle(topLeadingRadius: startsHere ? 8 : 0, bottomLeadingRadius: startsHere ? 8 : 0,
                                       bottomTrailingRadius: endsHere ? 8 : 0, topTrailingRadius: endsHere ? 8 : 0)
        )
        .padding(.leading, startsHere ? 4 : 0)
        .padding(.trailing, endsHere ? 4 : 0)
    }

    private func chip(_ t: DidaTask) -> some View {
        Text(t.cleanTitle)
            .font(.system(size: 11))
            .lineLimit(1)
            .strikethrough(t.done)
            .foregroundStyle(t.done ? Color.secondary : Color.primary)
            .padding(.horizontal, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 16)
            .background(CalendarPalette.color(t).opacity((t.done ? 0.12 : 0.26) * fade), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .padding(.horizontal, 4)
            .opacity(fade)
            .modifier(DraggableWhenOpen(task: t))
    }

    private func notesChip(_ n: Int) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "triangle.fill").font(.system(size: 7))
            Text("\(n) 条笔记").font(.system(size: 11))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 16)
        .padding(.horizontal, 4)
        .opacity(fade)
    }
}

// MARK: - 右侧面板：新建草稿 > 选中的任务详情 > 当天概览

private struct CalendarSide<Overview: View>: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var pane: PaneState
    @ViewBuilder var overview: () -> Overview

    var body: some View {
        if model.calendarDraft != nil {
            CalendarDraftPanel()
        } else if pane.page != nil {
            PaneDetailBody(pane: pane)
        } else {
            overview()
        }
    }
}

/// 双击时间轴后右侧的新建表单（参考系统日历的「新建日程」面板）：标题、日期时间、优先级，确认才真正写入滴答
private struct CalendarDraftPanel: View {
    @EnvironmentObject var model: AppModel
    @FocusState private var titleFocused: Bool
    @State private var saving = false

    private var draft: CalendarDraft { model.calendarDraft ?? CalendarDraft(date: Day.today(), time: nil) }

    private func binding<T>(_ kp: WritableKeyPath<CalendarDraft, T>) -> Binding<T> {
        Binding(get: { draft[keyPath: kp] }, set: { v in model.calendarDraft?[keyPath: kp] = v })
    }

    private var dateBinding: Binding<Date> {
        Binding(get: { Day.parse(draft.date) ?? Date() }, set: { model.calendarDraft?.date = Day.string($0) })
    }

    private var timeBinding: Binding<Date> {
        Binding(get: {
            let p = (draft.time ?? "09:00").split(separator: ":").compactMap { Int($0) }
            return Day.cal.date(bySettingHour: p.first ?? 9, minute: p.count > 1 ? p[1] : 0, second: 0, of: Date()) ?? Date()
        }, set: { d in
            let c = Day.cal.dateComponents([.hour, .minute], from: d)
            model.calendarDraft?.time = String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
        })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("新建待办").font(.callout.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Button { model.cancelCalendarDraft() } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless).help("取消（Esc）")
                }

                // 标题：左边一条橙色竖线，和轴上的色块呼应
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 2).fill(Brand.orange).frame(width: 4)
                    TextField("待办标题", text: binding(\.title), axis: .vertical)
                        .textFieldStyle(.plain).font(.title3.weight(.semibold))
                        .lineLimit(1 ... 3)
                        .focused($titleFocused)
                        .onSubmit { commit() }
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .fixedSize(horizontal: false, vertical: true)
                .glassCard(radius: 12)

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Image(systemName: "calendar").foregroundStyle(.secondary).frame(width: 20)
                        DatePicker("", selection: dateBinding, in: (Day.parse(Day.today()) ?? Date())..., displayedComponents: .date)
                            .labelsHidden()
                        Spacer(minLength: 0)
                    }
                    HStack {
                        Image(systemName: "clock").foregroundStyle(.secondary).frame(width: 20)
                        Toggle("具体时间", isOn: Binding(
                            get: { draft.time != nil },
                            set: { model.calendarDraft?.time = $0 ? "09:00" : nil }
                        ))
                        .toggleStyle(.switch).controlSize(.small)
                        Spacer(minLength: 0)
                        if draft.time != nil {
                            DatePicker("", selection: timeBinding, displayedComponents: .hourAndMinute).labelsHidden()
                        }
                    }
                    HStack {
                        Image(systemName: "flag").foregroundStyle(.secondary).frame(width: 20)
                        Picker("", selection: binding(\.priority)) {
                            Text("无").tag(0)
                            Text("低").tag(1)
                            Text("中").tag(3)
                            Text("高").tag(5)
                        }
                        .pickerStyle(.segmented).labelsHidden()
                    }
                }
                .padding(12)
                .glassCard(radius: 12)

                HStack(spacing: 10) {
                    Spacer()
                    Button("取消") { model.cancelCalendarDraft() }
                        .keyboardShortcut(.cancelAction)
                    Button { commit() } label: {
                        if saving { ProgressView().controlSize(.small) } else { Text("添加") }
                    }
                    .buttonStyle(.borderedProminent).tint(Brand.orange)
                    .disabled(saving || draft.title.trimmed.isEmpty)
                }
                Text("在时间轴上双击空白处新建；标题填好后回车即可添加").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { titleFocused = true }
    }

    private func commit() {
        guard !saving else { return }
        saving = true
        Task {
            _ = await model.commitCalendarDraft()
            saving = false
        }
    }
}
