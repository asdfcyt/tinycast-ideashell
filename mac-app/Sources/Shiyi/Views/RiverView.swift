import SwiftUI

/// 品牌色（取自安卓端 Theme.kt 的浅色主题）
enum Brand {
    static let orange = Color(red: 0xE8 / 255, green: 0x79 / 255, blue: 0x4A / 255)
    static let orangeDeep = Color(red: 0xA9 / 255, green: 0x44 / 255, blue: 0x1C / 255)
    static let brown = Color(red: 0x2A / 255, green: 0x21 / 255, blue: 0x18 / 255)
}

/*
 * 回顾的「河」（节点时刻表），复刻安卓端 RiverPane：没有卡片外壳，正文直接落在底色上。
 * 每天一个大号日期头，下面是这一天的每一件事，按时间从晚到早排开：竖线在左、时间居中、正文在右，每条记录是线上的一个节点。
 * Daily Note 里的每一条（`- **时间** 文字`）拆成独立的一行。
 * 节点区分类型：日记 = 橙色实心圆，笔记 = 深色三角，待办 = 方块（空心 = 没做，红色 = 逾期，灰色实心 = 做完）。
 * 默认只展开今天、昨天，更早的收起成一行日期头，点日期头展开 / 收起。待办可以交互：点节点直接勾选完成（再点恢复），点文字打开任务详情。
 */

private enum RiverKind { case daily, note, todo, todoDone, todoOverdue }

private enum RiverRow: Identifiable {
    case daily(DailyEntry, noteId: String?, index: Int)
    case note(NoteInfo)
    case todo(DidaTask, clock: String, overdue: Bool)

    var id: String {
        switch self {
        case let .daily(e, _, i): return "d\(i)-\(e.time)"
        case let .note(n): return "n" + n.id
        case let .todo(t, _, _): return "t" + t.id
        }
    }

    /// HH:mm；没有时间的待办是空字符串，排在最前
    var clock: String {
        switch self {
        case let .daily(e, _, _): return e.time
        case let .note(n): return n.clock ?? ""
        case let .todo(_, c, _): return c
        }
    }
}

struct RiverView: View {
    @EnvironmentObject var model: AppModel
    let data: TimelineData

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 6) {
            ForEach(data.days) { DaySection(day: $0, today: Day.today()) }
        }
    }
}

// MARK: - 一天

private struct DaySection: View {
    @EnvironmentObject var model: AppModel
    let day: DayBucket
    let today: String

    private var open: Bool { model.isRiverDayOpen(day.date) }
    private var isToday: Bool { day.date == today }

    private static let weekdayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "EEE"
        return f
    }()

    private var dayNumber: String { String(Int(day.date.suffix(2)) ?? 0) }

    private var weekday: String {
        guard let d = Day.parse(day.date) else { return "" }
        let w = Self.weekdayFormatter.string(from: d)
        // 不是本月的日子带上月份，免得只看到一个「6」不知道是哪个月
        let c = Day.cal
        guard let t = Day.parse(today) else { return w }
        if !c.isDate(d, equalTo: t, toGranularity: .month) { return "\(c.component(.month, from: d))月 \(w)" }
        return w
    }

    private var counts: String {
        var parts: [String] = []
        if !day.daily.isEmpty { parts.append("\(day.daily.count) 日记") }
        if !day.notes.isEmpty { parts.append("\(day.notes.count) 笔记") }
        if !day.todos.isEmpty { parts.append("\(day.todos.filter(\.done).count)/\(day.todos.count) 待办") }
        return parts.joined(separator: " · ")
    }

    private var rows: [RiverRow] {
        var r: [RiverRow] = []
        for (i, e) in day.daily.enumerated() { r.append(.daily(e, noteId: day.dailyNoteId, index: i)) }
        for n in day.notes { r.append(.note(n)) }
        for t in day.todos { r.append(.todo(t, clock: todoClock(t), overdue: isOverdue(t))) }
        // 全天（没有具体时间）的待办排在当天最上面，其余按时间从晚到早
        return r.sorted {
            let a = $0.clock.isEmpty, b = $1.clock.isEmpty
            if a != b { return a }
            return $0.clock > $1.clock
        }
    }

    /// 待办的时间：做完的用完成时刻，没做完的用计划时刻
    private func todoClock(_ t: DidaTask) -> String {
        if t.done, let d = t.completedDate {
            let c = Day.cal.dateComponents([.hour, .minute], from: d)
            return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
        }
        return t.time ?? ""
    }

    /// 没做完、计划时刻已经过了：过去的日子里没做完的，或今天里时间已过的（全天的待办要到第二天才算）
    private func isOverdue(_ t: DidaTask) -> Bool {
        if t.done { return false }
        if day.date < today { return true }
        if day.date != today { return false }
        guard let time = t.time else { return false }
        let c = Day.cal.dateComponents([.hour, .minute], from: Date())
        return time < String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { model.toggleRiverDay(day.date) }
            } label: {
                HStack(spacing: 8) {
                    Text(dayNumber).font(.system(size: 28, weight: .black)).monospacedDigit()
                    Text(weekday).font(.subheadline.weight(.heavy))
                    if isToday {
                        Text("今天")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(Brand.brown)
                            .padding(.horizontal, 8).padding(.vertical, 2)
                            .background(Brand.orange, in: Capsule())
                    }
                    Spacer(minLength: 8)
                    Text(counts).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Image(systemName: open ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .frame(height: 40)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if open {
                let list = rows
                ForEach(Array(list.enumerated()), id: \.element.id) { i, row in
                    switch row {
                    case let .daily(e, noteId, idx):
                        DailyLine(entry: e, date: day.date, noteId: noteId, index: idx, first: i == 0, last: i == list.count - 1)
                    case let .note(n):
                        NoteLine(note: n, first: i == 0, last: i == list.count - 1)
                    case let .todo(t, clock, overdue):
                        TodoLine(task: t, clock: clock, overdue: overdue, first: i == 0, last: i == list.count - 1)
                    }
                }
            }
        }
        .padding(.bottom, 6)
    }
}

