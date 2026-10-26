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

    @State private var picking: SjzPinKind?
    @State private var query = ""
    @State private var notes: [SjzNoteHit] = []
    @State private var regs: [SjzRegHit] = []
    @State private var clues: [SjzCapture] = []
    @State private var searching = false
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var focused: Bool

    private var pin: SjzPin { model.sjzPin }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(kinds, id: \.self) { pinRow($0) }
            if let kind = picking { picker(kind) }
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

    private func title(_ k: SjzPinKind) -> String { k == .note ? "证据" : k == .regulation ? "法规" : "线索" }
    private func icon(_ k: SjzPinKind) -> String { k == .note ? "doc.text" : k == .regulation ? "book.closed" : "lightbulb" }
    private func value(_ k: SjzPinKind) -> String { k == .note ? pin.noteLabel : k == .regulation ? pin.regulation : pin.clueLabel }
    private func placeholder(_ k: SjzPinKind) -> String {
        if pin.project.isEmpty { return "请先在设置里钉住项目" }
        switch k {
        case .note: return "未钉住 · 存为单独证据文件"
        case .regulation: return "未钉住 · 保存时自动取名并新建"
        case .clue: return "未钉住 · 新建一条线索"
        }
    }
    private func unpin(_ k: SjzPinKind) {
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
                .frame(width: 26, alignment: .leading)
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
            .help(kind == .note ? "搜索或新建取证单" : kind == .regulation ? "搜索或新建法规" : "搜索已有线索，钉住后追加")
            .disabled(pin.project.isEmpty)
        }
    }

    // MARK: 搜索 / 新建

    private func picker(_ kind: SjzPinKind) -> some View {
        let q = query.trimmed
        let exact: Bool
        switch kind {
        case .note: exact = notes.contains { $0.title == q || $0.no == q }
        case .regulation: exact = regs.contains { $0.name == q }
        case .clue: exact = true   // 线索不在这里新建：不钉就是新建
        }
        let empty = kind == .note ? notes.isEmpty : kind == .regulation ? regs.isEmpty : clues.isEmpty
        // 高度按内容算死：嵌在悬浮输入窗里时，让外层一定把这块高度算进去（否则列表会溢出去盖住底栏）
        let hits = kind == .note ? notes.count : kind == .regulation ? regs.count : clues.count
        let showNew = kind != .clue && !q.isEmpty && !exact
        let showHint = !showNew && q.isEmpty && empty && !searching
        let rows = min(hits, rowLimit) + (showNew ? 1 : 0)
        let height = 28 + CGFloat(rows) * 30 + (showHint ? 22 : 0)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 10)).foregroundStyle(.secondary)
                TextField(kind == .note ? "搜索取证单编号或标题，回车可新建" : kind == .regulation ? "搜索项目法规，或输入法规名新建" : "搜索已有线索（编号 / 标题 / 内容）",
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
                ForEach(notes.prefix(rowLimit)) { n in
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
                    resultRow(icon: "lightbulb", title: "\(c.id) \(c.title.isEmpty ? c.summary : c.title)", sub: c.statusLabel) {
                        Task { await model.sjzPin(clue: c); closePicker() }
                    }
                }
            }
            if showNew {
                resultRow(icon: "plus.circle.fill", title: kind == .note ? "新建取证单「\(q)」并钉住" : "新建法规「\(q)」并钉住", sub: "", tint: Brand.orange) {
                    commit(kind)
                }
            } else if showHint {
                Text(kind == .note ? "还没有取证单：输入标题即可新建"
                     : kind == .regulation ? "项目里还没有法规：输入法规名即可钉住 / 新建"
                     : "项目里还没有线索：直接保存就会新建一条")
                    .font(.caption).foregroundStyle(.tertiary).padding(.horizontal, 4)
            }
        }
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .topLeading)
    }

    /// 搜索结果最多列几条：灵动岛里空间大，万能输入里少列几条（继续输入缩小范围）
    private var rowLimit: Int { padded ? 6 : 4 }

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
        notes = []; regs = []; clues = []
        scheduleSearch(kind, immediately: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { focused = true }
    }

    private func closePicker() {
        picking = nil
        query = ""
        searchTask?.cancel()
    }

    private func scheduleSearch(_ kind: SjzPinKind, immediately: Bool = false) {
        searchTask?.cancel()
        let q = query.trimmed
        searchTask = Task {
            if !immediately { try? await Task.sleep(nanoseconds: 220_000_000) }
            if Task.isCancelled { return }
            searching = true
            defer { searching = false }
            switch kind {
            case .note:
                let r = (try? await model.sjz.searchNotes(q)) ?? []
                if !Task.isCancelled { notes = r }
            case .regulation:
                let r = (try? await model.sjz.searchRegulations(q)) ?? []
                if !Task.isCancelled { regs = r }
            case .clue:
                let project = model.sjzPin.project
                let r = project.isEmpty ? [] : ((try? await model.sjz.captures(project: project, kind: "clue", query: q, limit: 30)) ?? [])
                if !Task.isCancelled { clues = r }
            }
        }
    }

    /// 回车：和输入完全一致的就钉住它；否则用输入的文字新建（线索：只剩一条结果时钉住它）
    private func commit(_ kind: SjzPinKind) {
        let q = query.trimmed
        switch kind {
        case .note:
            if let n = notes.first(where: { $0.title == q || $0.no == q }) {
                Task { await model.sjzPin(note: n); closePicker() }
            } else if !q.isEmpty {
                Task { await model.sjzCreateNote(q); closePicker() }
            }
        case .regulation:
            if let r = regs.first(where: { $0.name == q }) {
                Task { await model.sjzPin(regulation: r.name); closePicker() }
            } else if !q.isEmpty {
                // 法规名不存在也可以先钉住：之后保存时会以这个名字新建
                Task { await model.sjzPin(regulation: q); closePicker() }
            }
        case .clue:
            if let c = clues.first(where: { $0.id.caseInsensitiveCompare(q) == .orderedSame }) ?? (clues.count == 1 ? clues.first : nil) {
                Task { await model.sjzPin(clue: c); closePicker() }
            }
        }
    }
}
