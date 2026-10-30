import AppKit
import SwiftUI

/// 「项目」页里的审计项目（来自结审）。数据只来自结审：任务、专注和记录都写回结审，不进滴答和闪念贝壳。
struct SjzProjectDetailView: View {
    @EnvironmentObject var model: AppModel
    let name: String

    @State private var docs: SjzDocs?
    @State private var selPhase = ""
    @State private var captures: [SjzCapture] = []
    /// 结审里生成过的工作小结（存在项目工作日志里）
    @State private var summaries: [SjzSummary] = []
    @State private var showSummaries = false
    @State private var capsLoaded = false
    @State private var capKind = ""
    @State private var capQuery = ""
    @State private var openGroups: Set<String> = []
    @State private var newList = false
    @State private var capDays = 0
    /// 空格快速预览的那一项；鼠标停在哪一条上，空格就预览哪一条
    @State private var hoverCap: SjzCapture?
    @State private var keyMonitor: Any?
    /// 等用户确认删除的那一项
    @State private var deleting: SjzCapture?
    @State private var newTitle = ""
    @State private var newDue = ""
    @State private var newStart = ""
    @State private var adding = false

    private var stat: SjzProjectStat? { model.sjzOverview?.projects.first { $0.name == name } }
    private var title: String { stat?.title ?? name }
    private var pinned: Bool { model.sjzPin.project == name }

    private var tasks: [DidaTask] {
        guard let ov = model.overview else { return [] }
        let id = SjzTasks.prefix + name
        let all = (ov.overdue + ov.upcoming + ov.undated).filter { $0.projectId == id }
        return all.sorted { ($0.date ?? "9999") < ($1.date ?? "9999") }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                statsRow
                tasksCard
                capturesCard
                docsCard
            }
            .padding(24)
            .frame(maxWidth: 780, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(AmbientBackground())
        .task(id: name) {
            docs = nil
            selPhase = ""
            // 先用上次的数据把列表画出来，再并行刷新；文书统计最慢，放在最后，不挡着「来自拾忆」
            if captures.isEmpty, let cached = Self.capCache[name] {
                let cleared = clearedIds
                captures = cached.filter { !cleared.contains($0.id) }
                capsLoaded = true
            }
            async let caps: Void = loadCaptures()
            async let ov: Void = model.refreshSjzOverview()
            _ = await (caps, ov)
            docs = try? await model.sjz.documents(project: name)
        }
        // 停留在这个页面时每几秒静默重读一次；切回拾忆窗口、结审有写入时立刻重读
        .task(id: "poll-" + name) {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                if NSApp.isActive { await loadCaptures() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await loadCaptures() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .sjzCapturesChanged)) { _ in
            Task { await loadCaptures() }
        }
        .sheet(isPresented: $newList) {
            SjzNewDatalistSheet(project: name) { await loadCaptures() }
                .environmentObject(model)
        }
        .onAppear(perform: installKeys)
        .onDisappear {
            if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        }
        .alert("删除\(deleting?.kindLabel ?? "")？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("删除", role: .destructive) {
                if let c = deleting { Task { await runCapture { try await model.sjz.deleteCapture(project: name, id: c.id) } } }
                deleting = nil
            }
            Button("取消", role: .cancel) { deleting = nil }
        } message: {
            if let c = deleting {
                Text("「\(c.title.isEmpty ? c.summary : c.title)」会同时从结审项目里删除，不能恢复。")
            }
        }
    }

    /// 空格：预览鼠标所在的那一条（再按一次或 Esc 关闭，回车转到编辑）。在输入框里打字时不拦截
    private func installKeys() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { ev in
            guard let w = NSApp.keyWindow, ev.window === w, !SjzEditorWindows.shared.isEditorWindow(w), !SjzPreviewWindows.shared.isPreviewWindow(w), !(w.firstResponder is NSText),
                  ev.modifierFlags.intersection([.command, .option, .control]).isEmpty else { return ev }
            if ev.keyCode == 49, let c = hoverCap {
                if !ev.isARepeat { model.toggleSjzPreview(project: name, capture: c) }
                return nil
            }
            return ev
        }
    }

    private func prefetch(_ c: SjzCapture) {
        Task {
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard hoverCap?.id == c.id else { return }
            await SjzDetailStore.load(api: model.sjz, project: name, id: c.id)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "checkmark.shield")
                .font(.system(size: 18, weight: .semibold)).foregroundStyle(Brand.orange)
                .frame(width: 38, height: 38)
                .background(Brand.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.title2.weight(.semibold)).lineLimit(2)
                let tags = stat?.infoTags ?? []
                if !tags.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(Array(tags.enumerated()), id: \.offset) { i, t in
                                TagChip(text: t, tint: i == 0 ? Brand.orange : .secondary).lineLimit(1).fixedSize()
                            }
                        }
                    }
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 6) {
                Button { model.openSjzApp(project: name, to: "/projects?detail=" + AppModel.urlEnc(name)) } label: { Label("打开结审", systemImage: "arrow.up.forward.app") }
                    .buttonStyle(.bordered)
                if !pinned {
                    Button { Task { await model.sjzSetProject(name) } } label: { Label("设为当前项目", systemImage: "pin") }
                        .buttonStyle(.borderless)
                }
            }
            .font(.callout)
        }
    }

    /// 新建任务：直接写进结审这个项目（和结审里的任务是同一份）
    private var addTaskRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus.circle.fill").foregroundStyle(Brand.orange)
            TextField("新建任务，回车添加到结审", text: $newTitle)
                .textFieldStyle(.plain).font(.callout)
                .onSubmit { Task { await addTask() } }
            DayPickerButton(title: "开始", icon: "flag", value: $newStart)
                .help("计划开始日（甘特图横条的起点）")
            DayPickerButton(title: "截止", icon: "calendar", value: $newDue)
                .help("截止日")
            Button("添加") { Task { await addTask() } }
                .disabled(newTitle.trimmed.isEmpty || adding)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .padding(.bottom, 4)
    }

    private func addTask() async {
        let t = newTitle.trimmed
        guard !t.isEmpty, !adding else { return }
        adding = true
        defer { adding = false }
        do {
            if !newStart.isEmpty, !newDue.isEmpty, newStart > newDue { model.showNotice("开始日不能晚于截止日"); return }
            try await model.sjz.createTask(project: name, subject: t, startDate: newStart, dueDate: newDue)
            newTitle = ""
            newDue = ""
            newStart = ""
            model.showNotice("已添加到结审的任务")
            await model.refreshSjzOverview(force: true)
        } catch { model.showNotice(error.localizedDescription) }
    }

    private var statsRow: some View {
        let s = stat
        return HStack(spacing: 10) {
            StatTile(value: "\(s?.open ?? 0)", label: "待办")
            StatTile(value: "\(s?.dueToday ?? 0)", label: "今天到期", tint: (s?.dueToday ?? 0) > 0 ? Brand.orange : .primary)
            StatTile(value: "\(s?.overdue ?? 0)", label: "逾期", tint: (s?.overdue ?? 0) > 0 ? .red : .primary)
            StatTile(value: "\(s?.pendingReviews ?? 0)", label: "待复核", tint: (s?.pendingReviews ?? 0) > 0 ? Brand.orange : .primary)
            Button { showSummaries.toggle() } label: {
                StatTile(value: "\(summaries.count)", label: "工作小结", tint: summaries.isEmpty ? .primary : .indigo)
            }
            .buttonStyle(.plain)
            .help("结审里生成的日报、周报、阶段报告，点开选一份查看")
            .popover(isPresented: $showSummaries, arrowEdge: .bottom) {
                PeekListView(kind: .summaries, entries: AuditProjectCard.summaryEntries(summaries, project: name, model: model)) { showSummaries = false }
            }
        }
    }

    @ViewBuilder private var tasksCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                SectionTitle(text: "相关待办", count: tasks.count)
                addTaskRow
                if tasks.isEmpty {
                    Text("这个项目没有未完成的任务").font(.callout).foregroundStyle(.tertiary).padding(.vertical, 4)
                }
                ForEach(tasks.prefix(15)) { t in
                    HStack(spacing: 6) {
                        TaskRow(task: t, overdue: (t.date ?? "9999") < Day.today(), showDate: true, showProject: false)
                        Button {
                            model.focus.attach(t)
                            model.selectedProject = nil
                        } label: { Image(systemName: "play.circle.fill").font(.system(size: 18)).foregroundStyle(Brand.orange) }
                            .buttonStyle(.plain)
                            .help("专注这个任务（时长和记录写回结审）")
                    }
                }
                if tasks.count > 15 { Text("还有 \(tasks.count - 15) 项，在结审里查看").font(.caption).foregroundStyle(.tertiary) }
            }
        }
    }
}

