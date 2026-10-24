import SwiftUI

/// 灵动岛展开页里的「结审」区：钉住的取证单 / 法规。
/// 钉住后，拖进岛的证据 / 法规 / 线索都以它为准；取证单、法规都可以搜索，搜不到就直接新建。
struct SjzPinStrip: View {
    @EnvironmentObject var model: AppModel

    private enum Kind { case note, regulation }

    @State private var picking: Kind?
    @State private var query = ""
    @State private var notes: [SjzNoteHit] = []
    @State private var regs: [SjzRegHit] = []
    @State private var searching = false
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var focused: Bool

    private var pin: SjzPin { model.sjzPin }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            pinRow(.note)
            pinRow(.regulation)
            if let kind = picking { picker(kind) }
        }
        .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 8)
        .task {
            await model.refreshSjzTarget()
        }
    }

    // MARK: 钉住的取证单 / 法规

    private func pinRow(_ kind: Kind) -> some View {
        let isNote = kind == .note
        let value = isNote ? pin.noteLabel : pin.regulation
        let active = picking == kind
        return HStack(spacing: 6) {
            Text(isNote ? "证据" : "法规").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
                .frame(width: 26, alignment: .leading)
            HStack(spacing: 5) {
                Image(systemName: isNote ? "doc.text" : "book.closed").font(.system(size: 10))
                    .foregroundStyle(value.isEmpty ? Color.secondary : Brand.orange)
                Text(value.isEmpty ? (pin.project.isEmpty ? "请先在设置里钉住项目" : (isNote ? "未钉住 · 存为单独证据文件" : "未钉住 · 保存时自动取名并新建")) : value)
                    .font(.system(size: 11.5)).lineLimit(1)
                    .foregroundStyle(value.isEmpty ? Color.secondary : Color.primary)
                Spacer(minLength: 0)
                if !value.isEmpty {
                    Button {
                        Task { isNote ? await model.sjzUnpinNote() : await model.sjzUnpinRegulation() }
                    } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(.tertiary) }
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
            .buttonStyle(.plain).help(isNote ? "搜索或新建取证单" : "搜索或新建法规")
            .disabled(pin.project.isEmpty)
        }
    }

    // MARK: 搜索 / 新建

    private func picker(_ kind: Kind) -> some View {
        let isNote = kind == .note
        let q = query.trimmed
        let exact = isNote ? notes.contains { $0.title == q || $0.no == q } : regs.contains { $0.name == q }
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 10)).foregroundStyle(.secondary)
                TextField(isNote ? "搜索取证单编号或标题，回车可新建" : "搜索项目法规，或输入法规名新建",
                          text: $query)
                    .textFieldStyle(.plain).font(.system(size: 12)).focused($focused)
                    .onSubmit { commit(kind) }
                    .onChange(of: query) { _, _ in scheduleSearch(kind) }
                if searching { ProgressView().controlSize(.mini) }
            }
            .padding(.horizontal, 8).frame(height: 28)
            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7, style: .continuous))

            if isNote {
                ForEach(notes.prefix(5)) { n in
                    resultRow(icon: "doc.text", title: n.no.isEmpty ? n.title : "\(n.no) \(n.title)", sub: n.status) {
                        Task { await model.sjzPin(note: n); closePicker() }
                    }
                }
            } else {
                ForEach(regs.prefix(5)) { r in
                    resultRow(icon: "book.closed", title: r.name, sub: r.clause) {
                        Task { await model.sjzPin(regulation: r.name); closePicker() }
                    }
                }
            }
            if !q.isEmpty, !exact {
                resultRow(icon: "plus.circle.fill", title: isNote ? "新建取证单「\(q)」并钉住" : "新建法规「\(q)」并钉住", sub: "", tint: Brand.orange) {
                    commit(kind)
                }
            } else if q.isEmpty, (isNote ? notes.isEmpty : regs.isEmpty), !searching {
                Text(isNote ? "还没有取证单：输入标题即可新建" : "项目里还没有法规：输入法规名即可钉住 / 新建")
                    .font(.caption).foregroundStyle(.tertiary).padding(.horizontal, 4)
            }
        }
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

    private func toggle(_ kind: Kind) {
        if picking == kind { closePicker(); return }
        picking = kind
        query = ""
        notes = []; regs = []
        scheduleSearch(kind, immediately: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { focused = true }
    }

    private func closePicker() {
        picking = nil
        query = ""
        searchTask?.cancel()
    }

    private func scheduleSearch(_ kind: Kind, immediately: Bool = false) {
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
            }
        }
    }

    /// 回车：和输入完全一致的就钉住它；否则用输入的文字新建
    private func commit(_ kind: Kind) {
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
        }
    }
}
