import SwiftUI

/// 任务详情：滴答任务本身 + 融合进来的任务笔记（来自手机备份里的「任务 ↔ 笔记」对应关系）
struct TaskDetailView: View {
    @EnvironmentObject var model: AppModel
    let task: DidaTask

    @State private var note: NoteDetail?
    @State private var noteError: String?
    @State private var noteLoading = false

    private var current: DidaTask { model.localTask(task.id) ?? task }
    private var ref: TaskNoteRef? { model.taskNote(forTask: current) }

    @State private var showEdit = false
    @State private var composing = false
    @State private var deliverable = ""
    @State private var purpose = ""
    @State private var steps = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                chips
                if !current.content.trimmed.isEmpty {
                    Card {
                        VStack(alignment: .leading, spacing: 8) {
                            SectionTitle(text: "备注")
                            MarkdownView(text: current.content)
                        }
                    }
                }
                taskNoteSection
                actions
            }
            .padding(24)
            .frame(maxWidth: 780, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(AmbientBackground())
        .task(id: ref?.noteId) { await loadNote() }
        .sheet(isPresented: $showEdit) { TaskEditSheet(task: current).environmentObject(model) }
        .onAppear { consumePendingEdit() }
        .onChange(of: model.pendingEditTask) { consumePendingEdit() }
    }

    private func consumePendingEdit() {
        guard model.pendingEditTask == task.id else { return }
        model.pendingEditTask = nil
        showEdit = true
    }

    // MARK: - 头部

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Button {
                Task { await model.complete(current) }
            } label: {
                Image(systemName: current.done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 26))
                    .foregroundStyle(current.done ? Color.green : priorityColor)
            }
            .buttonStyle(.plain)
            .disabled(current.done)
            .help(current.done ? "已完成" : "标记完成")

            VStack(alignment: .leading, spacing: 4) {
                // 标签跟在标题后面，用小一号的蓝字，不再单独占一个胶囊
                (Text(current.cleanTitle)
                    .font(.title.bold())
                    .foregroundColor(current.done ? .secondary : .primary)
                    + Text(current.tags.isEmpty ? "" : "  " + current.tags.map { "#" + $0 }.joined(separator: " "))
                    .font(.callout.weight(.medium))
                    .foregroundColor(Brand.orange))
                    .strikethrough(current.done)
                    .textSelection(.enabled)
                if current.done, let d = current.completedDate {
                    Text("完成于 " + d.formatted(date: .abbreviated, time: .shortened)).font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            Button { showEdit = true } label: { Label("编辑", systemImage: "square.and.pencil") }
                .buttonStyle(.bordered).controlSize(.regular)
                .help("编辑标题、备注、标签")
        }
    }

    // MARK: - 可以直接改的属性

    @State private var showDate = false

    private var chips: some View {
        FlowRow(spacing: 8) {
            dateChip
            priorityChip
            listChip
            projectChip
            if let r = current.repeatFlag { chip(icon: "repeat", text: Self.repeatText(r), tint: .secondary) }
        }
    }

    private var editable: Bool { !current.done }

    private func openDateEditor() { showDate = true }

    private var dateChip: some View {
        let c = current
        let late = !c.done && (c.date ?? "9999") < Day.today()
        let text: String = {
            guard let d = c.date else { return "添加日期" }
            let base = late ? "逾期 \(max(1, Day.diff(d, Day.today()))) 天 · " + Day.label(d) : Day.label(d)
            return base + (c.time.map { " " + $0 } ?? "")
        }()
        return Button { openDateEditor() } label: {
            chipLabel(icon: c.time == nil ? "calendar" : "clock", text: text, tint: late ? .red : (c.date == nil ? .secondary : .primary))
        }
        .buttonStyle(.plain).disabled(!editable)
        .help("修改日期和时间")
        .popover(isPresented: $showDate, arrowEdge: .bottom) {
            // 弹层单独做成一个视图：它自己持有日期 / 时间的状态。
            // 之前把这些状态放在外面，弹层里「if 有具体时间」的分支不会跟着开关刷新，打开后看不到时间。
            TaskDatePopover(task: current) { showDate = false }
                .environmentObject(model)
        }
    }

    private var priorityChip: some View {
        Menu {
            Picker("优先级", selection: Binding(get: { current.priority }, set: { p in Task { await model.edit(current, .priority(p)) } })) {
                Text("无").tag(0)
                Text("低").tag(1)
                Text("中").tag(3)
                Text("高").tag(5)
            }
            .pickerStyle(.inline)
        } label: {
            chipLabel(icon: current.priority > 0 ? "flag.fill" : "flag", text: current.priority > 0 ? priorityText : "优先级", tint: current.priority > 0 ? priorityColor : .secondary)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().disabled(!editable)
        .help("修改优先级")
    }

    /// 滴答里的清单（含收集箱）
    private var listChip: some View {
        Menu {
            ForEach(model.didaLists, id: \.id) { l in
                Button {
                    if l.id != current.projectId { Task { await model.edit(current, .list(l.id)) } }
                } label: {
                    if l.id == current.projectId { Label(l.name, systemImage: "checkmark") } else { Text(l.name) }
                }
            }
        } label: {
            chipLabel(icon: "tray", text: model.overview?.projectName(current.projectId) ?? "清单", tint: .secondary)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().disabled(!editable)
        .help("移动到其他清单")
    }

    /// 拾忆里的项目（靠标签归属）
    private var projectChip: some View {
        let cur = model.projectOf(current)
        return Menu {
            ForEach(model.projects, id: \.keyword) { p in
                Button {
                    if p.keyword != cur?.keyword { Task { await model.setProject(current, to: p) } }
                } label: {
                    if p.keyword == cur?.keyword { Label(p.keyword, systemImage: "checkmark") } else { Text(p.keyword) }
                }
            }
            if cur != nil {
                Divider()
                Button("移出项目") { Task { await model.setProject(current, to: nil) } }
                Button("在「项目」里查看") { if let cur { model.goToProject(cur.keyword) } }
            }
        } label: {
            chipLabel(icon: "folder", text: cur.map { "项目 · " + $0.keyword } ?? "归入项目", tint: cur == nil ? .secondary : Brand.orange)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().disabled(!editable || model.projects.isEmpty)
        .help("改变所属项目（通过标签归属）")
    }

    private func chip(icon: String, text: String, tint: Color) -> some View { chipLabel(icon: icon, text: text, tint: tint) }

    private func chipLabel(icon: String, text: String, tint: Color) -> some View {
        Label(text, systemImage: icon)
            .font(.callout)
            .foregroundStyle(tint)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .glassCapsule()
    }

    // MARK: - 任务笔记

    @ViewBuilder private var taskNoteSection: some View {
        if SjzTasks.owns(current.id) {
            // 结审任务的专注记录、进展都写在任务说明的「进展记录」里（结审），不建闪念贝壳笔记
            EmptyView()
        } else if let ref {
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        SectionTitle(text: "任务笔记")
                        if ref.archived == true { TagChip(text: "已交付", tint: .green) }
                        Spacer()
                        Button { model.openNote(ref.noteId, title: ref.deliverable) } label: { Label("单独打开", systemImage: "doc.text") }
                            .buttonStyle(.borderless)
                        Button { model.open(noteURL(ref.noteId)) } label: { Label("闪念贝壳", systemImage: "arrow.up.right.square") }
                            .buttonStyle(.borderless)
                    }
                    if let d = ref.deliverable?.nonEmpty {
                        Label("要交付：" + d, systemImage: "shippingbox").font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Divider()
                    if let e = noteError {
                        ErrorBanner(text: e) { Task { await loadNote() } }
                    } else if noteLoading && note == nil {
                        ProgressView().controlSize(.small)
                    } else if let n = note {
                        if n.content.isEmpty {
                            Text("（任务笔记还是空的）").foregroundStyle(.tertiary)
                        } else {
                            MarkdownView(text: n.content)
                        }
                        let images = NoteImages.extract(n.raw)
                        if !images.isEmpty {
                            VStack(alignment: .leading, spacing: 10) { ForEach(images, id: \.self) { RemoteImage(url: $0) } }
                        }
                    }
                }
            }
        } else {
            Card {
                if composing {
                    composeForm
                } else {
                    // 右侧面板很窄时，说明在上、按钮在下，按钮文字不被截断
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) {
                            Image(systemName: "doc.badge.plus").foregroundStyle(.tertiary)
                            Text("还没有任务笔记").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                            Spacer(minLength: 4)
                            createNoteButton
                        }
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 8) {
                                Image(systemName: "doc.badge.plus").foregroundStyle(.tertiary)
                                Text("还没有任务笔记").font(.callout).foregroundStyle(.secondary)
                            }
                            createNoteButton
                        }
                    }
                }
            }
        }
    }

    private var createNoteButton: some View {
        Button {
            deliverable = current.cleanTitle
            composing = true
        } label: { Label("创建任务笔记", systemImage: "plus").lineLimit(1).fixedSize() }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .tint(Brand.orange)
            .disabled(!model.hasIdeashell)
            .help(model.hasIdeashell ? "在闪念贝壳里新建一篇任务笔记，并把链接写回滴答任务" : "先到「设置」填写闪念贝壳 API Key")
    }

    private var composeForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(text: "创建任务笔记")
            field("交付成果", hint: "做完之后，交出去的是什么？") {
                TextField("", text: $deliverable).textFieldStyle(.roundedBorder)
            }
            field("行动目的", hint: "为什么要做这件事？（可不填）") {
                TextEditor(text: $purpose)
                    .font(.body).scrollContentBackground(.hidden)
                    .frame(minHeight: 54, maxHeight: 90)
                    .padding(6)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            }
            field("行动步骤", hint: "每行一步，会写成待勾选的清单（可不填）") {
                TextEditor(text: $steps)
                    .font(.body).scrollContentBackground(.hidden)
                    .frame(minHeight: 70, maxHeight: 130)
                    .padding(6)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            }
            HStack {
                Spacer()
                if model.creatingTaskNote { ProgressView().controlSize(.small) }
                Button("取消") { composing = false }
                    .disabled(model.creatingTaskNote)
                Button("创建") {
                    Task {
                        if await model.createTaskNote(current, deliverable: deliverable, purpose: purpose, steps: steps) {
                            composing = false
                            purpose = ""
                            steps = ""
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(Brand.orange)
                .disabled(model.creatingTaskNote)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func field<C: View>(_ title: String, hint: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(title).font(.callout.weight(.semibold))
                Text(hint).font(.caption).foregroundStyle(.tertiary)
            }
            content()
        }
    }

    private func loadNote() async {
        note = nil
        noteError = nil
        guard let id = ref?.noteId else { return }
        noteLoading = true
        defer { noteLoading = false }
        do { note = try await model.noteDetail(id) }
        catch { noteError = error.localizedDescription }
    }

    // MARK: - 操作

    private var actions: some View {
        FlowRow(spacing: 8) {
            Button { model.open(didaTaskURL(current.projectId, current.id)) } label: { Label("在滴答清单中打开", systemImage: "arrow.up.right.square") }
            Button { showEdit = true } label: { Label("编辑任务", systemImage: "square.and.pencil") }
            Button { model.copy(current.cleanTitle) } label: { Label("复制标题", systemImage: "doc.on.doc") }
            if current.done {
                Button { Task { await model.undoComplete(current) } } label: { Label("恢复为未完成", systemImage: "arrow.uturn.backward") }
            }
            Button(role: .destructive) { model.requestDelete(.task(current)) } label: { Label("删除", systemImage: "trash") }
                .help("删除这个待办（会先确认）")
        }
        .buttonStyle(.bordered)
    }

    // MARK: - 文案

    private var priorityColor: Color {
        switch current.priority {
        case 5: return .red
        case 3: return .orange
        case 1: return .blue
        default: return .secondary
        }
    }

    private var priorityText: String {
        switch current.priority {
        case 5: return "高优先级"
        case 3: return "中优先级"
        case 1: return "低优先级"
        default: return ""
        }
    }

    /// RRULE → 一句话（只认常见的 FREQ / INTERVAL）
    static func repeatText(_ rule: String) -> String {
        var freq = ""
        var interval = 1
        for part in rule.replacingOccurrences(of: "RRULE:", with: "").split(separator: ";") {
            let kv = part.split(separator: "=", maxSplits: 1).map(String.init)
            guard kv.count == 2 else { continue }
            if kv[0] == "FREQ" { freq = kv[1] }
            if kv[0] == "INTERVAL" { interval = Int(kv[1]) ?? 1 }
        }
        let unit: String
        switch freq {
        case "DAILY": unit = "天"
        case "WEEKLY": unit = "周"
        case "MONTHLY": unit = "个月"
        case "YEARLY": unit = "年"
        default: return "重复"
        }
        return interval <= 1 ? "每" + unit.replacingOccurrences(of: "个月", with: "月") : "每 \(interval) \(unit)重复"
    }
}

/// 自动换行的横向排布
struct FlowRow<Content: View>: View {
    var spacing: CGFloat = 8
    @ViewBuilder var content: Content

    var body: some View {
        FlowLayout(spacing: spacing) { content }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, maxW: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > width { y += rowH + spacing; x = 0; rowH = 0 }
            x += s.width + spacing
            rowH = max(rowH, s.height)
            maxW = max(maxW, x - spacing)
        }
        return CGSize(width: maxW, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX && x + s.width > bounds.maxX { y += rowH + spacing; x = bounds.minX; rowH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
    }
}
