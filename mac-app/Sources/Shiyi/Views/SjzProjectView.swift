import SwiftUI

/// 「项目」页里的审计项目（来自结审）。数据只来自结审：任务、专注和记录都写回结审，不进滴答和闪念贝壳。
struct SjzProjectDetailView: View {
    @EnvironmentObject var model: AppModel
    let name: String

    @State private var docs: SjzDocs?
    @State private var selPhase = ""
    @State private var captures: [SjzCapture] = []
    @State private var capsLoaded = false
    @State private var capKind = ""
    @State private var capQuery = ""
    @State private var capDays = 0
    @State private var editing: SjzCapture?

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
            await model.refreshSjzOverview()
            docs = try? await model.sjz.documents(project: name)
            await loadCaptures()
        }
        .sheet(item: $editing) { c in
            SjzCaptureEditor(project: name, capture: c) { await loadCaptures() }
                .environmentObject(model)
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
                HStack(spacing: 6) {
                    TagChip(text: "审计项目", tint: Brand.orange)
                    if pinned { TagChip(text: "岛上保存到这里", tint: .green) }
                    Text("数据来自结审，只保存在本机").font(.caption).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 6) {
                Button { model.openSjzApp() } label: { Label("打开结审", systemImage: "arrow.up.forward.app") }
                    .buttonStyle(.bordered)
                if !pinned {
                    Button { Task { await model.sjzSetProject(name) } } label: { Label("设为当前项目", systemImage: "pin") }
                        .buttonStyle(.borderless)
                }
            }
            .font(.callout)
        }
    }

    private var statsRow: some View {
        let s = stat
        return HStack(spacing: 10) {
            StatTile(value: "\(s?.open ?? 0)", label: "待办")
            StatTile(value: "\(s?.dueToday ?? 0)", label: "今天到期", tint: (s?.dueToday ?? 0) > 0 ? Brand.orange : .primary)
            StatTile(value: "\(s?.overdue ?? 0)", label: "逾期", tint: (s?.overdue ?? 0) > 0 ? .red : .primary)
            StatTile(value: "\(s?.pendingReviews ?? 0)", label: "待复核", tint: (s?.pendingReviews ?? 0) > 0 ? Brand.orange : .primary)
        }
    }

    @ViewBuilder private var tasksCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                SectionTitle(text: "相关待办", count: tasks.count)
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
                        Button { model.openSjzApp() } label: { Label("在结审里打开", systemImage: "arrow.up.forward.app") }
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
                            let rows = p.items.filter { $0.count > 0 || $0.required }
                            if rows.isEmpty { Text("这个阶段还没有文书").font(.callout).foregroundStyle(.tertiary) }
                            ForEach(rows) { t in docTypeBlock(t) }
                        }
                    }
                    Text("只显示编号、标题和状态，文书正文不会出现在拾忆里。").font(.caption2).foregroundStyle(.tertiary)
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
        return Button { model.openSjzApp() } label: {
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

    private func loadCaptures() async {
        captures = (try? await model.sjz.captures(project: name)) ?? captures
        capsLoaded = true
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
        if capsLoaded && !captures.isEmpty {
            let list = filteredCaptures
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        SectionTitle(text: "来自拾忆", count: captures.count)
                        Spacer()
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
                        ForEach([("", "全部"), ("evidence", "证据"), ("regulation", "法规"), ("clue", "线索"), ("data", "数据")], id: \.0) { k, label in
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
                    ForEach(list.prefix(40)) { c in captureRow(c) }
                    if list.count > 40 { Text("还有 \(list.count - 40) 条，用上面的筛选缩小范围").font(.caption).foregroundStyle(.tertiary) }
                }
            }
        }
    }

    private func captureRow(_ c: SjzCapture) -> some View {
        Button { editing = c } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: c.icon).font(.system(size: 13)).foregroundStyle(Brand.orange)
                    .frame(width: 26, height: 26)
                    .background(Brand.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text(c.title.isEmpty ? c.summary : c.title).font(.callout.weight(.medium)).lineLimit(1)
                        if !c.statusLabel.isEmpty {
                            TagChip(text: c.statusLabel, tint: c.status == "verified" ? .green : c.status == "excluded" ? .gray : Brand.orange)
                        }
                        if !c.editedAt.isEmpty { TagChip(text: "已编辑", tint: .blue) }
                        if !c.taskId.isEmpty { TagChip(text: "任务 \(c.taskId)", tint: .teal) }
                        if !c.noteNo.isEmpty { TagChip(text: c.noteNo, tint: .blue) }
                    }
                    // 摘要和「类型 · 来源」放在同一行：摘要太长时先被截断，类型 · 来源始终完整
                    HStack(spacing: 8) {
                        if !c.summary.isEmpty && c.summary != c.title {
                            Text(c.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Text("\(c.kindLabel) · \(c.source)").font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                            .layoutPriority(1)
                    }
                }
                Spacer(minLength: 6)
                Text(Self.timeLabel(c.date)).font(.caption2).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("编辑并写回结审") { editing = c }
            if c.kind == "clue" {
                Divider()
                ForEach([("pending", "待核实"), ("verified", "已核实"), ("excluded", "排除")], id: \.0) { st, label in
                    Button(label + (c.status == st ? " ✓" : "")) { Task { await setClue(c, st) } }
                }
            }
        }
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