extension SjzProjectDetailView {
    @ViewBuilder fileprivate var docsCard: some View {
        if let d = docs, d.total > 0 || !d.phase.isEmpty {
            let order = d.phases.map(\.key)
            let curIdx = order.firstIndex(of: d.phase) ?? -1
            let sel = d.phases.first { $0.key == (selPhase.isEmpty ? d.phase : selPhase) } ?? d.phases.first
            Card {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 8) {
                        SectionTitle(text: "文书中心", count: d.total)
                        Spacer()
                        Button { model.openSjzApp(project: name, to: "/documents") } label: { Label("在结审里打开", systemImage: "arrow.up.forward.app") }
                            .buttonStyle(.borderless).font(.caption)
                    }
                    if d.phases.count > 1 {
                        HStack(alignment: .top, spacing: 0) {
                            ForEach(Array(d.phases.enumerated()), id: \.element.id) { idx, p in
                                timelineNode(p, idx: idx, curIdx: curIdx, last: idx == d.phases.count - 1, selected: p.key == sel?.key)
                            }
                        }
                    }
                    if let p = sel {
                        Divider().opacity(0.6)
                        VStack(alignment: .leading, spacing: 12) {
                            if !p.plan.isEmpty { Text("计划：" + p.plan).font(.caption).foregroundStyle(.secondary) }
                            let rows = p.items.filter { $0.count > 0 || $0.required }
                            if rows.isEmpty { Text("这个阶段还没有文书").font(.callout).foregroundStyle(.tertiary) }
                            ForEach(rows) { t in docTypeBlock(t) }
                        }
                    }
                }
            }
        }
    }

    /// 横向时间线的一个节点：线 + 圆点（已完成绿 ✓ / 当前橙 / 未开始灰），下面是阶段名和成果数
    private func timelineNode(_ p: SjzPhase, idx: Int, curIdx: Int, last: Bool, selected: Bool) -> some View {
        let done = curIdx >= 0 && idx < curIdx
        let cur = p.current
        let green = Color.green.opacity(0.75)
        let gray = Color.secondary.opacity(0.28)
        return Button { selPhase = p.key } label: {
            VStack(spacing: 7) {
                HStack(spacing: 0) {
                    Rectangle().fill(idx == 0 ? Color.clear : (done || cur ? green : gray)).frame(height: 2)
                    ZStack {
                        if cur { Circle().fill(Brand.orange.opacity(0.2)).frame(width: 26, height: 26) }
                        Circle().fill(cur ? Brand.orange : (done ? Color.green.opacity(0.85) : Color(nsColor: .controlBackgroundColor)))
                            .frame(width: 14, height: 14)
                        if !cur && !done { Circle().strokeBorder(Color.secondary.opacity(0.4), lineWidth: 1.5).frame(width: 14, height: 14) }
                        if done { Image(systemName: "checkmark").font(.system(size: 8, weight: .heavy)).foregroundStyle(.white) }
                    }
                    .frame(width: 26, height: 26)
                    Rectangle().fill(last ? Color.clear : (done ? green : gray)).frame(height: 2)
                }
                VStack(spacing: 2) {
                    Text(p.label).font(.callout.weight(selected || cur ? .semibold : .regular))
                        .foregroundStyle(selected || cur ? Color.primary : Color.secondary)
                    Text(p.count > 0 ? "\(p.count) 份成果" : (cur ? "进行中" : "暂无")).font(.caption2)
                        .foregroundStyle(cur && p.count == 0 ? Brand.orange : Color.secondary.opacity(0.7))
                    if !p.range.isEmpty {
                        Text(p.range).font(.caption2).foregroundStyle(.tertiary).monospacedDigit().lineLimit(1)
                    }
                    Capsule().fill(selected ? Brand.orange : Color.clear).frame(width: 18, height: 2.5).padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func statusTint(_ label: String) -> Color {
        if label == "草稿" || label == "讨论稿" { return .secondary }
        if ["已签发", "定稿", "正式版", "已归档", "复核通过", "已发出"].contains(label) { return .green }
        return Brand.orange
    }

    private func docTypeBlock(_ t: SjzDocType) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(t.label).font(.callout.weight(.semibold)).foregroundStyle(t.count == 0 ? Color.secondary : Color.primary)
                if t.count > 0 {
                    Text("\(t.count) 份").font(.caption).foregroundStyle(.secondary)
                    if t.issued > 0 { TagChip(text: "已定稿 \(t.issued)", tint: .green) }
                }
                Spacer()
                if t.count == 0 && t.required {
                    Text("必备 · 待建立").font(.caption).foregroundStyle(Brand.orange)
                }
            }
            ForEach(t.docs) { it in docFile(it, typeLabel: t.label) }
            if t.count > t.docs.count { Text("还有 \(t.count - t.docs.count) 份，在结审里查看").font(.caption2).foregroundStyle(.tertiary) }
        }
    }

    /// 一份文书：像一张文件——左边纸张图标，中间标题和编号 / 更新日期，右边状态
    private func docFile(_ it: SjzDocItem, typeLabel: String) -> some View {
        let tint = statusTint(it.statusLabel)
        let meta = [it.docNo, typeLabel, it.updated.isEmpty ? "" : "更新于 " + it.updated].filter { !$0.isEmpty }.joined(separator: " · ")
        return Button { model.openSjzDoc(project: name, path: it.path) } label: {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color(nsColor: .textBackgroundColor))
                    RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.secondary.opacity(0.25), lineWidth: 1)
                    VStack(spacing: 3) {
                        ForEach(0..<4, id: \.self) { n in
                            Capsule().fill(Color.secondary.opacity(0.3)).frame(width: n == 0 ? 14 : (n == 3 ? 10 : 18), height: 2)
                                .frame(width: 18, alignment: .leading)
                        }
                    }
                    .offset(y: 3)
                    Rectangle().fill(tint.opacity(0.85)).frame(width: 18, height: 3).offset(y: -12)
                }
                .frame(width: 28, height: 36)
                .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
                VStack(alignment: .leading, spacing: 3) {
                    Text(it.title.isEmpty ? it.path : it.title).font(.callout.weight(.medium)).foregroundStyle(.primary).lineLimit(1)
                    Text(meta).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                if !it.statusLabel.isEmpty {
                    Text(it.statusLabel).font(.caption.weight(.medium))
                        .foregroundStyle(tint)
                        .padding(.horizontal, 9).padding(.vertical, 3)
                        .background(tint.opacity(0.12), in: Capsule())
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("在结审里打开")
    }

    private static var capCache: [String: [SjzCapture]] = [:]

    private func loadCaptures() async {
        guard let all = try? await model.sjz.captures(project: name) else { capsLoaded = true; return }
        Self.capCache[name] = all
        let cleared = clearedIds
        let next = all.filter { !cleared.contains($0.id) }
        if next != captures { captures = next }
        capsLoaded = true
        if let sm = try? await model.sjz.summaries(project: name), sm != summaries { summaries = sm }
    }

    // 「清除记录」：只是不再在拾忆这份列表里显示（记下已清除的记录编号，存在本机），结审里的文件原样保留
    private var clearedKey: String { "sjz.clearedCaptures." + name }
    private var clearedIds: Set<String> { Set(UserDefaults.standard.stringArray(forKey: clearedKey) ?? []) }

    private func clearCaptureRecords() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "清除拾忆里的这些记录？"
        alert.informativeText = "只清除拾忆这里「来自拾忆」的列表（共 \(captures.count) 条），结审里的证据、法规、线索等文件不会被删除，也不受影响。"
        let ok = alert.addButton(withTitle: "清除")
        ok.hasDestructiveAction = true
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        UserDefaults.standard.set(Array(clearedIds.union(captures.map(\.id))), forKey: clearedKey)
        captures = []
        capKind = ""
        capQuery = ""
        model.showNotice("已清除拾忆里的记录，结审里的文件没有动")
    }

    private var filteredCaptures: [SjzCapture] {
        let q = capQuery.trimmed.lowercased()
        let cutoff: Date? = capDays > 0 ? Calendar.current.date(byAdding: .day, value: -capDays, to: Calendar.current.startOfDay(for: Date())) : nil
        return captures.filter { c in
            (capKind.isEmpty || c.kind == capKind)
                && (q.isEmpty || "\(c.title) \(c.summary) \(c.source)".lowercased().contains(q))
                && (cutoff == nil || (c.date ?? .distantPast) >= cutoff!)
        }
    }

    @ViewBuilder fileprivate var capturesCard: some View {
        if capsLoaded {
            let list = filteredCaptures
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        SectionTitle(text: "来自拾忆", count: captures.count)
                        Spacer()
                        Button { newList = true } label: { Label("新建资料清单", systemImage: "plus") }
                            .buttonStyle(.borderless).font(.caption).foregroundStyle(.secondary)
                            .help("写进结审文书中心的「资料清单」，证据和想法可以关联到它")
                        Button { clearCaptureRecords() } label: { Label("清除记录", systemImage: "trash") }
                            .buttonStyle(.borderless).font(.caption).foregroundStyle(.secondary)
                            .help("只清除拾忆里的这份列表，不删除结审里的文件")
                        Menu {
                            // 直接平铺成一级菜单（Picker 放在 Menu 里会再套一层「时间」二级菜单）
                            ForEach([(0, "全部时间"), (1, "今天"), (7, "近 7 天"), (30, "近 30 天")], id: \.0) { d, label in
                                Button { capDays = d } label: {
                                    if capDays == d { Label(label, systemImage: "checkmark") } else { Text(label) }
                                }
                            }
                        } label: {
                            Label(capDays == 0 ? "全部时间" : capDays == 1 ? "今天" : "近 \(capDays) 天", systemImage: "calendar")
                        }
                        .menuStyle(.borderlessButton).fixedSize().font(.caption)
                    }
                    HStack(spacing: 6) {
                        ForEach([("", "全部"), ("idea", "想法"), ("evidence", "证据"), ("regulation", "法规"), ("clue", "线索"), ("datalist", "资料清单")], id: \.0) { k, label in
                            let n = k.isEmpty ? captures.count : captures.filter { $0.kind == k }.count
                            Button { capKind = k } label: {
                                Text(n > 0 ? "\(label) \(n)" : label)
                                    .font(.caption.weight(.medium))
                                    .padding(.horizontal, 10).padding(.vertical, 4)
                                    .background(capKind == k ? Brand.orange.opacity(0.16) : Color.primary.opacity(0.06), in: Capsule())
                                    .foregroundStyle(capKind == k ? Brand.orange : .secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        Spacer(minLength: 8)
                        HStack(spacing: 4) {
                            Image(systemName: "magnifyingglass").font(.caption).foregroundStyle(.tertiary)
                            TextField("搜索", text: $capQuery).textFieldStyle(.plain).font(.callout).frame(width: 110)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }
                    if list.isEmpty {
                        Text("没有符合条件的记录").font(.callout).foregroundStyle(.tertiary).padding(.vertical, 4)
                    }
                    let groups = Self.captureGroups(list)
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(groups.prefix(50)) { g in
                            VStack(alignment: .leading, spacing: 0) {
                                captureRow(g.top, kids: g.kids)
                                if !g.kids.isEmpty, isGroupOpen(g.id) {
                                    HStack(alignment: .top, spacing: 0) {
                                        // 追加记录挂在证据下面：左侧竖线从证据图标正下方连下来
                                        Rectangle().fill(Color.blue.opacity(0.22)).frame(width: 2)
                                            .padding(.leading, 20).padding(.trailing, 10).padding(.vertical, 1)
                                        VStack(alignment: .leading, spacing: 0) {
                                            ForEach(Array(g.kids.enumerated()), id: \.element.id) { i, k in captureRow(k, child: true, seq: i + 1) }
                                        }
                                    }
                                    .padding(.bottom, 2)
                                }
                            }
                        }
                    }
                    if groups.count > 50 { Text("还有 \(groups.count - 50) 项，用上面的筛选缩小范围").font(.caption).foregroundStyle(.tertiary) }
                }
            }
        }
    }

    fileprivate struct CapGroup: Identifiable {
        let top: SjzCapture
        let kids: [SjzCapture]
        let dayLabel: String
        let showDay: Bool
        let isFirst: Bool
        var id: String { top.id }
    }

    /// 追加记录归到它的证据下面；证据按最近一次动静排序，并按天分段（今天 / 昨天 / 日期）
    fileprivate static func captureGroups(_ list: [SjzCapture]) -> [CapGroup] {
        let ids = Set(list.map(\.id))
        var kids: [String: [SjzCapture]] = [:]
        var tops: [SjzCapture] = []
        for c in list {
            if !c.parentId.isEmpty, ids.contains(c.parentId) { kids[c.parentId, default: []].append(c) }
            // 想法关联了线索：像证据的追加一样挂在线索下面
            else if c.kind == "idea", let clue = c.clueIds.first(where: { ids.contains($0) }) { kids[clue, default: []].append(c) }
            else { tops.append(c) }
        }
        func latest(_ c: SjzCapture) -> Date {
            ([c.date] + (kids[c.id] ?? []).map(\.date)).compactMap { $0 }.max() ?? .distantPast
        }
        let order = Dictionary(uniqueKeysWithValues: tops.enumerated().map { ($1.id, $0) })
        tops.sort { let a = latest($0), b = latest($1); return a != b ? a > b : order[$0.id]! < order[$1.id]! }
        var out: [CapGroup] = []
        var lastDay = ""
        for t in tops {
            let ks = (kids[t.id] ?? []).sorted { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }
            let day = dayLabel(latest(t))
            out.append(CapGroup(top: t, kids: ks, dayLabel: day, showDay: day != lastDay, isFirst: out.isEmpty))
            lastDay = day
        }
        return out
    }

    fileprivate static func dayLabel(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "今天" }
        if cal.isDateInYesterday(d) { return "昨天" }
        let f = DateFormatter()
        f.dateFormat = cal.isDate(d, equalTo: Date(), toGranularity: .year) ? "M 月 d 日" : "yyyy 年 M 月 d 日"
        return f.string(from: d)
    }

    static func kindTint(_ k: String) -> Color {
        switch k {
        case "regulation", "summary": return .indigo
        case "clue": return .pink
        case "idea": return .purple
        case "data", "datalist": return .teal
        default: return Brand.orange
        }
    }

    /// 线索关联的想法 / 证据 / 法规：同一份证据下的追加记录只算一份
    fileprivate static func relatedTo(_ clue: SjzCapture, in all: [SjzCapture]) -> [SjzCapture] {
        let isList = clue.kind == "datalist"
        let hit = all.filter { isList ? $0.listIds.contains(clue.id) : ($0.kind != "clue" && $0.clueIds.contains(clue.id)) }
        let ids = Set(hit.map(\.id))
        return hit.filter { $0.parentId.isEmpty || !ids.contains($0.parentId) }
    }

    /// 证据汇编下的追加记录 / 原件默认折叠，点标签展开；搜索时全部展开
    private func isGroupOpen(_ id: String) -> Bool { openGroups.contains(id) || !capQuery.trimmed.isEmpty }

    private func captureRow(_ c: SjzCapture, child: Bool = false, kids: [SjzCapture] = [], seq: Int = 0) -> some View {
        CaptureRowView(c: c, child: child, kids: kids, seq: seq, expanded: isGroupOpen(c.id),
                       toggle: { if openGroups.contains(c.id) { openGroups.remove(c.id) } else { openGroups.insert(c.id) } },
                       related: c.kind == "clue" || c.kind == "datalist" ? Self.relatedTo(c, in: captures) : [],
                       all: captures, preview: { model.openSjzPreview(project: name, capture: $0) }) { model.openSjzEditor(project: name, capture: c) }
        .onHover { inside in
            if inside { hoverCap = c; prefetch(c) } else if hoverCap?.id == c.id { hoverCap = nil }
        }
        .contextMenu {
            Button("快速预览") { model.openSjzPreview(project: name, capture: c) }
            Button("使用便签打开") { model.openSjzAsSticky(project: name, capture: c) }
            if model.sjzCanPin(c) {
                // 钉住后，灵动岛和万能输入保存证据 / 法规 / 线索时直接追加到它，不用再去搜索
                Button(model.sjzIsPinned(c, project: name) ? "取消钉住" : "钉住", systemImage: model.sjzIsPinned(c, project: name) ? "pin.slash" : "pin") {
                    Task { await model.sjzTogglePin(c, project: name) }
                }
            }
            Divider()
            Button("编辑") { model.openSjzEditor(project: name, capture: c) }
            if c.kind == "clue", c.status != "converted" {
                Divider()
                ForEach([("pending", "待核实"), ("verified", "已核实"), ("excluded", "排除")], id: \.0) { st, label in
                    Button(label + (c.status == st ? " ✓" : "")) { Task { await setClue(c, st) } }
                }
            }
            if c.kind == "clue" || c.kind == "idea" {
                Divider()
                if c.kind == "idea" {
                    if c.toClue.isEmpty {
                        Button("转为线索") { Task { await runCapture { try await model.sjz.ideaToClue(project: name, id: c.id) } } }
                    } else {
                        Button("已转为线索 \(c.toClue)") {}.disabled(true)
                    }
                }
                if c.kind == "clue" {
                    if c.status == "converted" {
                        Button("撤回为线索（删除取证单草稿）") { Task { await runCapture { try await model.sjz.clueRevert(project: name, id: c.id) } } }
                    } else {
                        Button("生成取证单草稿") { Task { await runCapture { try await model.sjz.clueToNote(project: name, id: c.id) } } }
                    }
                }
                if c.taskId.isEmpty {
                    Button("转为任务") { Task { await runCapture { try await model.sjz.clueToTask(project: name, id: c.id) } } }
                } else {
                    Button("已转为任务 \(c.taskId)") {}.disabled(true)
                }
            }
            Divider()
            Button("删除…", role: .destructive) { deleting = c }
        }
    }

    private func runCapture(_ work: () async throws -> String) async {
        do {
            let m = try await work()
            model.showNotice(m)
            await model.refreshSjzOverview(force: true)
            await loadCaptures()
        } catch { model.showNotice(error.localizedDescription) }
    }

    private func setClue(_ c: SjzCapture, _ status: String) async {
        do {
            _ = try await model.sjz.updateCapture(project: name, id: c.id, fields: ["status": status])
            await loadCaptures()
        } catch { model.showNotice(error.localizedDescription) }
    }

    private static func timeLabel(_ d: Date?) -> String {
        guard let d else { return "" }
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDateInToday(d) ? "今天 HH:mm" : "MM-dd HH:mm"
        return f.string(from: d)
    }
}

