import Charts
import SwiftUI

// MARK: - 通用

/// 项目页每个组件的标题行：图标 + 标题 + 数量 + 右侧的操作按钮
private struct HomeHeader: View {
    let icon: String
    let tint: Color
    let title: String
    var count: Int?
    var action: String?
    var actionIcon: String?
    var disabled = false
    var onAction: () -> Void = {}

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(tint)
                .frame(width: 26, height: 26)
                .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            Text(title).font(.headline)
            if let count, count > 0 {
                Text("\(count)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .padding(.horizontal, 7).padding(.vertical, 1.5)
                    .background(Color.primary.opacity(0.07), in: Capsule())
            }
            Spacer(minLength: 8)
            if let action {
                Button(action: onAction) {
                    if let actionIcon { Label(action, systemImage: actionIcon) } else { Text(action) }
                }
                .buttonStyle(.bordered).controlSize(.small).disabled(disabled)
            }
        }
    }
}

private struct HomeHint: View {
    let text: String
    var body: some View {
        Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

/// 展开 / 收起的小文字按钮
private struct MoreButton: View {
    let text: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(text).font(.callout.weight(.medium))
        }
        .buttonStyle(.plain).foregroundStyle(Brand.orangeDeep)
    }
}

// MARK: - 项目概览（状态 + 目标 + 交付成果合成一张卡）

