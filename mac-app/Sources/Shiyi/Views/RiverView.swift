import AppKit
import SwiftUI

/// 品牌色（取自安卓端 Theme.kt 的浅色主题）
enum Brand {
    static let orange = Color(red: 0xE8 / 255, green: 0x79 / 255, blue: 0x4A / 255)
    /// 深橙：浅色下是深褐橙；暗色下换成浅一些的橙，不然在深色玻璃 / 深色底上看不清
    static let orangeDeep = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0xF5 / 255, green: 0xA2 / 255, blue: 0x7A / 255, alpha: 1)
            : NSColor(red: 0xA9 / 255, green: 0x44 / 255, blue: 0x1C / 255, alpha: 1)
    })
    static let brown = Color(red: 0x2A / 255, green: 0x21 / 255, blue: 0x18 / 255)
}

/*
 * 时间河（节点时刻表），复刻安卓端 RiverPane：没有卡片外壳，正文直接落在底色上，现在放在日历右侧显示选中的那一天。
 * 这一天的每一件事按时间从晚到早排开：竖线在左、时间居中、正文在右，每条记录是线上的一个节点。
 * Daily Note 里的每一条（`- **时间** 文字`）拆成独立的一行。
 * 节点区分类型：日记 = 橙色实心圆，笔记 = 深色三角，待办 = 方块（空心 = 没做，红色 = 逾期，灰色实心 = 做完）。
 * 待办可以交互：点节点直接勾选完成（再点恢复）。单击一行选中，空格预览，双击弹出完整页面。
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

// MARK: - 一天的行

private enum RiverRows {
    /// 当天的所有行：全天（没有具体时间）的待办排在最上面，其余按时间从晚到早
    static func make(_ day: DayBucket, today: String) -> [RiverRow] {
        var r: [RiverRow] = []
        for (i, e) in day.daily.enumerated() { r.append(.daily(e, noteId: day.dailyNoteId, index: i)) }
        for n in day.notes { r.append(.note(n)) }
        for t in day.todos { r.append(.todo(t, clock: todoClock(t), overdue: isOverdue(t, day: day.date, today: today))) }
        return r.sorted {
            let a = $0.clock.isEmpty, b = $1.clock.isEmpty
            if a != b { return a }
            return $0.clock > $1.clock
        }
    }

    /// 待办的时间：做完的用完成时刻，没做完的用计划时刻
    static func todoClock(_ t: DidaTask) -> String {
        if t.done, let d = t.completedDate {
            let c = Day.cal.dateComponents([.hour, .minute], from: d)
            return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
        }
        return t.time ?? ""
    }

    /// 没做完、计划时刻已经过了：过去的日子里没做完的，或今天里时间已过的（全天的待办要到第二天才算）
    static func isOverdue(_ t: DidaTask, day: String, today: String) -> Bool {
        if t.done { return false }
        if day < today { return true }
        if day != today { return false }
        guard let time = t.time else { return false }
        let c = Day.cal.dateComponents([.hour, .minute], from: Date())
        return time < String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }
}

/// 日历右侧：选中那一天的时间河（节点样式沿用原来的回顾页）。
/// 单击选中，空格弹出预览浮窗，双击弹出完整页面；待办的节点可以直接勾选完成。
struct DayRiverList: View {
    let day: DayBucket

    var body: some View {
        let list = RiverRows.make(day, today: Day.today())
        LazyVStack(alignment: .leading, spacing: 0) {
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

    private var accent: Color { kind == .todoOverdue ? .red : Brand.orange }

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
        PaneSelection(pane: model.calPane, match: { p in noteId.map { p.isNote($0, entry: key) } ?? false }) { selected in
            TimelineRow(
                clock: entry.time, kind: .daily, first: first, last: last,
                selected: selected,
                onClick: noteId.map { id in { model.riverSelect(.note(NoteRef(id: id, fallbackTitle: "Daily Note")), entry: key) } },
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
            Button("使用便签打开") { StickyController.shared.create(text: entry.text) }
            DispatchMenu(model: model) { entry.text }
            if let id = noteId {
                Button("预览") { model.riverPreview(.note(NoteRef(id: id, fallbackTitle: "Daily Note")), entry: key) }
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
        PaneSelection(pane: model.calPane, match: { $0.isNote(note.id) }) { selected in
            TimelineRow(
                clock: note.clock ?? "", kind: .note, first: first, last: last,
                selected: selected,
                onClick: { model.riverSelect(.note(NoteRef(id: note.id, fallbackTitle: note.title))) },
                onDoubleClick: { model.openNote(note.id, title: note.title) }
            ) {
                Text(note.title).font(.system(size: 14, weight: .bold)).lineLimit(2)
                if let s = note.summary?.nonEmpty {
                    Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .contextMenu {
            Button("预览") { model.riverPreview(.note(NoteRef(id: note.id, fallbackTitle: note.title))) }
            Button("弹出") { model.openNote(note.id, title: note.title) }
            Button("使用便签打开") { model.openNoteAsSticky(note.id, title: note.title) }
            DispatchMenu(model: model) { note.text?.trimmed.nonEmpty ?? [note.title, note.summary].compactMap { $0?.trimmed.nonEmpty }.joined(separator: "\n") }
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
        PaneSelection(pane: model.calPane, match: { $0.isTask(task.id) }) { selected in
            TimelineRow(
                clock: clock,
                kind: task.done ? .todoDone : (overdue ? .todoOverdue : .todo),
                first: first, last: last,
                allDay: clock.isEmpty,
                selected: selected,
                onClick: { model.riverSelect(.task(task)) },
                onDoubleClick: { model.present(.task(task)) },
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
            Button("预览") { model.riverPreview(.task(task)) }
            TaskContextMenu(task: task)
        }
    }
}