/// 来自拾忆的一条记录：二次编辑并写回结审（正文 / 标题 / 来源 / 关联取证单；线索可改状态、转任务或取证单草稿）
struct SjzCaptureEditor: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let project: String
    let capture: SjzCapture
    let onDone: () async -> Void

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
    @State private var preview = true

    /// 正文拆成「文字段 / 图片段」混排编辑：图片整行引用 `![说明][imgN]` 单独成块
    struct Seg: Identifiable, Equatable {
        enum Kind { case text, image }
        let id = UUID()
        var kind: Kind
        var text = ""
        var key = ""
        var alt = ""
    }

    static func parse(_ md: String) -> [Seg] {
        let re = RX("^!\\[([^\\]]*)\\]\\[(img\\d+)\\]\\s*$")
        var out: [Seg] = []
        var buf: [String] = []
        func flush() {
            let t = buf.joined(separator: "\n").trimmed
            if !t.isEmpty { out.append(Seg(kind: .text, text: t)) }
            buf = []
        }
        for line in md.components(separatedBy: "\n") {
            if let m = re.first(in: line) { flush(); out.append(Seg(kind: .image, key: m.group(2), alt: m.group(1))) } else { buf.append(line) }
        }
        flush()
        return out.isEmpty ? [Seg(kind: .text)] : out
    }

    static func join(_ segs: [Seg]) -> String {
        segs.compactMap { s -> String? in
            switch s.kind {
            case .text: return s.text.trimmed.isEmpty ? nil : s.text.trimmed
            case .image: return "![\(s.alt)][\(s.key)]"
            }
        }.joined(separator: "\n\n")
    }

    private var content: String { Self.join(segs) }

    private var isClue: Bool { capture.kind == "clue" }
    private var canLink: Bool { capture.kind == "evidence" || capture.kind == "regulation" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: capture.icon).foregroundStyle(Brand.orange)
                Text("\(capture.kindLabel) · \(capture.id)").font(.headline)
                Spacer()
                Text("保存后写回结审，并在工作日志留痕").font(.caption).foregroundStyle(.tertiary)
            }
            field("标题", text: $title)
            field("来源", text: $source)
            if isClue {
                HStack(spacing: 8) {
                    Text("状态").font(.caption).foregroundStyle(.secondary)
                    Picker("", selection: $status) {
                        Text("待核实").tag("pending")
                        Text("已核实").tag("verified")
                        Text("排除").tag("excluded")
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 220)
                    Spacer()
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(capture.kind == "data" ? "文件" : "正文").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if capture.kind != "data", loaded, editable {
                        Picker("", selection: $preview) {
                            Text("预览").tag(true)
                            Text("编辑").tag(false)
                        }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 120)
                    }
                }
                if capture.kind == "data" {
                    Text(capture.path).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    Text("数据文件不能在这里编辑，可以改标题和来源；文件在结审的「原始材料」里。").font(.caption).foregroundStyle(.tertiary)
                } else if !loaded {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 160)
                } else if !editable {
                    Text(content.isEmpty ? "这一项的正文不能在线编辑" : content).font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 100, alignment: .topLeading)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            if preview { previewBlocks } else { editBlocks }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minHeight: 220, maxHeight: 430)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
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
            if isClue {
                HStack(spacing: 8) {
                    Button { Task { await run { try await model.sjz.clueToTask(project: project, id: capture.id) } } } label: { Label("转为任务", systemImage: "checkmark.circle") }
                        .disabled(!capture.taskId.isEmpty || busy)
                    Button { Task { await run { try await model.sjz.clueToNote(project: project, id: capture.id) } } } label: { Label("生成取证单草稿", systemImage: "doc.badge.plus") }
                        .disabled(busy)
                    Text("线索不能直接成为审计疑点，需要在结审里确认").font(.caption).foregroundStyle(.tertiary)
                }
                .buttonStyle(.bordered).controlSize(.small)
            }
            if !message.isEmpty { Text(message).font(.caption).foregroundStyle(Brand.orange) }
            HStack {
                Button("在结审里打开") { model.openSjzApp() }.buttonStyle(.borderless).font(.callout)
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存并写回") { Task { await save() } }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).disabled(busy || !dirty)
            }
        }
        .padding(20)
        .frame(width: 640)
        .task {
            title = capture.title
            source = capture.source
            status = capture.status
            if capture.kind != "data" {
                if let d = try? await model.sjz.captureDetail(project: project, id: capture.id) {
                    segs = Self.parse(d.content); original = Self.join(segs); editable = d.editable
                    images = d.images.compactMapValues { NSImage(data: $0) }
                    if isClue || d.images.isEmpty && d.content.count < 200 { preview = false }
                }
            }
            notes = (try? await model.sjz.searchNotes("")) ?? []
            loaded = true
        }
    }

    private var dirty: Bool {
        title != capture.title || source != capture.source || (editable && loaded && content != original)
            || (isClue && status != capture.status) || linkNote != nil
    }

    @ViewBuilder private var previewBlocks: some View {
        ForEach(segs) { seg in
            switch seg.kind {
            case .image: imageView(seg)
            case .text: markdownText(seg.text)
            }
        }
    }

    @ViewBuilder private var editBlocks: some View {
        ForEach($segs) { $seg in
            switch seg.kind {
            case .text:
                TextField("文字", text: $seg.text, axis: .vertical)
                    .textFieldStyle(.plain).font(.system(size: 13)).lineLimit(1...30)
                    .padding(8)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            case .image:
                ZStack(alignment: .topTrailing) {
                    imageView(seg)
                    Button { segs.removeAll { $0.id == seg.id } } label: {
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

    /// 简易 Markdown 渲染：标题、引用块、列表和行内格式（粗体 / 链接 / 代码）
    @ViewBuilder private func markdownText(_ md: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(md.components(separatedBy: "\n").enumerated()), id: \.offset) { _, raw in
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.isEmpty {
                    Color.clear.frame(height: 2)
                } else if line.hasPrefix("#") {
                    let level = line.prefix(while: { $0 == "#" }).count
                    Text(inline(String(line.dropFirst(level)).trimmed))
                        .font(.system(size: level <= 1 ? 17 : level == 2 ? 15 : 14, weight: .semibold))
                } else if line.hasPrefix(">") {
                    HStack(alignment: .top, spacing: 8) {
                        RoundedRectangle(cornerRadius: 1.5).fill(Brand.orange.opacity(0.5)).frame(width: 3)
                        Text(inline(String(line.drop(while: { $0 == ">" || $0 == " " }))))
                            .font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•").foregroundStyle(.secondary)
                        Text(inline(String(line.dropFirst(2)))).font(.system(size: 13))
                    }
                } else {
                    Text(inline(line)).font(.system(size: 13))
                }
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
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
        guard !f.isEmpty else { dismiss(); return }
        await run { try await model.sjz.updateCapture(project: project, id: capture.id, fields: f) }
    }
}