/// 一张卡讲清楚三件事：做到哪了（进度环 / 势头 / 专注）、要去哪（目标）、要交付什么
struct ProjectOverviewCard: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var home: ProjectHomeStore
    let project: Project
    let mentions: [NoteInfo]
    let taskNotes: [(key: String, ref: TaskNoteRef)]
    let creating: Bool
    let onCreate: () -> Void
    let onEdit: (HomeEdit) -> Void

    private var ws: Workspace { model.backup?.workspace ?? Workspace() }
    private var doneIds: Set<String> { Set((model.overview?.done ?? []).map(\.id)) }

    /// 已交付：任务笔记已归档，或对应的滴答任务已完成
    private var delivered: Int {
        taskNotes.filter { n in
            if n.ref.archived == true { return true }
            return n.key.hasPrefix("dida:") && doneIds.contains(String(n.key.dropFirst(5)))
        }.count
    }

    private var total: Int { taskNotes.count }
    private var active: Int { total - delivered }
    private var progress: Double? { total == 0 ? nil : Double(delivered) / Double(total) }

    private var logs: [FocusLogEntry] { ws.focusLog.filter { $0.project.lowercased() == project.keyword.lowercased() } }

    /// 有动静的日子：提及了这个项目的笔记那天，或有过专注那天
    private var activeDays: Set<String> {
        Set(mentions.compactMap(\.day)).union(logs.map { Day.string($0.startDate) })
    }

    private var windows: (cur: Int, prev: Int) {
        let today = Day.today()
        var cur = 0, prev = 0
        for d in activeDays {
            let ago = Day.diff(d, today)
            if (0 ... 6).contains(ago) { cur += 1 } else if (7 ... 13).contains(ago) { prev += 1 }
        }
        return (cur, prev)
    }

    private var trend: (label: String, arrow: String, tint: Color) {
        let w = windows
        if w.cur == 0 && w.prev == 0 { return ("停滞", "pause.circle.fill", .gray) }
        if w.cur > w.prev { return ("加速", "arrow.up.right.circle.fill", .green) }
        if w.cur == w.prev { return ("平稳", "equal.circle.fill", .blue) }
        return ("放缓", "arrow.down.right.circle.fill", .orange)
    }

    private var daily14: [(day: String, minutes: Int)] {
        let today = Day.today()
        var by: [String: Int] = [:]
        for l in logs { by[Day.string(l.startDate), default: 0] += l.minutes }
        return (0 ..< 14).map { i in
            let d = Day.add(today, days: i - 13)
            return (d, by[d] ?? 0)
        }
    }

    private var weekFocus: Int { daily14.suffix(7).reduce(0) { $0 + $1.minutes } }
    private var hasHome: Bool { model.homeOf(project.keyword) != nil }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .center, spacing: 24) {
                    ring
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(alignment: .top, spacing: 0) {
                            metric(total == 0 ? "—" : "\(delivered)/\(total)", "已交付成果", total == 0 ? "还没有任务笔记" : "进行中 \(active)")
                            metricDivider
                            trendMetric
                            metricDivider
                            metric(weekFocus > 0 ? Self.compact(weekFocus) : "—", "近 7 天专注", weekFocus > 0 ? "共 \(logs.filter { Day.diff(Day.string($0.startDate), Day.today()) <= 6 }.count) 次" : "没有记录")
                        }
                        sparkline
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if active > 3 {
                    Label("同时推进 \(active) 个成果，同时做太多会拖慢交付，建议先收尾几个。", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(.orange)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }

                goals
            }
        }
    }

    // MARK: 目标 / 交付成果

    @ViewBuilder private var goals: some View {
        if !hasHome {
            HStack(spacing: 12) {
                Image(systemName: "house.and.flag").font(.system(size: 20)).foregroundStyle(Brand.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("创建项目主页笔记").font(.callout.weight(.semibold))
                    Text("目标、交付成果、里程碑、复盘、资料都记在这里，并同步到手机端。")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button(action: onCreate) {
                    if creating { ProgressView().controlSize(.small) } else { Text("创建") }
                }
                .buttonStyle(.borderedProminent).tint(Brand.orange).disabled(creating)
            }
            .padding(12)
            .background(Brand.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else if home.text == nil, let e = home.error {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                Text(e).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                Spacer(minLength: 8)
                Button("重试") { if let m = model as AppModel? { Task { await home.load(model: m, project: project) } } }
                    .buttonStyle(.bordered).controlSize(.small)
            }
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) { goalTile; deliverTile }.frame(minWidth: 480)
                VStack(spacing: 12) { goalTile; deliverTile }
            }
            // 还在读的时候先摆出空的卡片，读到了再填
            .opacity(home.text == nil ? 0.55 : 1)
            .overlay(alignment: .topTrailing) {
                if home.text == nil { ProgressView().controlSize(.small).padding(10) }
            }
        }
    }

    private var goalTile: some View {
        tile("scope", .red, "目标", HomeSection.goal, "这个项目最终要达成什么？")
    }

    private var deliverTile: some View {
        tile("shippingbox.fill", .blue, "交付成果", HomeSection.deliver, "要交付的是成果，而不是要做的事")
    }

    private func tile(_ icon: String, _ tint: Color, _ title: String, _ section: String, _ hint: String) -> some View {
        let shown = HomeParse.withoutPlaceholder(home.body(section))
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 11, weight: .bold)).foregroundStyle(tint)
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(tint)
                Spacer(minLength: 0)
                Image(systemName: "square.and.pencil").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            if shown.isEmpty {
                Text(hint).font(.callout).foregroundStyle(.tertiary)
            } else {
                MarkdownView(text: shown).font(.callout)
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, minHeight: 74, alignment: .topLeading)
        .background(tint.opacity(0.07), in: shape)
        .overlay(shape.strokeBorder(tint.opacity(0.14), lineWidth: 0.8))
        .contentShape(shape)
        .onTapGesture { onEdit(HomeEdit(section: section, title: title, label: title, hint: hint, initial: shown, mode: .replace)) }
        .help("点一下编辑")
    }

    // MARK: 进度环 / 事实行 / 迷你图

    private var ring: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.08), lineWidth: 9)
            if let p = progress {
                Circle().trim(from: 0, to: max(p, 0.015))
                    .stroke(AngularGradient(colors: [Brand.orange.opacity(0.65), Brand.orange], center: .center,
                                            startAngle: .degrees(0), endAngle: .degrees(360 * max(p, 0.015))),
                            style: StrokeStyle(lineWidth: 9, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            VStack(spacing: 0) {
                Text(progress.map { "\(Int(($0 * 100).rounded()))%" } ?? "—")
                    .font(.system(size: 23, weight: .bold, design: .rounded)).monospacedDigit()
                Text("交付进度").font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .frame(width: 104, height: 104)
        .animation(.easeOut(duration: 0.5), value: progress)
        .help(total == 0 ? "项目里还没有任务笔记：每个任务笔记算一个要交付的成果" : "已交付 \(delivered) / 共 \(total) 个成果（每个任务笔记算一个成果）")
    }

    private var sparkline: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("近 14 天专注").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("今天").font(.caption).foregroundStyle(.tertiary)
            }
            Chart(daily14, id: \.day) { d in
                BarMark(x: .value("日期", d.day), y: .value("分钟", max(d.minutes, 4)), width: .ratio(0.62))
                    .foregroundStyle(d.minutes == 0 ? Color.primary.opacity(0.1) : (d.day == Day.today() ? Brand.orange : Brand.orange.opacity(0.55)))
                    .cornerRadius(3)
            }
            .chartXAxis(.hidden).chartYAxis(.hidden)
            .frame(height: 38)
        }
    }

    private func metric(_ value: String, _ label: String, _ note: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 21, weight: .semibold, design: .rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(note).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var trendMetric: some View {
        let t = trend
        return VStack(alignment: .leading, spacing: 2) {
            Label(t.label, systemImage: t.arrow)
                .font(.system(size: 21, weight: .semibold, design: .rounded)).foregroundStyle(t.tint).lineLimit(1)
            Text("近期势头").font(.caption).foregroundStyle(.secondary)
            Text("近 7 天活跃 \(windows.cur) 天 · 前 7 天 \(windows.prev) 天").font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var metricDivider: some View {
        Rectangle().fill(Color.primary.opacity(0.1)).frame(width: 1, height: 44).padding(.horizontal, 14)
    }

    /// 紧凑的时长：1小时17分 / 45分
    private static func compact(_ m: Int) -> String {
        let h = m / 60, r = m % 60
        if h == 0 { return "\(r)分" }
        return r == 0 ? "\(h)小时" : "\(h)小时\(r)分"
    }
}

// MARK: - 里程碑（时间线）/ 复盘 / 资料

struct ProjectHomeBottom: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var home: ProjectHomeStore
    let project: Project
    let onEdit: (HomeEdit) -> Void

    @State private var milestonesExpanded = false
    @State private var reviewsExpanded = false
    private let milestonePreview = 4
    private let reviewPreview = 3

    var body: some View {
        if model.homeOf(project.keyword) != nil, home.text != nil {
            milestoneCard
            // 宽的时候复盘和资料并排，窄了上下排
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    reviewCard.frame(maxWidth: .infinity)
                    linksCard.frame(width: 250)
                }
                .frame(minWidth: 560)
                VStack(spacing: 16) { reviewCard; linksCard }
            }
        }
    }

    // 里程碑与进展：时间线，最新在上；完成的成果是橙色对勾节点，单句记录是小圆点
    private var milestoneCard: some View {
        let entries = HomeParse.milestones(HomeParse.items(home.body(HomeSection.milestone)))
        let shown = milestonesExpanded ? entries : Array(entries.prefix(milestonePreview))
        return Card {
            VStack(alignment: .leading, spacing: 12) {
                HomeHeader(icon: "flag.checkered", tint: Brand.orange, title: "里程碑与进展", count: entries.count, action: "记一条", actionIcon: "plus") {
                    onEdit(HomeEdit(section: HomeSection.milestone, title: "记一条进展 · " + project.keyword, label: "进展",
                                    hint: "会自动带上当前时间，写进笔记的「里程碑与进展」。", initial: "", mode: .milestone))
                }
                if entries.isEmpty { HomeHint(text: "还没有里程碑。任务完成后，任务笔记的复盘总结会汇到这里。") }
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { i, e in
                        let last = i == shown.count - 1
                        switch e {
                        case let .done(d): TimelineRow(done: true, last: last) { MilestoneDoneRow(d: d) }
                        case let .note(stamp, text): TimelineRow(done: false, last: last) { MilestoneNoteRow(stamp: stamp, text: text) }
                        }
                    }
                }
                if entries.count > milestonePreview {
                    MoreButton(text: milestonesExpanded ? "收起" : "还有 \(entries.count - milestonePreview) 项 ›") {
                        withAnimation(.snappy(duration: 0.2)) { milestonesExpanded.toggle() }
                    }
                }
            }
        }
    }

    // 复盘与经验：最新在上
    private var reviewCard: some View {
        let all = Array(HomeParse.paragraphs(home.body(HomeSection.review)).reversed())
        let shown = reviewsExpanded ? all : Array(all.prefix(reviewPreview))
        return Card {
            VStack(alignment: .leading, spacing: 12) {
                HomeHeader(icon: "lightbulb.fill", tint: .yellow, title: "复盘与经验", count: all.count, action: "写复盘", actionIcon: "square.and.pencil") {
                    onEdit(HomeEdit(section: HomeSection.review, title: "写复盘 · " + project.keyword, label: "复盘",
                                    hint: "做得好的、踩过的坑、下次怎么做。会自动带上当前时间。", initial: "", mode: .review))
                }
                if all.isEmpty { HomeHint(text: "项目告一段落，或者踩了坑，就在这里记一笔。") }
                ForEach(Array(shown.enumerated()), id: \.offset) { i, p in
                    if i > 0 { Divider().opacity(0.6) }
                    ReviewBlock(para: p)
                }
                if all.count > reviewPreview {
                    MoreButton(text: reviewsExpanded ? "收起" : "还有 \(all.count - reviewPreview) 段 ›") {
                        withAnimation(.snappy(duration: 0.2)) { reviewsExpanded.toggle() }
                    }
                }
            }
        }
    }

    // 资料与链接：链接可点开
    private var linksCard: some View {
        let all = HomeParse.items(home.body(HomeSection.links))
        return Card {
            VStack(alignment: .leading, spacing: 8) {
                HomeHeader(icon: "link", tint: .blue, title: "资料", count: all.count, action: "添加", actionIcon: "plus") {
                    onEdit(HomeEdit(section: HomeSection.links, title: "添加资料 · " + project.keyword, label: "链接或说明",
                                    hint: "一行一条；链接可以写成 [名称](网址)。", initial: "", mode: .link))
                }
                if all.isEmpty { HomeHint(text: "把资料、链接贴在这里。") }
                ForEach(Array(all.enumerated()), id: \.offset) { _, line in LinkRow(line: line) }
            }
        }
    }
}

