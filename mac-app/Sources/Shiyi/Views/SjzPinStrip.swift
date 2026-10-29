import SwiftUI

enum SjzPinKind { case note, regulation, clue }

/// 结审的「追加到哪一份」：钉住的取证单 / 法规 / 线索。
/// 钉住后，万能输入、拖进灵动岛的证据 / 法规 / 线索都追加到它；不钉就各自新建。
/// 取证单、法规、线索都可以搜索已有的；取证单、法规搜不到可以直接新建。
/// 灵动岛里三行都显示；万能输入里只显示当前类型对应的那一行（`kinds`）。
struct SjzPinStrip: View {
    @EnvironmentObject var model: AppModel

    var kinds: [SjzPinKind] = [.note, .regulation, .clue]
    /// 灵动岛里自带四周留白；万能输入里由外层控制
    var padded = true
    /// 线索那一行是「关联到哪条线索」（证据 / 法规 / 想法）而不是「追加到哪条线索」（线索类型）
    var associates = false
    /// 选「新建取证单」时不立刻在结审里建，先记下标题，等保存证据时一并创建并把这次的内容存进去（万能输入用）
    var deferNew = false

    @State private var picking: SjzPinKind?
    @State private var query = ""
    @State private var notes: [SjzNoteHit] = []
    /// 「证据」行搜到的已有证据（结审台账里的证据，已按文件去重）
    @State private var evids: [SjzCapture] = []
    @State private var regs: [SjzRegHit] = []
    @State private var clues: [SjzCapture] = []
    @State private var searching = false
    @State private var searchError: String?
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var focused: Bool