/// 来自拾忆的一条记录：二次编辑并写回结审（正文 / 标题 / 来源 / 关联取证单；线索可改状态、转任务）
struct SjzCaptureEditor: View {
    @EnvironmentObject var model: AppModel
    let project: String
    let capture: SjzCapture
    let onDone: () async -> Void
    let onClose: () -> Void
    private func dismiss() { onClose() }
    /// 所在窗口：打开并排查看时把窗口拉宽，关掉时缩回去
    @State private var win: NSWindow?
    private static let sideWidth: CGFloat = 520

    @State private var title = ""
    @State private var source = ""
    @State private var original = ""
    @State private var status = ""
    @State private var editable = true
    @State private var loaded = false
    @State private var busy = false
    @State private var linkNote: SjzNoteHit?
    @State private var notes: [SjzNoteHit] = []
    @State private var message = ""
    @State private var images: [String: NSImage] = [:]

    @State private var segs: [Seg] = []
    enum PMode: Hashable { case original, text, edit }
    @State private var mode: PMode = .text
    @State private var files: [SjzFile] = []
    @State private var fileSel = ""
    @State private var jumpPage: Int?
    @State private var stale = false

    /// 正文拆成「文字段 / 图片段」混排编辑：图片整行引用 `![说明][imgN]` 单独成块
    struct Seg: Identifiable, Equatable {
        enum Kind { case text, image }
        let id = UUID()
        var kind: Kind
        var text = ""
        var key = ""
        var alt = ""
        /// 汇总里一次摘录的标识（`<!-- excerpt:ID -->`）：每次摘录是一张卡片，编辑时可以单独改 / 删
        var marker = ""
    }

