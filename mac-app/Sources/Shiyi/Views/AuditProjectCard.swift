import AppKit
import SwiftUI

// MARK: - 侧栏：当前审计项目

/// 正在做的审计项目（结审里「当前项目」，没钉住就取第一个）：阶段进度，以及已发出、还没收回的取证单——到了回复期限没收回的标红
struct AuditProjectCard: View {
    /// 下面的仪表：拿到审计项目的几个环，排进自己的环里
    let content: ([AnyView]) -> AnyView
    @EnvironmentObject var model: AppModel
    @State private var docs: SjzDocs?
    @State private var items: [SjzOutstanding] = []
    @State private var caps: [SjzCapture] = []
    @State private var summaries: [SjzSummary] = []
    @State private var loadedItems = false
    /// 取证单发出后多少天内应当收回；超过就算逾期（结审里没有单独的期限字段，先统一按这个天数算）
    @AppStorage("sjz.replyDays") private var replyDays = 5
    /// 正在预览的那一类：点统计数字或右键菜单选择，弹出里面具体有哪些
    @State private var peek: Peek?

    enum Peek: String, Identifiable, CaseIterable {
        case today, clues, ideas, evidence, regulations, datalists, all, open, overdue, summaries, recall
        var id: String { rawValue }
        var title: String {
            switch self {
            case .today: return "今日新增"
            case .clues: return "待核实线索"
            case .ideas: return "想法"
            case .evidence: return "证据"
            case .regulations: return "法规"
            case .datalists: return "资料清单"
            case .all: return "全部记录"
            case .open: return "未完成任务"
            case .overdue: return "逾期任务"
            case .summaries: return "工作小结"
            case .recall: return "待收回"
            }
        }
        var icon: String {
            switch self {
            case .today: return "sparkles"
            case .clues: return "lightbulb"
            case .ideas: return "text.bubble"
            case .evidence: return "doc.text.image"
            case .regulations: return "book.closed"
            case .datalists: return "list.clipboard"
            case .all: return "tray.full"
            case .open: return "checklist"
            case .overdue: return "exclamationmark.circle"
            case .summaries: return "doc.richtext"
            case .recall: return "tray.and.arrow.down"
            }
        }
        /// 统计里有对应数字的几类：弹窗挂在那个数字上，其余的挂在整张卡片上
        var hasTile: Bool { self == .open || self == .overdue || self == .clues || self == .today || self == .summaries || self == .recall }
    }

    struct PeekEntry: Identifiable {
        let id: String
        let icon: String
        let tint: Color
        let title: String
        let sub: String
        let trailing: String
        let trailTint: Color
        let open: () -> Void
    }

    private static var docCache: [String: SjzDocs] = [:]
    private static var itemCache: [String: [SjzOutstanding]] = [:]
    private static var capCache: [String: [SjzCapture]] = [:]
    private static var summaryCache: [String: [SjzSummary]] = [:]
    /// 上次显示的项目：切页面回来时，环里的数字一开始就是上次的，不会先归零再涨上去
    private static var lastProject = ""

    init(content: @escaping ([AnyView]) -> AnyView) {
        self.content = content
        let n = Self.lastProject
        if !n.isEmpty {
            _docs = State(initialValue: Self.docCache[n])
            _items = State(initialValue: Self.itemCache[n] ?? [])
            _caps = State(initialValue: Self.capCache[n] ?? [])
            _summaries = State(initialValue: Self.summaryCache[n] ?? [])
            _loadedItems = State(initialValue: Self.itemCache[n] != nil)
        }
    }

    private var name: String { model.sjzPin.project.isEmpty ? (model.sjzOverview?.projects.first?.name ?? "") : model.sjzPin.project }
    private var title: String {
        if let t = model.sjzOverview?.projects.first(where: { $0.name == name })?.title, !t.isEmpty { return t }
        return model.sjzPin.projectTitle.isEmpty ? name : model.sjzPin.projectTitle
    }

    private var stat: SjzProjectStat? { model.sjzOverview?.projects.first { $0.name == name } }
    private var todayCount: Int { caps.filter { c in c.date.map { Calendar.current.isDateInToday($0) } ?? false }.count }
    private var pendingClues: Int { caps.filter { $0.kind == "clue" && $0.status == "pending" }.count }