/// 时间线的一行：左边是节点 + 向下的连线，右边是内容
private struct TimelineRow<Content: View>: View {
    let done: Bool
    let last: Bool
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 4) {
                if done {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .heavy)).foregroundStyle(Brand.brown)
                        .frame(width: 22, height: 22).background(Brand.orange, in: Circle())
                } else {
                    Circle().fill(Brand.orange.opacity(0.45)).frame(width: 8, height: 8)
                        .frame(width: 22, height: 22)
                }
                if !last {
                    Capsule().fill(Color.primary.opacity(0.1)).frame(width: 2).frame(maxHeight: .infinity)
                }
            }
            .frame(width: 22)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, last ? 0 : 16)
        }
    }
}

// MARK: - 行

@MainActor private func openHomeLink(_ url: String, _ model: AppModel) {
    if let id = HomeParse.noteId(inUrl: url) { model.openNote(id) }
    else if let u = URL(string: url) { model.open(u) }
}

/// 一个完成的成果：对勾 + 成果名 + 完成日期，下面是复盘总结（点一下展开 / 收起），再下面是折叠的过程记录
private struct MilestoneDoneRow: View {
    @EnvironmentObject var model: AppModel
    let d: MilestoneEntry.Done
    @State private var open = false
    @State private var showProcess = false