    private var pin: SjzPin { model.sjzPin }
    /// 万能输入里选好、保存时才创建的取证单标题
    private var pending: String { deferNew ? model.sjzPendingNote.trimmed : "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(kinds, id: \.self) { pinRow($0) }
            if let kind = picking { picker(kind) }
            // 悬浮输入窗里看不到主窗口的提示条：钉住 / 新建失败的原因直接显示在这里
            if let e = model.sjzError, !e.isEmpty {
                Label(e, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(Color.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, padded ? 12 : 0).padding(.top, padded ? 10 : 0).padding(.bottom, padded ? 8 : 0)
        .task {
            await model.refreshSjzTarget()
        }
        // 万能输入里切换类型：收起上一个类型的搜索
        .onChange(of: kinds) { _, new in if let p = picking, !new.contains(p) { closePicker() } }
    }

    // MARK: 钉住的取证单 / 法规 / 线索

    private func title(_ k: SjzPinKind) -> String { k == .note ? "证据" : k == .regulation ? "法规" : (associates ? "关联线索" : "线索") }
    private func icon(_ k: SjzPinKind) -> String {
        if k == .note, !pin.evidencePath.isEmpty, pending.isEmpty { return "doc.text.image" }
        return k == .note ? "doc.text" : k == .regulation ? "book.closed" : "lightbulb"
    }
    private func value(_ k: SjzPinKind) -> String {
        if k == .note, !pending.isEmpty { return "新建取证单「\(pending)」· 保存时创建" }
        if k == .note, !pin.evidencePath.isEmpty { return "追加到证据「\(pin.evidenceLabel)」" }
        if k == .note { return pin.noteLabel.isEmpty ? "" : "追加到取证单 " + pin.noteLabel }
        return k == .regulation ? pin.regulation : pin.clueLabel
    }
    private func placeholder(_ k: SjzPinKind) -> String {
        if pin.project.isEmpty { return "请先在设置里钉住项目" }
        switch k {
        case .note: return "未钉住 · 存为单独证据文件"
        case .regulation: return "未钉住 · 保存时自动取名并新建"
        case .clue: return associates ? "未钉住 · 不关联线索" : "未钉住 · 新建一条线索"
        }
    }
    private func unpin(_ k: SjzPinKind) {
        // 只是选了「保存时新建」还没建：取消它，回到原来钉住的（或没钉住）状态
        if k == .note, !pending.isEmpty { model.sjzPendingNote = ""; return }
        Task {
            switch k {
            case .note: await model.sjzUnpinNote()
            case .regulation: await model.sjzUnpinRegulation()
            case .clue: await model.sjzUnpinClue()
            }
        }
    }

    private func pinRow(_ kind: SjzPinKind) -> some View {
        let v = value(kind)
        let active = picking == kind
        return HStack(spacing: 6) {
            Text(title(kind)).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
                .frame(width: associates ? 46 : 26, alignment: .leading)
            HStack(spacing: 5) {
                Image(systemName: icon(kind)).font(.system(size: 10))
                    .foregroundStyle(v.isEmpty ? Color.secondary : Brand.orange)
                Text(v.isEmpty ? placeholder(kind) : v)
                    .font(.system(size: 11.5)).lineLimit(1)
                    .foregroundStyle(v.isEmpty ? Color.secondary : Color.primary)
                Spacer(minLength: 0)
                if !v.isEmpty {
                    Button { unpin(kind) } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(.tertiary) }
                        .buttonStyle(.plain).help("取消钉住")
                }
            }
            .padding(.horizontal, 8).frame(height: 26)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            Button { toggle(kind) } label: {
                Image(systemName: active ? "chevron.up" : "magnifyingglass")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 26, height: 26)
                    .background(active ? Brand.orange.opacity(0.25) : Color.primary.opacity(0.06),
                                in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            .buttonStyle(.plain)
            .help(kind == .note ? "搜索已有证据（钉住后追加），或选取证单 / 新建取证单" : kind == .regulation ? "搜索或新建法规" : associates ? "选一条线索：新记的内容会关联到它" : "搜索已有线索，钉住后追加")
            .disabled(pin.project.isEmpty)
        }
    }

    // MARK: 搜索 / 新建

    private func picker(_ kind: SjzPinKind) -> some View {
        let q = query.trimmed
        let exact: Bool
        switch kind {
        case .note: exact = notes.contains { $0.title == q || $0.no == q } || evids.contains { $0.title == q }
        case .regulation: exact = regs.contains { $0.name == q }
        case .clue: exact = true   // 线索不在这里新建：不钉就是新建
        }
        let empty = kind == .note ? (notes.isEmpty && evids.isEmpty) : kind == .regulation ? regs.isEmpty : clues.isEmpty
        // 高度按内容算死：嵌在悬浮输入窗里时，让外层一定把这块高度算进去（否则列表会溢出去盖住底栏）
        let evShown = min(evids.count, noteRows), noteShown = min(notes.count, noteRows)
        let hits = kind == .note ? evShown + noteShown : kind == .regulation ? regs.count : clues.count
        let heads = kind == .note ? (evShown > 0 ? 1 : 0) + (noteShown > 0 ? 1 : 0) : 0
        let showNew = kind != .clue && !q.isEmpty && !exact
        let showHint = !showNew && q.isEmpty && empty && !searching
        let showErr = searchError != nil
        let rows = (kind == .note ? hits : min(hits, rowLimit)) + (showNew ? 1 : 0)
        let height = 28 + CGFloat(rows) * 30 + CGFloat(heads) * 20 + (showHint && !showErr ? 22 : 0) + (showErr ? 34 : 0)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 10)).foregroundStyle(.secondary)
                TextField(kind == .note ? "搜索已有证据 / 取证单，回车可新建取证单" : kind == .regulation ? "搜索项目法规，或输入法规名新建" : "搜索已有线索（编号 / 标题 / 内容）",
                          text: $query)
                    .textFieldStyle(.plain).font(.system(size: 12)).focused($focused)
                    .onSubmit { commit(kind) }
                    .onChange(of: query) { _, _ in scheduleSearch(kind) }
                if searching { ProgressView().controlSize(.mini) }
            }
            .padding(.horizontal, 8).frame(height: 28)
            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7, style: .continuous))

            switch kind {
            case .note:
                if evShown > 0 { sectionHead("已有证据 · 钉住后新内容追加到它") }
                ForEach(evids.prefix(noteRows)) { c in
                    resultRow(icon: "doc.text.image", title: (c.title.isEmpty ? c.summary : c.title).mdPlain, sub: c.source) {
                        Task { await model.sjzPin(evidence: c); closePicker() }
                    }
                }
                if noteShown > 0 { sectionHead("取证单 · 新证据追加到它的证据汇集") }
                ForEach(notes.prefix(noteRows)) { n in
                    resultRow(icon: "doc.text", title: n.no.isEmpty ? n.title : "\(n.no) \(n.title)", sub: n.status) {
                        Task { await model.sjzPin(note: n); closePicker() }
                    }
                }
            case .regulation:
                ForEach(regs.prefix(rowLimit)) { r in
                    resultRow(icon: "book.closed", title: r.name, sub: r.clause) {
                        Task { await model.sjzPin(regulation: r.name); closePicker() }
                    }
                }
            case .clue:
                ForEach(clues.prefix(rowLimit)) { c in
                    resultRow(icon: "lightbulb", title: "\(c.id) \((c.title.isEmpty ? c.summary : c.title).mdPlain)", sub: c.statusLabel) {
                        Task { await model.sjzPin(clue: c); closePicker() }
                    }
                }
            }
            if showNew {
                let newTitle = kind == .note ? (deferNew ? "新建取证单「\(q)」，保存证据时一并创建" : "新建取证单「\(q)」并钉住") : "新建法规「\(q)」并钉住"
                resultRow(icon: "plus.circle.fill", title: newTitle, sub: "", tint: Brand.orange) {
                    commit(kind)
                }
            }
            if let e = searchError {
                Label("搜索失败：" + e, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(Color.red).lineLimit(2)
                    .padding(.horizontal, 4)
            } else if !showNew && showHint {
                Text(kind == .note ? "还没有证据或取证单：输入标题即可新建取证单"
                     : kind == .regulation ? "项目里还没有法规：输入法规名即可钉住 / 新建"
                     : "项目里还没有线索：直接保存就会新建一条")
                    .font(.caption).foregroundStyle(.tertiary).padding(.horizontal, 4)
            }
        }
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .topLeading)
    }

    /// 搜索结果最多列几条：灵动岛里空间大，万能输入里少列几条（继续输入缩小范围）
    private var rowLimit: Int { padded ? 6 : 4 }
    /// 「证据」行里证据、取证单两组各列几条
    private var noteRows: Int { padded ? 4 : 3 }

    private func sectionHead(_ s: String) -> some View {
        Text(s).font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
            .padding(.horizontal, 4).frame(height: 16, alignment: .leading)
    }

    private func resultRow(icon: String, title: String, sub: String, tint: Color = .secondary, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 11)).foregroundStyle(tint).frame(width: 16)
                Text(title).font(.system(size: 11.5)).lineLimit(1)
                Spacer(minLength: 4)
                if !sub.isEmpty { Text(sub).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1) }
            }
            .padding(.horizontal, 8).frame(height: 26)
            .contentShape(Rectangle())
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: 行为

    private func toggle(_ kind: SjzPinKind) {
        if picking == kind { closePicker(); return }
        picking = kind
        query = ""
        notes = []; evids = []; regs = []; clues = []
        model.sjzError = nil
        searchError = nil
        scheduleSearch(kind, immediately: true)
        // 悬浮输入窗不激活应用：搜索框拿到焦点后，要把输入法也切到它上面，不然中文打不进去 / 拼音当字母搜
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            focused = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { FieldInputContext.activate() }
        }
    }

    private func closePicker() {
        picking = nil
        query = ""
        searchError = nil
        searching = false
        searchTask?.cancel()
    }

    private func scheduleSearch(_ kind: SjzPinKind, immediately: Bool = false) {
        searchTask?.cancel()
        let q = query.trimmed
        searchTask = Task {
            if !immediately { try? await Task.sleep(nanoseconds: 220_000_000) }
            if Task.isCancelled { return }
            searching = true
            defer { if !Task.isCancelled { searching = false } }
            do {
                switch kind {
                case .note:
                    let r = try await model.sjz.searchNotes(q)
                    // 已有证据：同一份文件只列一次（一份文件里可能有多次摘录）；只列能追加的 evidence/*.md
                    let project = model.sjzPin.project
                    var ev: [SjzCapture] = []
                    if !project.isEmpty {
                        var seen = Set<String>()
                        for c in try await model.sjz.captures(project: project, kind: "evidence", query: q, limit: 60)
                        where c.path.hasPrefix("evidence/") && c.path.hasSuffix(".md") && !c.path.dropFirst(9).contains("/") && seen.insert(c.path).inserted {
                            ev.append(c)
                        }
                    }
                    if !Task.isCancelled { notes = r; evids = ev; searchError = nil }
                case .regulation:
                    let r = try await model.sjz.searchRegulations(q)
                    if !Task.isCancelled { regs = r; searchError = nil }
                case .clue:
                    let project = model.sjzPin.project
                    var r: [SjzCapture] = []
                    if !project.isEmpty { r = try await model.sjz.captures(project: project, kind: "clue", query: q, limit: 30) }
                    if !Task.isCancelled { clues = r; searchError = nil }
                }
            } catch {
                // 输入过程中旧的搜索被取消不算失败；其余错误（超时 / 鉴权 / 结审没开）要让用户看到，而不是显示成「没有结果」
                if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled { return }
                searchError = error.localizedDescription
            }
        }
    }

    /// 回车：和输入完全一致的就钉住它；否则用输入的文字新建（线索：只剩一条结果时钉住它）
    private func commit(_ kind: SjzPinKind) {
        Task {
            // 刚输完就回车时搜索还没回来：先等它，免得拿旧结果把已有的取证单当成不存在、重复新建
            await searchTask?.value
            let q = query.trimmed
            switch kind {
            case .note:
                if let n = notes.first(where: { $0.title == q || $0.no == q }) {
                    await model.sjzPin(note: n); closePicker()
                } else if let e = evids.first(where: { $0.title == q }) {
                    await model.sjzPin(evidence: e); closePicker()
                } else if !q.isEmpty {
                    // 搜索本身失败了（结果不可信）：不要贸然新建，错误已经显示在搜索框下面
                    guard searchError == nil else { return }
                    if deferNew {
                        // 万能输入：保存证据时才在结审里创建，并把这次内容存进去
                        model.sjzPendingNote = q
                        closePicker()
                    } else {
                        await model.sjzCreateNote(q); closePicker()
                    }
                }
            case .regulation:
                if let r = regs.first(where: { $0.name == q }) {
                    await model.sjzPin(regulation: r.name); closePicker()
                } else if !q.isEmpty {
                    // 法规名不存在也可以先钉住：之后保存时会以这个名字新建
                    await model.sjzPin(regulation: q); closePicker()
                }
            case .clue:
                if let c = clues.first(where: { $0.id.caseInsensitiveCompare(q) == .orderedSame }) ?? (clues.count == 1 ? clues.first : nil) {
                    await model.sjzPin(clue: c); closePicker()
                }
            }
        }
    }
}

/// 悬浮输入窗（不激活应用的 NSPanel）里，SwiftUI 的搜索框拿到焦点后输入法仍挂在原来的 App 上：
/// 和主输入框一样，显式把输入上下文切到当前的字段编辑器。
@MainActor
enum FieldInputContext {
    static func activate() {
        guard let w = NSApp.windows.first(where: { $0.isKeyWindow }),
              let tv = w.firstResponder as? NSTextView else { return }
        tv.inputContext?.activate()
    }
}