// MARK: - 一行 = 时间 + 竖线上的节点 + 正文

private let clockX: CGFloat = 26
private let clockW: CGFloat = 40
private let railX: CGFloat = 9
private let nodeY: CGFloat = 19

private struct TimelineRow<Content: View>: View {
    let clock: String
    let kind: RiverKind
    let first: Bool
    let last: Bool
    var allDay = false
    var selected = false
    var onClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    var onNodeClick: (() -> Void)?
    @ViewBuilder var content: () -> Content

    @State private var hovering = false

    private var accent: Color { kind == .todoOverdue ? .red : Color.accentColor }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Color.clear.frame(width: clockX)
            Group {
                if allDay {
                    Text("全天")
                        .font(.system(size: 10, weight: .black))
                        .foregroundStyle(accent)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                } else {
                    Text(clock)
                        .font(.system(size: 12, weight: .black))
                        .monospacedDigit()
                        .foregroundStyle(accent)
                }
            }
            .frame(width: clockW, alignment: .leading)
            .padding(.top, 3)
            Spacer().frame(width: 8)
            VStack(alignment: .leading, spacing: 2, content: content)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? Brand.orange.opacity(0.14) : (hovering && onClick != nil ? Color.primary.opacity(0.05) : .clear))
        }
        .background(alignment: .topLeading) { rail }
        .overlay(alignment: .topLeading) {
            if let onNodeClick {
                // 节点本身只有 12pt，点按区域放大到 24 × 36
                Color.clear
                    .frame(width: clockX - 2, height: 36)
                    .contentShape(Circle())
                    .offset(y: nodeY - 18)
                    .onTapGesture(perform: onNodeClick)
                    .help(kind == .todoDone ? "点一下恢复为未完成" : "点一下完成")
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onClick?() }
        .simultaneousGesture(TapGesture(count: 2).onEnded { onDoubleClick?() })
        .onHover { hovering = $0 }
    }

    /// 竖线在每一行里各画一段，行与行之间连成一条；节点周围留出空隙，所以空心方块里不会透出线
    private var rail: some View {
        Canvas { ctx, size in
            let x = railX, gap: CGFloat = 9
            var line = Path()
            if !first { line.move(to: CGPoint(x: x, y: 0)); line.addLine(to: CGPoint(x: x, y: nodeY - gap)) }
            if !last { line.move(to: CGPoint(x: x, y: nodeY + gap)); line.addLine(to: CGPoint(x: x, y: size.height)) }
            ctx.stroke(line, with: .color(Color.primary.opacity(0.14)), lineWidth: 2)

            let ink = Color.primary
            switch kind {
            case .daily:
                ctx.fill(Path(ellipseIn: CGRect(x: x - 6, y: nodeY - 6, width: 12, height: 12)), with: .color(Brand.orange))
            case .note:
                let r: CGFloat = 4.8
                var tri = Path()
                tri.move(to: CGPoint(x: x, y: nodeY - r))
                tri.addLine(to: CGPoint(x: x + r, y: nodeY + r * 0.8))
                tri.addLine(to: CGPoint(x: x - r, y: nodeY + r * 0.8))
                tri.closeSubpath()
                ctx.fill(tri, with: .color(ink))
                ctx.stroke(tri, with: .color(ink), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
            case .todo, .todoOverdue:
                let rect = CGRect(x: x - 4.75, y: nodeY - 4.75, width: 9.5, height: 9.5)
                ctx.stroke(Path(roundedRect: rect, cornerRadius: 2), with: .color(kind == .todoOverdue ? Color.red : ink), lineWidth: 2.5)
            case .todoDone:
                let rect = CGRect(x: x - 5.5, y: nodeY - 5.5, width: 11, height: 11)
                ctx.fill(Path(roundedRect: rect, cornerRadius: 2.5), with: .color(Color.secondary))
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - 三种行

private struct DailyLine: View {
    @EnvironmentObject var model: AppModel
    let entry: DailyEntry
    let date: String
    let noteId: String?
    let index: Int
    let first: Bool
    let last: Bool

    var body: some View {
        let key = "\(index)-\(entry.time)"
        PaneSelection(pane: model.pane, match: { p in noteId.map { p.isNote($0, entry: key) } ?? false }) { selected in
            TimelineRow(
                clock: entry.time, kind: .daily, first: first, last: last,
                selected: selected,
                onClick: noteId.map { id in { model.paneNote(id, title: "Daily Note", entry: key) } },
                onDoubleClick: noteId.map { id in { model.openNote(id, title: "Daily Note") } }
            ) {
                Text(entry.text)
                    .font(.system(size: 14, weight: .semibold))
                    .strikethrough(entry.struck)
                    .lineLimit(3)
                    .textSelection(.disabled)
            }
        }
        .contextMenu {
            Button("复制这条") { model.copy(entry.text) }
            Button("新建笔记…") { model.newNoteDraft = NewNoteDraft(title: entry.text) }
                .disabled(!model.hasIdeashell)
            if let id = noteId {
                Button("在右侧查看") { model.paneNote(id, title: "Daily Note", entry: key) }
                Button("弹出这天的 Daily Note") { model.openNote(id, title: "Daily Note") }
                Button("在闪念贝壳中打开") { model.open(noteURL(id)) }
            }
            Divider()
            Button("删除这条日记…", role: .destructive) { model.requestDelete(.daily(date: date, entry: entry, noteId: noteId)) }
        }
    }
}

private struct NoteLine: View {
    @EnvironmentObject var model: AppModel
    let note: NoteInfo
    let first: Bool
    let last: Bool

    var body: some View {
        PaneSelection(pane: model.pane, match: { $0.isNote(note.id) }) { selected in
            TimelineRow(
                clock: note.clock ?? "", kind: .note, first: first, last: last,
                selected: selected,
                onClick: { model.paneNote(note.id, title: note.title) },
                onDoubleClick: { model.openNote(note.id, title: note.title) }
            ) {
                Text(note.title).font(.system(size: 14, weight: .bold)).lineLimit(2)
                if let s = note.summary?.nonEmpty {
                    Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .contextMenu {
            Button("在右侧查看") { model.paneNote(note.id, title: note.title) }
            Button("弹出") { model.openNote(note.id, title: note.title) }
            Button("在闪念贝壳中打开") { model.open(noteURL(note.id)) }
            Button("复制标题") { model.copy(note.title) }
        }
    }
}

private struct TodoLine: View {
    @EnvironmentObject var model: AppModel
    let task: DidaTask
    let clock: String
    let overdue: Bool
    let first: Bool
    let last: Bool

    var body: some View {
        PaneSelection(pane: model.pane, match: { $0.isTask(task.id) }) { selected in
            TimelineRow(
                clock: clock,
                kind: task.done ? .todoDone : (overdue ? .todoOverdue : .todo),
                first: first, last: last,
                allDay: clock.isEmpty,
                selected: selected,
                onClick: { model.paneTask(task) },
                onDoubleClick: { model.openTask(task) },
                onNodeClick: { Task { await model.toggleTask(task) } }
            ) {
                Text(task.cleanTitle)
                    .font(.system(size: 14, weight: .semibold))
                    .strikethrough(task.done)
                    .foregroundStyle(task.done ? Color.secondary : Color.primary)
                    .lineLimit(2)
                if overdue {
                    Text("已逾期").font(.system(size: 10, weight: .bold)).foregroundStyle(.red)
                }
            }
        }
        .contextMenu {
            Button("在右侧查看") { model.paneTask(task) }
            TaskContextMenu(task: task)
        }
    }
}