    static func parse(_ md: String) -> [Seg] {
        let re = RX("^!\\[([^\\]]*)\\]\\[(img\\d+)\\]\\s*$")
        let mk = RX("^<!--\\s*excerpt:([\\w-]+)\\s*-->\\s*$")
        var out: [Seg] = []
        var buf: [String] = []
        var marker = ""
        func flush() {
            let t = buf.joined(separator: "\n").trimmed
            if !t.isEmpty { out.append(Seg(kind: .text, text: t, marker: marker)); marker = "" }
            buf = []
        }
        for line in md.components(separatedBy: "\n") {
            if let m = mk.first(in: line.trimmingCharacters(in: .whitespaces)) { flush(); marker = m.group(1); continue }
            if let m = re.first(in: line) { flush(); out.append(Seg(kind: .image, key: m.group(2), alt: m.group(1), marker: marker)); marker = ""; continue }
            buf.append(line)
        }
        flush()
        return out.isEmpty ? [Seg(kind: .text)] : out
    }

    static func join(_ segs: [Seg]) -> String {
        segs.compactMap { s -> String? in
            var body: String
            switch s.kind {
            case .text: body = s.text.trimmed
            case .image: body = "![\(s.alt)][\(s.key)]"
            }
            if body.isEmpty && s.marker.isEmpty { return nil }
            return s.marker.isEmpty ? body : "<!-- excerpt:\(s.marker) -->\n\(body)"
        }.joined(separator: "\n\n")
    }

    private var content: String { Self.join(segs) }

    private var isClue: Bool { capture.kind == "clue" }
    /// 想法：只有正文可改（标题自动取首行），保存时同步改写结审工作日志里的那一条
    private var isIdea: Bool { capture.kind == "idea" }
    private var canLink: Bool { capture.kind == "evidence" || capture.kind == "regulation" }
    /// 证据 / 法规 / 想法都可以关联到线索（线索生成取证单时带入）
    private var canClueLink: Bool { capture.kind == "evidence" || capture.kind == "regulation" || capture.kind == "idea" }
    /// 证据 / 想法可以关联到资料清单
    private var canListLink: Bool { capture.kind == "evidence" || capture.kind == "idea" }
    private var isDatalist: Bool { capture.kind == "datalist" }
    @State private var listIds: [String] = []
    @State private var listList: [SjzCapture] = []
    /// 资料清单的时间（yyyy-MM-dd，空串 = 没有）：要求提供 / 发出 / 收回
    @State private var dueAt = ""
    @State private var sentAt = ""
    @State private var recalledAt = ""
    @State private var times0: [String: String] = [:]
    /// 右侧并排查看的关联材料
    @State private var side: SjzCapture?
    @State private var clueIds: [String] = []
    @State private var clueList: [SjzCapture] = []
    /// 线索：关联到它的想法 / 证据 / 法规
    @State private var related: [SjzCapture] = []

    private func listName(_ id: String) -> String {
        guard let c = listList.first(where: { $0.id == id }) else { return id }
        return "\(c.id) \(c.title.isEmpty ? c.summary : c.title)"
    }

    private func clueName(_ id: String) -> String {
        guard let c = clueList.first(where: { $0.id == id }) else { return id }
        return "\(c.id) \(c.title.isEmpty ? c.summary : c.title)" + (c.status == "converted" ? "（已出取证单）" : "")
    }