    /// 一行待收回的东西：已发出没收回的取证单，或带 #资料清单 标签、有计划日期和截止日期的任务
    private struct Row: Identifiable {
        let id: String
        let isList: Bool
        let title: String
        let matter: String
        let range: String?
        /// 距离到期还有几天（负数 = 已逾期）；没有日期为 nil
        let left: Int?
        /// 还没到计划开始日（资料清单）
        let notStarted: Bool
        /// 已发出的资料清单：结审里的文书路径（用来找到对应的记录，标记已收回）；取证单和任务形式的清单为 nil
        var recallPath: String? = nil
        let open: () -> Void
    }

    private static let rangeFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "M/d"
        return f
    }()

    private var rows: [Row] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        func days(_ to: Date) -> Int { cal.dateComponents([.day], from: today, to: cal.startOfDay(for: to)).day ?? 0 }
        let f = Self.rangeFmt
        let n = name
        var out: [Row] = items.map { it in
            let d = it.sentDate
            let isData = it.kind == "data_request"
            let due = isData ? Day.parse(it.dueAt) : d.flatMap { cal.date(byAdding: .day, value: replyDays, to: cal.startOfDay(for: $0)) }
            return Row(id: "note:" + it.path, isList: isData,
                       title: [it.no, it.unit.isEmpty ? it.title : it.unit].filter { !$0.isEmpty }.joined(separator: " "),
                       matter: it.matter.isEmpty ? (it.unit.isEmpty ? "" : it.title) : it.matter,
                       range: d.flatMap { s in due.map { "\(f.string(from: s)) 发出 → \(f.string(from: $0)) \(isData ? "截止" : "到期")" } },
                       left: due.map(days), notStarted: false,
                       recallPath: isData ? it.path : nil,
                       open: { model.openSjzApp(project: n, to: "/documents?open=" + AppModel.urlEnc(it.path)) })
        }
        for t in model.sjzOverview?.next ?? [] where t.project == n && Self.isList(t) {
            let sd = Day.parse(String((t.startDate ?? "").prefix(10)))
            let dd = Day.parse(String(t.dueDate.prefix(10)))
            guard let sd, let dd else { continue }
            out.append(Row(id: "task:" + t.id, isList: true,
                           title: Self.cleanTitle(t.subject), matter: "",
                           range: "\(f.string(from: sd)) → \(f.string(from: dd))",
                           left: days(dd), notStarted: days(sd) > 0,
                           open: { model.openSjzApp(project: n, to: "/tasks?task=" + AppModel.urlEnc(t.id)) }))
        }
        return out.sorted { ($0.left ?? 9999) < ($1.left ?? 9999) }
    }

    /// 任务里带「#资料清单」标签，并且同时有计划日期和截止日期
    private static func isList(_ t: SjzTaskLite) -> Bool {
        guard (t.subject + " " + t.detail).contains("#资料清单") else { return false }
        return !(t.startDate ?? "").isEmpty && !t.dueDate.isEmpty
    }

    private static func cleanTitle(_ s: String) -> String {
        let t = s.replacingOccurrences(of: "#资料清单", with: "").trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? "资料清单" : t
    }

    var body: some View {
        if !name.isEmpty {
            let rs = rows
            let late = rs.filter { ($0.left ?? 0) < 0 }.count
            Panel {
                CardHeader(icon: "checkmark.shield", title: "正在做的审计项目") {
                    Button { model.section = .focus; model.selectedProject = SjzTasks.prefix + name } label: {
                        HStack(spacing: 3) {
                            Text("打开项目")
                            Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                        }
                        .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                // 项目名 + 阶段进度
                VStack(alignment: .leading, spacing: 9) {
                    Text(title).font(.system(size: 15, weight: .semibold)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    if let d = docs, !d.phases.isEmpty { phaseBar(d) }
                }
                .padding(.horizontal, 16).padding(.bottom, 4)
                content(ringViews(rs))
                if !rs.isEmpty {
                    Divider().padding(.horizontal, 16)
                    HStack(spacing: 6) {
                        Text("待收回").foregroundStyle(.secondary)
                        Text("\(rs.count)").foregroundStyle(.tertiary)
                        if late > 0 { TagChip(text: "\(late) 条已逾期", tint: .red) }
                        Spacer(minLength: 4)
                        if rs.contains(where: { !$0.isList }) {
                            Text("取证单期限 \(replyDays) 天").font(.caption2).foregroundStyle(.tertiary).help("取证单发出后 \(replyDays) 天内应收回，右键卡片可以改；资料清单按任务的计划日期和截止日期算")
                        }
                    }
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 2)
                    ForEach(Array(rs.prefix(3).enumerated()), id: \.element.id) { i, r in
                        row(r).padding(.horizontal, 16).padding(.vertical, 6)
                        if i < min(rs.count, 3) - 1 { Divider().padding(.leading, 16) }
                    }
                    if rs.count > 3 { Text("还有 \(rs.count - 3) 条，在结审里查看").font(.caption2).foregroundStyle(.tertiary).padding(.horizontal, 16).padding(.vertical, 4) }
                }
            }
            .popover(item: Binding(get: { peek.flatMap { $0.hasTile ? nil : $0 } }, set: { if $0 == nil { peek = nil } }), arrowEdge: .leading) { k in
                peekList(k)
            }
            .contextMenu { projectMenu }
            .task(id: name) { await load() }
            .onReceive(NotificationCenter.default.publisher(for: .sjzCapturesChanged)) { _ in Task { await load() } }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in Task { await load() } }
        } else {
            VStack(spacing: 0) {
                content([])
                Color.clear.frame(height: 0)
                    .task { await model.refreshSjzTarget(); await model.refreshSjzOverview() }
            }
        }
    }

    private func row(_ r: Row) -> some View {
        let (badge, tint) = Self.badge(r.left, notStarted: r.notStarted)
        return Button(action: r.open) {
            HStack(alignment: .center, spacing: 8) {
                Text(badge).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(tint)
                    .frame(width: 52).padding(.vertical, 3)
                    .background(tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(r.title).font(.system(size: 13, weight: .medium)).foregroundStyle(.primary).lineLimit(1)
                    HStack(spacing: 5) {
                        Text(r.isList ? "资料清单" : "取证单").font(.system(size: 10, weight: .medium)).foregroundStyle(r.isList ? Color.indigo : Brand.orange)
                        if let range = r.range {
                            Text(range).font(.system(size: 10.5, weight: .medium)).monospacedDigit().foregroundStyle((r.left ?? 0) < 0 ? Color.red : Color.secondary)
                        }
                        if !r.matter.isEmpty { Text(r.matter).font(.caption2).foregroundStyle(.tertiary).lineLimit(1) }
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(r.id.hasPrefix("task:") ? "在结审里打开这个任务" : r.isList ? "在结审里打开这份资料清单" : "在结审里打开这份取证单")
        .contextMenu {
            // 资料清单：对方交齐了就标记已收回，收回日期默认今天
            if r.recallPath != nil {
                Button { Task { await markRecalled(r) } } label: { Label("已收回", systemImage: "tray.and.arrow.down") }
                Divider()
            }
            Button(action: r.open) {
                Label(r.id.hasPrefix("task:") ? "在结审里打开这个任务" : r.isList ? "在结审里打开这份资料清单" : "在结审里打开这份取证单", systemImage: "arrow.up.forward.app")
            }
            Button { model.copy(r.title) } label: { Label("复制标题", systemImage: "doc.on.doc") }
            Divider()
            projectMenu
        }
    }

    /// 卡片本身的右键菜单（行上的菜单在最后也带上这些）
    @ViewBuilder private var projectMenu: some View {
        Section("打开") {
            Button { model.section = .focus; model.selectedProject = SjzTasks.prefix + name } label: { Label("在拾忆里打开项目", systemImage: "folder") }
            Button { model.openSjzApp(project: name, to: "/") } label: { Label("在结审里打开项目", systemImage: "arrow.up.forward.app") }
        }
        // 期限只对取证单有用：当前没有待收回的取证单就不显示
        if rows.contains(where: { !$0.isList }) {
            Section("设置") {
                Menu {
                    ForEach([3, 5, 7, 10, 15, 30], id: \.self) { d in
                        Button { replyDays = d } label: { if replyDays == d { Label("\(d) 天", systemImage: "checkmark") } else { Text("\(d) 天") } }
                    }
                } label: { Label("取证单回复期限（\(replyDays) 天）", systemImage: "clock.badge.checkmark") }
            }
        }
    }

    /// 在这个项目的资料清单记录里找到对应的一条（文书路径一致；退一步按文件名）
    private static func datalistCapture(path: String, in list: [SjzCapture]) -> SjzCapture? {
        let ls = list.filter { $0.kind == "datalist" }
        if let c = ls.first(where: { $0.path == path }) { return c }
        let file = (path as NSString).lastPathComponent
        guard !file.isEmpty else { return nil }
        return ls.first { ($0.path as NSString).lastPathComponent == file }
    }

    /// 标记资料清单已收回：收回日期写成今天，结审会把状态流转为「已收回」
    private func markRecalled(_ r: Row) async {
        guard let path = r.recallPath else { return }
        let n = name
        var cap = Self.datalistCapture(path: path, in: caps)
        if cap == nil, let fresh = try? await model.sjz.captures(project: n, kind: "datalist", limit: 200) {
            cap = Self.datalistCapture(path: path, in: fresh)
        }
        guard let cap else { model.showNotice("没找到这份资料清单的记录，请到结审里标记"); return }
        do {
            _ = try await model.sjz.updateCapture(project: n, id: cap.id, fields: ["recalledAt": Day.today()])
            SjzDetailStore.forget(project: n, id: cap.id)
            items.removeAll { $0.path == path }
            Self.itemCache[n] = items
            model.showNotice("已收回：\(r.title)")
            await model.refreshSjzOverview(force: true)
            AppModel.lastDatalistSync = .distantPast
            await model.syncDatalistReminders()
            await load()
        } catch { model.showNotice(error.localizedDescription) }
    }

    private static func badge(_ left: Int?, notStarted: Bool) -> (String, Color) {
        guard let left else { return ("未记日期", .secondary) }
        if notStarted, left >= 0 { return ("未开始", .secondary) }
        if left < 0 { return ("逾期 \(-left) 天", .red) }
        if left == 0 { return ("今天到期", .orange) }
        if left <= 2 { return ("还剩 \(left) 天", .orange) }
        return ("还剩 \(left) 天", .secondary)
    }

    private func mini(_ label: String, _ value: String, _ color: Color, _ k: Peek) -> some View {
        PeekTile(label: label, value: value, color: color, active: peek == k) { peek = peek == k ? nil : k }
            .popover(isPresented: Binding(get: { peek == k }, set: { if !$0 && peek == k { peek = nil } }), arrowEdge: .bottom) { peekList(k) }
    }

    /// 并进仪表的三个环：工作小结、待核实线索、待收回
    private func ringViews(_ rs: [Row]) -> [AnyView] {
        [
            AnyView(ring("工作小结", summaries.count, cap: 5, color: Color(red: 0.16, green: 0.66, blue: 0.72), .summaries)),
            AnyView(ring("待核实线索", pendingClues, cap: 10, color: Color(red: 0.92, green: 0.34, blue: 0.55), .clues)),
            AnyView(ring("待收回", rs.count, cap: 5, color: Color(red: 0.96, green: 0.71, blue: 0.25), .recall)),
        ]
    }

    /// 一个环：数字在中间，满环按 cap 算；点一下弹出列表
    private func ring(_ label: String, _ value: Int, cap: Double, color: Color, _ k: Peek, badge: String? = nil) -> some View {
        Button { peek = peek == k ? nil : k } label: {
            MiniRing(color: color, progress: min(Double(value) / cap, 1), value: "\(value)", label: label)
                .overlay(alignment: .topTrailing) {
                    if let badge {
                        Text(badge).font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                            .padding(.horizontal, 5).padding(.vertical, 1.5)
                            .background(Color.red, in: Capsule())
                            .offset(x: -2, y: -2)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("点一下看看是哪些")
        .popover(isPresented: Binding(get: { peek == k }, set: { if !$0 && peek == k { peek = nil } }), arrowEdge: .bottom) { peekList(k) }
    }

    private func peekList(_ k: Peek) -> some View {
        PeekListView(kind: k, entries: entries(k),
                     headCount: k == .summaries ? Self.summaryHeadCount(summaries) : nil,
                     actions: k == .summaries ? Self.summaryActions(project: name, model: model) : []) { peek = nil }
    }

    /// 工作小结的列表项：点一下在结审里打开这份小结
    static func summaryEntries(_ list: [SjzSummary], project: String, model: AppModel) -> [PeekEntry] {
        orderedSummaries(list).map { s in
            PeekEntry(id: "summary:" + s.path, icon: "doc.richtext", tint: .indigo,
                      title: "\(s.kindLabel) · \(s.shortPeriod)",
                      sub: [s.manual ? "手写" : (s.auto ? "自动生成" : "手动生成"), s.ai ? "AI 润色" : ""].filter { !$0.isEmpty }.joined(separator: " · "),
                      trailing: s.date.map(timeLabel) ?? "", trailTint: .secondary,
                      open: { model.openSjzPreview(project: project, capture: s.asCapture) })
        }
    }

    /// 排序：每种小结（周报、日报、阶段报告、项目小结）最新的一份排最前，其余按时间排在后面
    static func orderedSummaries(_ list: [SjzSummary]) -> [SjzSummary] {
        let sorted = list.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        let heads = ["weekly", "daily", "phase", "project"].compactMap { k in sorted.first { $0.kind == k } }
        return heads + sorted.filter { s in !heads.contains(where: { $0.path == s.path }) }
    }

    /// 前面几条默认展开（每种最新的一份），其余折叠
    static func summaryHeadCount(_ list: [SjzSummary]) -> Int { Set(list.map(\.kind)).count }

    struct PeekAction: Identifiable {
        let id: String
        let label: String
        let icon: String
        let run: () async -> Void
    }

    /// 弹窗底部的「生成今日日报 / 本周周报」
    static func summaryActions(project: String, model: AppModel) -> [PeekAction] {
        [("daily", "生成今日日报", "sun.max"), ("weekly", "生成本周周报", "calendar")].map { kind, label, icon in
            PeekAction(id: kind, label: label, icon: icon, run: { await generateSummary(project: project, kind: kind, model: model) })
        }
    }

    /// 生成并打开预览；同一统计期间已有小结时先问：覆盖还是查看已有的
    @MainActor static func generateSummary(project: String, kind: String, model: AppModel) async {
        do {
            var r = try await model.sjz.generateSummary(project: project, kind: kind)
            if r.exists, let s = r.summary {
                let alert = NSAlert()
                alert.messageText = "已经有一份\(s.kindLabel)"
                let mine = r.message.contains("手写")
                alert.informativeText = mine ? "这份是你手写的，覆盖后你写的内容会丢失。要覆盖，还是先看看已有的？" : "同一统计期间只保留一份。要覆盖重新生成，还是先看看已有的？"
                alert.addButton(withTitle: mine ? "仍然覆盖" : "覆盖重新生成")
                alert.addButton(withTitle: "查看已有的")
                alert.addButton(withTitle: "取消")
                switch alert.runModal() {
                case .alertFirstButtonReturn: r = try await model.sjz.generateSummary(project: project, kind: kind, overwrite: true)
                case .alertSecondButtonReturn: model.openSjzPreview(project: project, capture: s.asCapture); return
                default: return
                }
            }
            guard let s = r.summary else { model.showNotice(r.message.isEmpty ? "没有生成" : r.message); return }
            SjzDetailStore.forget(project: project, id: s.asCapture.id)
            model.showNotice("已生成\(s.kindLabel)")
            model.openSjzPreview(project: project, capture: s.asCapture)
        } catch { model.showNotice(error.localizedDescription) }
    }

    private func capEntries(_ list: [SjzCapture]) -> [PeekEntry] {
        let n = name
        return list.map { c in
            PeekEntry(id: c.id, icon: c.icon, tint: SjzProjectDetailView.kindTint(c.kind),
                      title: (c.title.isEmpty ? c.summary : c.title).mdPlain,
                      sub: ["\(c.kindLabel) · \(c.id)", c.statusLabel].filter { !$0.isEmpty }.joined(separator: " · "),
                      trailing: c.date.map(Self.timeLabel) ?? "", trailTint: .secondary,
                      open: { model.openSjzEditor(project: n, capture: c) })
        }
    }

    private func taskEntries(overdueOnly: Bool) -> [PeekEntry] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let n = name
        let list: [(SjzTaskLite, Int?)] = (model.sjzOverview?.next ?? []).filter { $0.project == n }.map { t in
            let due = Day.parse(String(t.dueDate.prefix(10)))
            return (t, due.map { cal.dateComponents([.day], from: today, to: cal.startOfDay(for: $0)).day ?? 0 })
        }
        return list.filter { !overdueOnly || ($0.1 ?? 0) < 0 }
            .sorted { ($0.1 ?? 9999) < ($1.1 ?? 9999) }
            .map { t, left in
                let (badge, tint) = Self.badge(left, notStarted: false)
                return PeekEntry(id: "task:" + t.id, icon: Self.isList(t) ? "list.clipboard" : "checklist", tint: Self.isList(t) ? .indigo : Brand.orange,
                                 title: Self.cleanTitle(t.subject), sub: Self.isList(t) ? "资料清单任务" : "任务",
                                 trailing: badge, trailTint: tint,
                                 open: { model.openSjzApp(project: n, to: "/tasks?task=" + AppModel.urlEnc(t.id)) })
            }
    }

    private func entries(_ k: Peek) -> [PeekEntry] {
        switch k {
        case .today: return capEntries(caps.filter { c in c.date.map { Calendar.current.isDateInToday($0) } ?? false })
        case .clues: return capEntries(caps.filter { $0.kind == "clue" && $0.status == "pending" })
        case .ideas: return capEntries(caps.filter { $0.kind == "idea" })
        case .evidence: return capEntries(caps.filter { $0.kind == "evidence" })
        case .regulations: return capEntries(caps.filter { $0.kind == "regulation" })
        case .datalists: return capEntries(caps.filter { $0.kind == "datalist" })
        case .all: return capEntries(caps)
        case .open: return taskEntries(overdueOnly: false)
        case .overdue: return taskEntries(overdueOnly: true)
        case .summaries: return Self.summaryEntries(summaries, project: name, model: model)
        case .recall:
            return rows.map { r in
                let (badge, tint) = Self.badge(r.left, notStarted: r.notStarted)
                return PeekEntry(id: r.id, icon: r.isList ? "list.clipboard" : "doc.text", tint: r.isList ? .indigo : Brand.orange,
                                 title: r.title, sub: [r.isList ? "资料清单" : "取证单", r.matter].filter { !$0.isEmpty }.joined(separator: " · "),
                                 trailing: badge, trailTint: tint, open: r.open)
            }
        }
    }

    fileprivate static func timeLabel(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDateInToday(d) ? "HH:mm" : "M/d HH:mm"
        return f.string(from: d)
    }

    private func phaseBar(_ d: SjzDocs) -> some View {
        let cur = d.phases.firstIndex(where: { $0.current }) ?? d.phases.firstIndex(where: { $0.key == d.phase }) ?? 0
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 3) {
                ForEach(Array(d.phases.enumerated()), id: \.offset) { i, _ in
                    Capsule().fill(i < cur ? Brand.orange.opacity(0.45) : i == cur ? Brand.orange : Color.primary.opacity(0.1)).frame(height: 4)
                }
            }
            HStack {
                Text(d.phases[cur].label).font(.caption.weight(.semibold))
                Spacer()
                Text("第 \(cur + 1) / \(d.phases.count) 阶段").font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    private struct RecentEntry: Identifiable {
        let id: String
        let icon: String
        let tint: Color
        let text: String
        let date: Date?
        let action: () -> Void
    }

    /// 「最近」：拾忆写进去的记录（工作小结单独放在统计行里）
    private var recentEntries: [RecentEntry] {
        let n = name
        let out: [RecentEntry] = caps.prefix(3).map { c in
            RecentEntry(id: c.id, icon: c.icon, tint: SjzProjectDetailView.kindTint(c.kind),
                        text: "\(c.kindLabel) · \(c.title.isEmpty ? c.summary : c.title)".mdPlain, date: c.date,
                        action: { model.openSjzPreview(project: n, capture: c) })
        }
        return out
    }

    /// 先用上次的结果画出来，再在后台刷新；钉住的项目或概览还没读到时先读
    private func load() async {
        if model.sjzPin.project.isEmpty { await model.refreshSjzTarget() }
        if model.sjzOverview == nil { await model.refreshSjzOverview() }
        let n = name
        guard !n.isEmpty else { return }
        Self.lastProject = n
        if docs == nil, let c = Self.docCache[n] { docs = c }
        if items.isEmpty, let c = Self.itemCache[n] { items = c; loadedItems = true }
        if caps.isEmpty, let c = Self.capCache[n] { caps = c }
        if let c = try? await model.sjz.captures(project: n, limit: 300) { caps = c; Self.capCache[n] = c }
        if let c = try? await model.sjz.outstanding(project: n) { items = c; loadedItems = true; Self.itemCache[n] = c }
        if let sm = try? await model.sjz.summaries(project: n) { summaries = sm; Self.summaryCache[n] = sm }
        if let d = try? await model.sjz.documents(project: n) { docs = d; Self.docCache[n] = d }
    }
}