    private var summary: String { d.review.joined(separator: "\n") }
    private var expandable: Bool { summary.count > 70 || d.review.count > 1 || !d.process.isEmpty }

    var body: some View {
        Group {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Text(HomeParse.plain(d.title)).font(.body.weight(.semibold)).lineLimit(open ? nil : 2)
                    Spacer(minLength: 8)
                    Text(HomeParse.shortStamp(d.stamp).components(separatedBy: " ").first ?? "")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary).monospacedDigit()
                }
                if summary.isEmpty {
                    Text("还没有复盘总结").font(.caption).foregroundStyle(.tertiary)
                } else {
                    Text(summary).font(.callout).foregroundStyle(.secondary).lineLimit(open ? nil : 3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if open {
                    if !d.process.isEmpty {
                        MoreButton(text: showProcess ? "收起过程记录" : "过程记录 \(d.process.count) 条 ›") { showProcess.toggle() }
                        if showProcess {
                            ForEach(Array(d.process.enumerated()), id: \.offset) { _, p in
                                Text((p.stamp.isEmpty ? "" : HomeParse.shortStamp(p.stamp) + "  ") + HomeParse.plain(p.text))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if let u = d.url { MoreButton(text: "查看任务笔记 ›") { openHomeLink(u, model) } }
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if expandable { withAnimation(.snappy(duration: 0.2)) { open.toggle() } } }
    }
}

/// 一句单独的记录：日期在前、文字接在后面
private struct MilestoneNoteRow: View {
    let stamp: String
    let text: String
    @State private var open = false

    var body: some View {
        let long = text.count > 90
        VStack(alignment: .leading, spacing: 3) {
            (Text(stamp.isEmpty ? "" : HomeParse.shortStamp(stamp) + "  ").font(.caption.weight(.heavy)).foregroundColor(Brand.orangeDeep)
                + Text(HomeParse.plain(text)).font(.callout))
                .lineLimit(open || !long ? nil : 3)
                .fixedSize(horizontal: false, vertical: true)
            if long { Text(open ? "收起" : "展开").font(.caption.weight(.medium)).foregroundStyle(Brand.orangeDeep) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { if long { withAnimation(.snappy(duration: 0.2)) { open.toggle() } } }
    }
}

private struct ReviewBlock: View {
    let para: String
    @State private var open = false
    private static let stamped = RX(#"^(\d{4})-(\d{2}-\d{2})(?: (\d{2}:\d{2}))?[\s：:]*([\s\S]*)$"#, multiline: false)

    var body: some View {
        let m = Self.stamped.first(in: para)
        let bodyText = m.map { $0.group(4).isEmpty ? para : $0.group(4) } ?? para
        let long = bodyText.count > 120 || bodyText.filter { $0 == "\n" }.count >= 3
        VStack(alignment: .leading, spacing: 4) {
            if let m {
                Text(HomeParse.stampOf(m)).font(.caption.weight(.heavy)).foregroundStyle(Brand.orangeDeep).monospacedDigit()
            }
            if long && !open {
                Text(HomeParse.plain(bodyText).replacingOccurrences(of: "\n", with: " "))
                    .font(.callout).lineLimit(3).fixedSize(horizontal: false, vertical: true)
            } else {
                MarkdownView(text: bodyText)
            }
            if long { Text(open ? "收起" : "展开").font(.caption.weight(.medium)).foregroundStyle(Brand.orangeDeep) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { if long { withAnimation(.snappy(duration: 0.2)) { open.toggle() } } }
    }
}

private struct LinkRow: View {
    @EnvironmentObject var model: AppModel
    let line: String

    var body: some View {
        let url = HomeParse.firstUrl(line)
        Button {
            if let url { openHomeLink(url, model) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: url == nil ? "text.alignleft" : "link").font(.caption).foregroundStyle(url == nil ? Color.secondary : Color.blue)
                Text(HomeParse.plain(line)).font(.callout).foregroundStyle(url == nil ? Color.primary : Color.blue)
                    .lineLimit(2).multilineTextAlignment(.leading)
                Spacer(minLength: 4)
                if url != nil { Image(systemName: "arrow.up.right").font(.caption2.weight(.bold)).foregroundStyle(.blue.opacity(0.7)) }
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(url == nil)
    }
}

// MARK: - 编辑对话框

struct HomeEditSheet: View {
    let edit: HomeEdit
    let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @FocusState private var focused: Bool

    init(edit: HomeEdit, onSave: @escaping (String) -> Void) {
        self.edit = edit
        self.onSave = onSave
        _text = State(initialValue: edit.initial)
    }

    private var canSave: Bool { edit.mode == .replace || !text.trimmed.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(edit.title).font(.title3.weight(.bold))
            Text(edit.hint).font(.callout).foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.body).scrollContentBackground(.hidden)
                .focused($focused)
                .padding(8)
                .frame(minHeight: edit.mode == .replace ? 160 : 110)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(edit.mode == .replace ? "保存" : "添加") {
                    onSave(text)
                    dismiss()
                }
                .buttonStyle(.borderedProminent).tint(Brand.orange)
                .keyboardShortcut(.defaultAction).disabled(!canSave)
            }
        }
        .padding(22)
        .frame(width: 460)
        .onAppear { focused = true }
    }
}