    private var mainColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Color.clear.frame(width: 56, height: 1)   // 给窗口左上角的红黄绿按钮让位
                Image(systemName: capture.icon).foregroundStyle(Brand.orange)
                Text("\(capture.kindLabel) · \(capture.id)").font(.headline)
                Spacer()
            }
            if !isIdea {
                field("标题", text: $title)
                field("来源", text: $source)
            }
            if isClue {
                HStack(spacing: 8) {
                    Text("状态").font(.caption).foregroundStyle(.secondary)
                    if capture.status == "converted" {
                        TagChip(text: "已出取证单", tint: .blue)
                        Text("状态请在结审里调整").font(.caption).foregroundStyle(.tertiary)
                    } else {
                        Picker("", selection: $status) {
                            Text("待核实").tag("pending")
                            Text("已核实").tag("verified")
                            Text("排除").tag("excluded")
                        }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 220)
                    }
                    Spacer()
                }
            }
            if isDatalist { timesRow }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(capture.kind == "data" ? "文件" : isDatalist ? "资料明细" : "正文").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if capture.kind != "data", loaded, editable || !files.isEmpty {
                        Picker("", selection: $mode) {
                            if !files.isEmpty { Text(files.contains(where: { $0.role == "original" }) ? "原件" : "出处原件").tag(PMode.original) }
                            Text(textLabel).tag(PMode.text)
                            if editable { Text("编辑").tag(PMode.edit) }
                        }
                        .pickerStyle(.segmented).labelsHidden().frame(width: files.isEmpty ? 120 : 200)
                    }
                }
                if capture.kind == "data" {
                    Text(capture.path).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                } else if !loaded {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 160)
                } else if mode == .original, let f = currentFile {
                    originalPane(f)
                } else if mode == .edit, editable {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) { editBlocks }
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minHeight: 200, maxHeight: .infinity)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                } else {
                    QuickTextPane(content: content, images: images, files: files, pad: 12) { f, page in fileSel = f.id; jumpPage = page; mode = .original }
                        .equatable()
                        .frame(minHeight: 200, maxHeight: .infinity)
                    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            if canLink {
                HStack(spacing: 8) {
                    Text("取证单").font(.caption).foregroundStyle(.secondary)
                    Menu {
                        ForEach(notes) { n in Button([n.no, n.title].filter { !$0.isEmpty }.joined(separator: " ")) { linkNote = n } }
                    } label: {
                        Text(linkNote.map { [$0.no, $0.title].joined(separator: " ") } ?? (capture.noteNo.isEmpty ? "关联到取证单…" : "已关联 \(capture.noteNo)，再关联一份…"))
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                    Spacer()
                }
            }
            if canClueLink {
                HStack(alignment: .top, spacing: 8) {
                    Text("关联线索").font(.caption).foregroundStyle(.secondary).padding(.top, 5)
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(clueIds, id: \.self) { id in
                            HStack(spacing: 6) {
                                Image(systemName: "lightbulb").font(.system(size: 10)).foregroundStyle(Brand.orange)
                                Text(clueName(id)).font(.callout).lineLimit(1)
                                    .onTapGesture { if let c = clueList.first(where: { $0.id == id }) { side = c } }
                                    .help("在右侧并排查看")
                                Button { clueIds.removeAll { $0 == id } } label: {
                                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                                }
                                .buttonStyle(.plain).help("取消关联")
                            }
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Color.primary.opacity(0.06), in: Capsule())
                        }
                        Menu {
                            let rest = clueList.filter { !clueIds.contains($0.id) }
                            if rest.isEmpty { Text("没有可关联的线索") }
                            ForEach(rest) { c in
                                Button("\(c.id) \(c.title.isEmpty ? c.summary : c.title)") { clueIds.append(c.id) }
                            }
                        } label: {
                            Label(clueIds.isEmpty ? "关联到线索…" : "再关联一条…", systemImage: "plus")
                        }
                        .menuStyle(.borderlessButton).fixedSize()
                    }
                    Spacer()
                }
            }
            if isClue || isDatalist, !related.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text("关联材料").font(.caption).foregroundStyle(.secondary)
                        Text("\(related.count)").font(.caption).foregroundStyle(.tertiary)
                        Spacer()
                    }
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(Array(related.enumerated()), id: \.element.id) { i, r in
                                Button {
                                    withAnimation(.easeOut(duration: 0.15)) { side = side?.id == r.id ? nil : r }
                                } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: r.icon).font(.system(size: 10, weight: .semibold))
                                            .foregroundStyle(SjzProjectDetailView.kindTint(r.kind))
                                            .frame(width: 20, height: 20)
                                            .background(SjzProjectDetailView.kindTint(r.kind).opacity(0.14), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                                        Text(r.kindLabel).font(.caption).foregroundStyle(.secondary).frame(width: 28, alignment: .leading)
                                        Text((r.title.isEmpty ? r.summary : r.title).mdPlain).font(.callout).lineLimit(1).truncationMode(.tail)
                                        Spacer(minLength: 8)
                                        Image(systemName: side?.id == r.id ? "rectangle.righthalf.inset.filled" : "chevron.right")
                                            .font(.system(size: 9, weight: .semibold)).foregroundStyle(side?.id == r.id ? Brand.orange : Color.secondary.opacity(0.6))
                                    }
                                    .padding(.horizontal, 10).padding(.vertical, 6)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(side?.id == r.id ? Brand.orange.opacity(0.08) : Color.clear)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain).help("在右侧并排查看")
                                if i < related.count - 1 { Divider().padding(.leading, 40).opacity(0.6) }
                            }
                        }
                    }
                    .frame(maxHeight: min(CGFloat(related.count) * 34, 136))
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
            if canListLink {
                HStack(alignment: .top, spacing: 8) {
                    Text("关联资料清单").font(.caption).foregroundStyle(.secondary).padding(.top, 5)
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(listIds, id: \.self) { id in
                            HStack(spacing: 6) {
                                Image(systemName: "list.clipboard").font(.system(size: 10)).foregroundStyle(.teal)
                                Text(listName(id)).font(.callout).lineLimit(1)
                                    .onTapGesture { if let c = listList.first(where: { $0.id == id }) { side = c } }
                                    .help("在右侧并排查看")
                                Button { listIds.removeAll { $0 == id } } label: {
                                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                                }
                                .buttonStyle(.plain).help("取消关联")
                            }
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Color.primary.opacity(0.06), in: Capsule())
                        }
                        Menu {
                            let rest = listList.filter { !listIds.contains($0.id) }
                            if rest.isEmpty { Text("还没有资料清单，先在项目页新建") }
                            ForEach(rest) { c in
                                Button("\(c.id) \(c.title.isEmpty ? c.summary : c.title)") { listIds.append(c.id) }
                            }
                        } label: {
                            Label(listIds.isEmpty ? "关联到资料清单…" : "再关联一份…", systemImage: "plus")
                        }
                        .menuStyle(.borderlessButton).fixedSize()
                    }
                    Spacer()
                }
            }
            if !message.isEmpty { Text(message).font(.caption).foregroundStyle(Brand.orange) }
            HStack {
                Button("在结审里打开") { model.openSjzCapture(project: project, capture) }.buttonStyle(.borderless).font(.callout)
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存并写回") { Task { await save() } }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).disabled(busy || !dirty || stale)
            }
        }
        .padding(EdgeInsets(top: 9, leading: 20, bottom: 20, trailing: 20))
        .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            mainColumn
            if let s = side {
                Divider()
                SjzQuickLook(api: model.sjz, project: project, capture: s, size: CGSize(width: 520, height: 0), embedded: true,
                             onClose: { side = nil },
                             onEdit: { model.openSjzEditor(project: project, capture: s) })
                    .id(s.id)
                    .frame(maxHeight: .infinity)
            }
        }
        .frame(minHeight: 440)
        .background(WinGrab { win = $0 })
        .onChange(of: side?.id) { old, new in
            guard let w = win, (old == nil) != (new == nil) else { return }
            var f = w.frame
            let dx = Self.sideWidth + 1
            if new != nil {
                f.size.width += dx
                if let vis = w.screen?.visibleFrame, f.maxX > vis.maxX { f.origin.x = max(vis.minX, vis.maxX - f.width) }
            } else { f.size.width = max(w.contentMinSize.width, f.width - dx) }
            w.setFrame(f, display: true, animate: true)
        }
        .task {
            title = capture.title
            source = capture.source
            status = capture.status
            clueIds = capture.clueIds
            listIds = capture.listIds
            if capture.kind != "data" {
                // 先用悬停时预取的缓存立刻画出来，再在后台读一次最新的；已经开始改了就不覆盖，只提示
                if let c = SjzDetailStore.cached(project: project, id: capture.id) { apply(c, first: true); loaded = true }
                if let d = await SjzDetailStore.load(api: model.sjz, project: project, id: capture.id) {
                    if !loaded { apply(d, first: true) }
                    else if d.content != original || d.files != files {
                        if content == original { apply(d, first: false) } else { stale = true; message = "结审里这一项刚有更新，请取消后重新打开再改，以免覆盖" }
                    }
                }
            }
            loaded = true
            // 取证单 / 线索列表只有点菜单才用到，放在后面读，不挡着正文
            notes = (try? await model.sjz.searchNotes("")) ?? []
            if canClueLink { clueList = (try? await model.sjz.captures(project: project, kind: "clue", limit: 100)) ?? [] }
            if canListLink { listList = (try? await model.sjz.captures(project: project, kind: "datalist", limit: 100)) ?? [] }
            if isClue || isDatalist, let all = try? await model.sjz.captures(project: project, limit: 300) { related = SjzProjectDetailView.relatedTo(capture, in: all) }
        }
    }

    private func apply(_ d: SjzDetailStore.Detail, first: Bool) {
        segs = Self.parse(d.content); original = Self.join(segs); editable = d.editable
        images = d.images
        files = d.files
        if isDatalist, first {
            times0 = d.times
            dueAt = d.times["dueAt"] ?? ""; sentAt = d.times["sentAt"] ?? ""; recalledAt = d.times["recalledAt"] ?? ""
        }
        if first {
            fileSel = d.files.first?.id ?? ""
            mode = Self.defaultMode(content: d.content, files: d.files)
        } else if !d.files.contains(where: { $0.id == fileSel }) { fileSel = d.files.first?.id ?? "" }
    }

    private var dirty: Bool {
        (title != capture.title || source != capture.source || (editable && loaded && content != original)
            || (isClue && status != capture.status) || linkNote != nil || (canClueLink && clueIds != capture.clueIds) || (canListLink && listIds != capture.listIds) || timesChanged)
    }

    private var timesChanged: Bool {
        isDatalist && loaded && (dueAt != (times0["dueAt"] ?? "") || sentAt != (times0["sentAt"] ?? "") || recalledAt != (times0["recalledAt"] ?? ""))
    }

    /// 资料清单的三个时间：要求提供日期可以随时改；填发出 / 收回日期会同时把状态流转为已发出 / 已收回，清除则撤销
    private var timesRow: some View {
        HStack(spacing: 8) {
            Text("时间").font(.caption).foregroundStyle(.secondary).frame(width: 34, alignment: .leading)
            DayPickerButton(title: "要求提供", icon: "calendar.badge.clock", value: $dueAt)
            DayPickerButton(title: "发出", icon: "paperplane", value: $sentAt)
            if !sentAt.isEmpty { DayPickerButton(title: "收回", icon: "tray.and.arrow.down", value: $recalledAt) }
            Spacer()
            Text(recalledAt.isEmpty ? (sentAt.isEmpty ? "草稿" : "已发出，等对方提供") : "已收回").font(.caption).foregroundStyle(.tertiary)
        }
        .onChange(of: sentAt) { _, v in if v.isEmpty { recalledAt = "" } }
    }

    private var currentFile: SjzFile? { files.first(where: { $0.id == fileSel }) ?? files.first }
    private var textLabel: String {
        if files.isEmpty { return "预览" }
        if !files.contains(where: { $0.role == "original" }) { return "摘录" }
        return content.contains("<!-- excerpt:") ? "汇总" : "文字层"
    }

    /// 有原件时默认直接看原件；只有「汇总里既有原件又有自己摘录的文字」才先看汇总
    static func defaultMode(content: String, files: [SjzFile]) -> PMode {
        if !files.contains(where: { $0.role == "original" }) { return .text }
        if !content.contains("<!-- excerpt:") { return .original }
        let own = content.components(separatedBy: "\n").contains { raw in
            let t = raw.trimmingCharacters(in: .whitespaces)
            if t.isEmpty || t.hasPrefix("<!--") || t.hasPrefix("#") || t.hasPrefix("原文件：") || t.hasPrefix("文字层：") { return false }
            if t.hasPrefix(">") { let q = t.drop(while: { $0 == ">" || $0 == " " }); return !(q.hasPrefix("摘录于") || q.hasPrefix("来源：") || q.hasPrefix("出处：") || q.hasPrefix("备注：")) }
            return true
        }
        return own ? .text : .original
    }

    @ViewBuilder private func originalPane(_ f: SjzFile) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if files.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(files) { x in
                            Button { fileSel = x.id; jumpPage = nil } label: {
                                Label(x.name, systemImage: x.icon).font(.caption).lineLimit(1)
                                    .padding(.horizontal, 9).padding(.vertical, 4)
                                    .background(x.id == f.id ? Brand.orange.opacity(0.18) : Color.primary.opacity(0.06), in: Capsule())
                                    .foregroundStyle(x.id == f.id ? Brand.orange : .secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            SjzFilePreview(file: f, page: jumpPage)
                .frame(maxWidth: .infinity, minHeight: 240, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.primary.opacity(0.1), lineWidth: 0.5))
            HStack(spacing: 12) {
                Image(systemName: f.icon).foregroundStyle(Brand.orange)
                Text(f.name).font(.callout).lineLimit(1).truncationMode(.middle)
                Text(f.sizeLabel).font(.caption).foregroundStyle(.tertiary)
                Spacer()
                Button("用默认应用打开") { NSWorkspace.shared.open(f.url) }
                Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([f.url]) }
            }
            .buttonStyle(.borderless).font(.caption)
        }
    }

    /// 这一段属于哪次摘录：往前找到最近的带标识的那一段
    private func isFileBlock(_ seg: Seg) -> Bool { seg.kind == .text && seg.text.contains("原文件：[[") }

    private func cardTitle(_ seg: Seg, _ n: Int) -> String {
        for line in seg.text.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("##") { return String(t.drop(while: { $0 == "#" || $0 == " " })) }
        }
        return seg.kind == .image ? "截图" : "摘录 \(n)"
    }

    /// 删掉一次摘录：从这一段起到下一个带标识的段落之前
    private func removeCard(_ seg: Seg) {
        guard let i = segs.firstIndex(where: { $0.id == seg.id }) else { return }
        var j = i + 1
        while j < segs.count, segs[j].marker.isEmpty { j += 1 }
        segs.removeSubrange(i..<j)
        if segs.isEmpty { segs = [Seg(kind: .text)] }
    }

    @ViewBuilder private var editBlocks: some View {
        ForEach($segs) { $seg in
            if !seg.marker.isEmpty {
                let n = (segs.filter { !$0.marker.isEmpty }.firstIndex(where: { $0.id == seg.id }) ?? 0) + 1
                HStack(spacing: 8) {
                    Image(systemName: isFileBlock(seg) ? "paperclip" : "quote.opening").font(.system(size: 11)).foregroundStyle(Brand.orange)
                    Text(cardTitle(seg, n)).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Spacer()
                    if isFileBlock(seg) {
                        Text("原件请到结审里删除").font(.caption2).foregroundStyle(.tertiary)
                    } else {
                        Button { removeCard(seg) } label: { Label("删除这条摘录", systemImage: "trash") }
                            .buttonStyle(.borderless).font(.caption).foregroundStyle(.red.opacity(0.85))
                    }
                }
                .padding(.top, 6)
                Divider()
            }
            switch seg.kind {
            case .text:
                if isFileBlock(seg) {
                    Text(seg.text).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled)
                        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                } else {
                    // 不用 TextField(axis: .vertical)：它的回车是「提交」而不是换行，会把文字全选
                    SegTextEditor(text: $seg.text)
                }
            case .image:
                ZStack(alignment: .topTrailing) {
                    imageView(seg)
                    Button { removeImage(seg) } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 17)).foregroundStyle(.white, .black.opacity(0.55))
                    }
                    .buttonStyle(.plain).padding(6).help("从正文移除这张图片（文件里的图片数据仍保留）")
                }
            }
        }
        HStack(spacing: 10) {
            Button { segs.append(Seg(kind: .text)) } label: { Label("加一段文字", systemImage: "text.append") }
        }
        .buttonStyle(.borderless).font(.caption)
    }

    /// 删图片：如果它带着摘录标识，标识交给下一段，不然这次摘录的编号会丢
    private func removeImage(_ seg: Seg) {
        guard let i = segs.firstIndex(where: { $0.id == seg.id }) else { return }
        let mk = segs[i].marker
        segs.remove(at: i)
        if !mk.isEmpty, i < segs.count, segs[i].marker.isEmpty { segs[i].marker = mk }
    }

    @ViewBuilder private func imageView(_ seg: Seg) -> some View {
        if let img = images[seg.key] {
            VStack(alignment: .leading, spacing: 3) {
                Image(nsImage: img).resizable().scaledToFit()
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .onTapGesture { NSWorkspace.shared.open(Self.tempFile(img, key: seg.key)) }
                    .help("点击用预览打开原图")
            }
        } else {
            Label("图片 \(seg.key) 不可用", systemImage: "photo").font(.caption).foregroundStyle(.tertiary)
        }
    }

    private static func tempFile(_ img: NSImage, key: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("shiyi-\(key)-\(UUID().uuidString.prefix(6)).png")
        if let t = img.tiffRepresentation, let rep = NSBitmapImageRep(data: t), let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: url) }
        return url
    }

    private func field(_ label: String, text: Binding<String>) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 34, alignment: .leading)
            TextField("", text: text).textFieldStyle(.roundedBorder)
        }
    }

    private func run(_ work: () async throws -> String) async {
        busy = true
        defer { busy = false }
        do {
            message = ""
            let m = try await work()
            model.showNotice(m)
            await model.refreshSjzOverview(force: true)
            if isDatalist { AppModel.lastDatalistSync = .distantPast; await model.syncDatalistReminders() }
            await onDone()
            dismiss()
        } catch { message = error.localizedDescription }
    }

    private func save() async {
        var f: JSON = [:]
        if title != capture.title { f["title"] = title }
        if source != capture.source { f["source"] = source }
        if editable, loaded, content != original { f["content"] = content }
        if isClue, status != capture.status { f["status"] = status }
        if let linkNote { f["linkNote"] = linkNote.path }
        if canClueLink, clueIds != capture.clueIds { f["clueIds"] = clueIds }
        if canListLink, listIds != capture.listIds { f["listIds"] = listIds }
        if timesChanged {
            if dueAt != (times0["dueAt"] ?? "") { f["dueDate"] = dueAt }
            if sentAt != (times0["sentAt"] ?? "") { f["sentAt"] = sentAt }
            if recalledAt != (times0["recalledAt"] ?? "") { f["recalledAt"] = recalledAt }
        }
        guard !f.isEmpty else { dismiss(); return }
        await run {
            let m = try await model.sjz.updateCapture(project: project, id: capture.id, fields: f)
            SjzDetailStore.forget(project: project, id: capture.id)
            return m
        }
    }
}



/// 结审记录编辑里的一段文字：真正的多行输入框（回车换行），带 Markdown 边写边预览和格式快捷键
private struct SegTextEditor: View {
    @Binding var text: String
    @State private var h: CGFloat = 0

    var body: some View {
        ComposerTextView(text: $text, contentHeight: $h, markdown: true, fontSize: 13, autoFocus: false)
            .frame(height: max(h + 4, 44))
            .padding(8)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

/// 选日期的小按钮：点开是一个小日历，可选任意一天，下面有「今天 / 明天 / 下周一」快捷项。value 为 yyyy-MM-dd，空串 = 没设
struct DayPickerButton: View {
    let title: String
    let icon: String
    @Binding var value: String
    @State private var open = false

    private var label: String { value.isEmpty ? title : "\(title) \(value.dropFirst(5))" }

    var body: some View {
        Button { open = true } label: {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 11))
                Text(label)
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(value.isEmpty ? Color.secondary : Brand.orange)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(value.isEmpty ? Color.primary.opacity(0.06) : Brand.orange.opacity(0.14), in: Capsule())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            DayPickerCalendar(selected: value, title: title) { picked in
                value = picked
                open = false
            }
        }
    }
}

/// 自绘的小日历：月份切换、今天描边、选中橙色实心圆，周一在最前
private struct DayPickerCalendar: View {
    let selected: String
    let title: String
    let onPick: (String) -> Void

    @State private var month: Date
    @State private var hovered: String?

    private static let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.firstWeekday = 2
        return c
    }()
    private static let titleFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy年M月"
        return f
    }()

    init(selected: String, title: String, onPick: @escaping (String) -> Void) {
        self.selected = selected
        self.title = title
        self.onPick = onPick
        let base = Day.parse(selected) ?? Date()
        let c = Self.cal
        _month = State(initialValue: c.date(from: c.dateComponents([.year, .month], from: base)) ?? base)
    }

    private var cells: [Date] {
        let c = Self.cal
        let offset = (c.component(.weekday, from: month) + 5) % 7
        let start = c.date(byAdding: .day, value: -offset, to: month) ?? month
        return (0..<42).compactMap { c.date(byAdding: .day, value: $0, to: start) }
    }

    var body: some View {
        let today = Day.today()
        VStack(spacing: 10) {
            HStack(spacing: 4) {
                Text(Self.titleFmt.string(from: month)).font(.system(size: 14, weight: .semibold))
                Spacer()
                navButton("chevron.left") { shift(-1) }
                Button { month = firstOfMonth(Date()) } label: {
                    Circle().fill(Brand.orange.opacity(0.7)).frame(width: 6, height: 6).frame(width: 22, height: 22).contentShape(Rectangle())
                }
                .buttonStyle(.plain).help("回到本月")
                navButton("chevron.right") { shift(1) }
            }
            .padding(.horizontal, 2)

            VStack(spacing: 2) {
                HStack(spacing: 0) {
                    ForEach(["一", "二", "三", "四", "五", "六", "日"], id: \.self) { w in
                        Text(w).font(.system(size: 11)).foregroundStyle(.tertiary).frame(maxWidth: .infinity)
                    }
                }
                let days = cells
                ForEach(0..<6, id: \.self) { row in
                    HStack(spacing: 0) {
                        ForEach(0..<7, id: \.self) { col in dayCell(days[row * 7 + col], today: today) }
                    }
                }
            }

            Divider().opacity(0.6)
            HStack(spacing: 6) {
                chip("今天") { onPick(today) }
                chip("明天") { onPick(Day.add(today, days: 1)) }
                chip("下周一") { onPick(nextMonday(today)) }
                Spacer(minLength: 0)
                if !selected.isEmpty {
                    Button { onPick("") } label: { Text("清除").font(.caption.weight(.medium)).foregroundStyle(.red.opacity(0.85)) }
                        .buttonStyle(.plain)
                }
            }
        }
        .padding(14)
        .frame(width: 268)
    }

    private func dayCell(_ d: Date, today: String) -> some View {
        let c = Self.cal
        let key = Day.string(d)
        let inMonth = c.isDate(d, equalTo: month, toGranularity: .month)
        let isSel = key == selected
        let isToday = key == today
        return Button { onPick(key) } label: {
            Text("\(c.component(.day, from: d))")
                .font(.system(size: 13, weight: isSel || isToday ? .semibold : .regular))
                .foregroundStyle(isSel ? Color.white : isToday ? Brand.orange : inMonth ? Color.primary : Color.secondary.opacity(0.4))
                .frame(width: 32, height: 32)
                .background(Circle().fill(isSel ? Brand.orange : (hovered == key ? Brand.orange.opacity(0.14) : Color.clear)))
                .overlay(Circle().strokeBorder(Brand.orange.opacity(0.7), lineWidth: isToday && !isSel ? 1.2 : 0))
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 ? key : (hovered == key ? nil : hovered) }
    }

    private func navButton(_ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                .frame(width: 22, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func chip(_ text: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text).font(.caption.weight(.medium)).foregroundStyle(Brand.orange)
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(Brand.orange.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func shift(_ n: Int) {
        month = Self.cal.date(byAdding: .month, value: n, to: month) ?? month
    }

    private func firstOfMonth(_ d: Date) -> Date {
        let c = Self.cal
        return c.date(from: c.dateComponents([.year, .month], from: d)) ?? d
    }

    private func nextMonday(_ today: String) -> String {
        let wd = Self.cal.component(.weekday, from: Day.parse(today) ?? Date())  // 1 = 周日
        let n = (9 - wd) % 7
        return Day.add(today, days: n == 0 ? 7 : n)
    }
}


/// 「来自拾忆」里的一行（紧凑两行）：标题 + 标签 + 时间；第二行是摘要（和标题重复时不显示）和来源
/// 列表行上的关联标签：点一下弹出关联的那几条，再点一条就预览它
private struct RelChip: View {
    let text: String
    let tint: Color
    let items: [SjzCapture]
    let pick: (SjzCapture) -> Void
    @State private var open = false
    @State private var hoverId: String?

    var body: some View {
        HStack(spacing: 3) {
            Text(text)
            if !items.isEmpty { Image(systemName: "eye").font(.system(size: 8, weight: .bold)).opacity(0.7) }
        }
        .font(.caption2.weight(.medium)).foregroundStyle(tint)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(tint.opacity(0.12), in: Capsule())
        .fixedSize()
        .contentShape(Capsule())
        .onTapGesture { if !items.isEmpty { open = true } }
        .help(items.isEmpty ? "" : "点一下预览关联的内容")
        .popover(isPresented: $open, arrowEdge: .bottom) { list }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("关联 \(items.count) 项 · 点一条预览").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 6)
            Divider().opacity(0.6)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(items) { r in
                        let t = SjzProjectDetailView.kindTint(r.kind)
                        Button { open = false; pick(r) } label: {
                            HStack(spacing: 8) {
                                Image(systemName: r.icon).font(.system(size: 10, weight: .semibold)).foregroundStyle(t)
                                    .frame(width: 22, height: 22).background(t.opacity(0.14), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                                VStack(alignment: .leading, spacing: 1) {
                                    Text((r.title.isEmpty ? r.summary : r.title).mdPlain).font(.system(size: 12.5, weight: .medium)).foregroundStyle(.primary).lineLimit(1)
                                    Text("\(r.kindLabel) · \(r.id)").font(.system(size: 10.5)).foregroundStyle(.tertiary)
                                }
                                Spacer(minLength: 6)
                                if !r.statusLabel.isEmpty { Text(r.statusLabel).font(.system(size: 10.5)).foregroundStyle(.secondary) }
                            }
                            .padding(.horizontal, 12).padding(.vertical, 5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(hoverId == r.id ? Color.primary.opacity(0.06) : Color.clear)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .onHover { hoverId = $0 ? r.id : (hoverId == r.id ? nil : hoverId) }
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 300)
        }
        .frame(width: 320)
    }
}

private struct CaptureRowView: View {
    let c: SjzCapture
    let child: Bool
    let kids: [SjzCapture]
    /// 在父项下面的第几条追加（0 = 沿用编号后缀）
    var seq = 0
    var expanded = false
    var toggle: () -> Void = {}
    var related: [SjzCapture] = []
    /// 本项目全部记录（标签点开时按编号找关联的那几条）和「预览」动作
    var all: [SjzCapture] = []
    var preview: (SjzCapture) -> Void = { _ in }
    let tap: () -> Void
    @State private var hover = false

    private func linked(_ ids: [String]) -> [SjzCapture] { all.filter { ids.contains($0.id) } }

    /// 汇编下的内容：「2 条追加 · 3 个原件」，点一下展开 / 折叠
    private var kidsChip: some View {
        let files = kids.filter { !$0.originals.isEmpty }.count
        let ideas = kids.filter { $0.kind == "idea" }.count
        let adds = kids.count - files - ideas
        let text = [adds > 0 ? "\(adds) 条追加" : "", ideas > 0 ? "\(ideas) 条想法" : "", files > 0 ? "\(files) 个原件" : ""].filter { !$0.isEmpty }.joined(separator: " · ")
        return HStack(spacing: 3) {
            Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 8, weight: .bold))
            Text(text)
        }
        .font(.caption2.weight(.medium)).foregroundStyle(.blue)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(Color.blue.opacity(0.12), in: Capsule())
        .fixedSize()
        .contentShape(Capsule())
        .onTapGesture { toggle() }
        .help(expanded ? "收起" : "展开追加记录和原件")
    }

    /// 「关联 想法 2 · 证据 3 · 法规 1」
    private var relatedText: String {
        let parts = [("idea", "想法"), ("evidence", "证据"), ("regulation", "法规")].compactMap { k, l -> String? in
            let n = related.filter { $0.kind == k }.count
            return n > 0 ? "\(l) \(n)" : nil
        }
        return parts.isEmpty ? "" : "关联 " + parts.joined(separator: " · ")
    }

    private var tint: Color { SjzProjectDetailView.kindTint(c.kind) }
    private var title: String { (c.title.isEmpty ? c.summary : c.title).mdPlain }
    private var seqText: String { seq > 0 ? "\(seq)" : (c.id.split(separator: ".").last.map(String.init) ?? "") }
    /// 想法挂在线索下面：和父项类型不同，要写出自己的类型和编号
    private var crossKind: Bool { child && c.parentId.isEmpty }
    private var time: String {
        guard let d = c.date else { return "" }
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDateInToday(d) ? "今天 HH:mm" : "MM-dd HH:mm"
        return f.string(from: d)
    }
    /// 摘要：去掉「追加到 E-xxxx ·」前缀；只是标题的重复或延续时不显示
    private var summary: String {
        var s = c.summary
        if !c.parentId.isEmpty { s = s.replacingOccurrences(of: "追加到 \(c.parentId) · ", with: "") }
        s = Self.maskFiles(s).mdPlain
        let t = c.title.mdPlain
        guard !s.isEmpty, !t.isEmpty, s != t, !s.hasPrefix(t), !t.hasPrefix(s) else { return "" }
        return s
    }
    /// 文件名换成文件类型（PDF / Word …），不展示具体文件名
    private static let fileExt = try! NSRegularExpression(pattern: "[^\\s·（）、，,]+\\.(pdf|docx|doc|xlsx|xls|pptx|ppt|png|jpe?g|gif|webp|md|txt|csv)", options: .caseInsensitive)
    private static func typeName(_ ext: String) -> String {
        switch ext.lowercased() {
        case "pdf": return "PDF"
        case "doc", "docx": return "Word"
        case "xls", "xlsx", "csv": return "Excel"
        case "ppt", "pptx": return "PPT"
        case "png", "jpg", "jpeg", "gif", "webp": return "图片"
        default: return ext.uppercased()
        }
    }
    private static func maskFiles(_ t: String) -> String {
        var out = t
        for m in fileExt.matches(in: t, range: NSRange(t.startIndex..., in: t)).reversed() {
            guard let r = Range(m.range, in: out), let e = Range(m.range(at: 1), in: t) else { continue }
            out.replaceSubrange(r, with: typeName(String(t[e])))
        }
        return out
    }
    /// 来源：自己（拾忆）不用写出来；文件名只显示文件类型，网站、应用名照常显示
    private var source: String { c.source == "拾忆" ? "" : Self.maskFiles(c.source) }

    private var hasAttrs: Bool { !child || crossKind || !source.isEmpty || !c.editedAt.isEmpty || !summary.isEmpty }

    var body: some View {
        Button(action: tap) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: c.icon)
                    .font(.system(size: child ? (hasAttrs ? 9 : 8) : 11, weight: .semibold)).foregroundStyle(tint)
                    .frame(width: child ? (hasAttrs ? 18 : 15) : 22, height: child ? (hasAttrs ? 18 : 15) : 22)
                    .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    // 第一行：标题 + 流转与关系（追加、状态、转成的线索 / 任务 / 取证单）+ 时间
                    HStack(spacing: 5) {
                        Text(title).font(.callout.weight(child ? .regular : .semibold)).lineLimit(1)
                        if child { TagChip(text: "追加 #\(seqText)", tint: .blue).fixedSize() }
                        if !kids.isEmpty { kidsChip }
                        if !c.statusLabel.isEmpty {
                            TagChip(text: c.statusLabel, tint: c.status == "verified" ? .green : c.status == "excluded" ? .gray : Brand.orange).fixedSize()
                        }
                        if !relatedText.isEmpty { RelChip(text: relatedText, tint: c.kind == "datalist" ? .teal : .pink, items: related, pick: preview) }
                        if !c.toClue.isEmpty { RelChip(text: "→ 线索 \(c.toClue)", tint: .purple, items: linked([c.toClue]), pick: preview) }
                        if !c.clueIds.isEmpty, !crossKind { RelChip(text: "线索 \(c.clueIds.joined(separator: "、"))", tint: .pink, items: linked(c.clueIds), pick: preview) }
                        if !c.listIds.isEmpty { RelChip(text: "资料清单 \(c.listIds.joined(separator: "、"))", tint: .teal, items: linked(c.listIds), pick: preview) }
                        if !c.taskId.isEmpty { TagChip(text: "任务 \(c.taskId)", tint: .teal).fixedSize() }
                        if !c.noteNo.isEmpty { TagChip(text: "取证单 \(c.noteNo)", tint: .indigo).fixedSize() }
                        Spacer(minLength: 6)
                        Text(time).font(.caption2).monospacedDigit().foregroundStyle(.tertiary).fixedSize()
                    }
                    // 第二行：这一条自己的属性（类型、编号、文件类型 / 来源、是否编辑过）+ 摘要
                    // 子项（追加记录）不重复写它作为证据的类型和编号；没有属性时整行不显示
                    if hasAttrs {
                        HStack(spacing: 5) {
                            if !child || crossKind { TagChip(text: c.kindLabel, tint: tint).fixedSize() }
                            if !child || crossKind { TagChip(text: c.id, tint: .gray).fixedSize() }
                            if !source.isEmpty { TagChip(text: source, tint: .gray).lineLimit(1) }
                            if !c.editedAt.isEmpty { TagChip(text: "已编辑", tint: .blue).fixedSize() }
                            if !summary.isEmpty {
                                Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, child ? 2 : 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hover ? Color.primary.opacity(0.05) : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}


/// 在拾忆里新建资料清单：写进结审文书中心的「资料清单」分类
struct SjzNewDatalistSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let project: String
    let onDone: () async -> Void
    @State private var title = ""
    @State private var items = ""
    @State private var due = ""
    @State private var busy = false
    @State private var message = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "list.clipboard").foregroundStyle(Brand.orange)
                Text("新建资料清单").font(.headline)
                Spacer()
            }
            TextField("清单名称，如：第一批资料清单", text: $title).textFieldStyle(.roundedBorder)
            VStack(alignment: .leading, spacing: 4) {
                Text("资料明细（每行一项）").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $items)
                    .font(.callout).scrollContentBackground(.hidden)
                    .padding(6).frame(height: 180)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            HStack(spacing: 8) {
                Text("要求提供日期").font(.caption).foregroundStyle(.secondary)
                DayPickerButton(title: "选择", icon: "calendar", value: $due)
                Spacer()
            }
            if !message.isEmpty { Text(message).font(.caption).foregroundStyle(Brand.orange) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("新建") { Task { await create() } }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(title.trimmed.isEmpty || busy)
            }
        }
        .padding(20)
        .frame(minWidth: 480, idealWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
        .sheetWindowTweaks()
    }

    private func create() async {
        busy = true
        defer { busy = false }
        do {
            let m = try await model.sjz.addDatalist(project: project, title: title.trimmed, items: items.trimmed, dueDate: due)
            model.showNotice(m)
            await onDone()
            dismiss()
        } catch { message = error.localizedDescription }
    }
}
