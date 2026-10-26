import SwiftUI

// MARK: - 笔记详情（右侧面板 / 弹层共用）

struct NoteDetailView: View {
    @EnvironmentObject var model: AppModel
    let noteId: String
    var fallback: NoteInfo?
    var fallbackTitle: String?

    @State private var detail: NoteDetail?
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(detail?.title.nonEmpty ?? fallback?.title ?? fallbackTitle ?? "笔记")
                    .font(.title.bold())
                    .textSelection(.enabled)
                metaLine
                relations
                if let error {
                    ErrorBanner(text: error) { Task { await load() } }
                } else if detail == nil {
                    ProgressView().controlSize(.small)
                }
                if let d = detail {
                    if d.content.isEmpty {
                        Text("（没有文字内容，可能是语音或图片笔记）").foregroundStyle(.tertiary)
                    } else {
                        MarkdownView(text: d.content)
                    }
                    let images = NoteImages.extract(d.raw)
                    if !images.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(images, id: \.self) { RemoteImage(url: $0) }
                        }
                    }
                    Divider()
                    HStack {
                        Button { model.open(noteURL(noteId)) } label: { Label("在闪念贝壳打开", systemImage: "arrow.up.right.square") }
                        Button { model.copy(d.content) } label: { Label("复制正文", systemImage: "doc.on.doc") }
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(AmbientBackground())
        .task(id: noteId) { await load() }
    }

    private var metaLine: some View {
        let day = detail?.day ?? fallback?.day
        let clock = detail?.clock ?? fallback?.clock
        let tags = detail?.tags ?? fallback?.tags ?? []
        return HStack(spacing: 8) {
            if let day { Text(Day.label(day) + (clock.map { " " + $0 } ?? "")).foregroundStyle(.secondary) }
            ForEach(tags, id: \.self) { TagChip(text: "#" + $0.trimmingCharacters(in: CharacterSet(charactersIn: "#"))) }
        }
        .font(.callout)
    }

    /// 这篇笔记在项目 / 任务里的身份：任务笔记 → 关联任务卡；项目主页 → 项目入口
    @ViewBuilder private var relations: some View {
        if let link = model.taskOfNote(noteId) {
            LinkedTaskCard(taskId: link.taskId, ref: link.ref)
        }
        if let keyword = model.projectOfHome(noteId) {
            Button { model.goToProject(keyword) } label: {
                HStack {
                    Image(systemName: "house").foregroundStyle(Brand.orange)
                    Text("「\(keyword)」的项目主页").font(.callout)
                    Spacer()
                    Text("查看项目").font(.callout).foregroundStyle(.secondary)
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                }
                .padding(12)
                .glassCard(radius: 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func load() async {
        error = nil
        do { detail = try await model.noteDetail(noteId) }
        catch { self.error = error.localizedDescription }
    }
}

/// 任务笔记顶部的「关联任务」卡：任务标题 / 日期 / 状态，一键看任务、完成任务
struct LinkedTaskCard: View {
    @EnvironmentObject var model: AppModel
    let taskId: String
    let ref: TaskNoteRef

    @State private var task: DidaTask?
    @State private var loading = true

    private var live: DidaTask? { model.localTask(taskId) ?? task }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            if let t = live {
                Button {
                    Task { await model.complete(t) }
                } label: {
                    Image(systemName: t.done ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 22))
                        .foregroundStyle(t.done ? Color.green : .secondary)
                }
                .buttonStyle(.plain)
                .disabled(t.done)
                VStack(alignment: .leading, spacing: 2) {
                    Text("关联任务").font(.caption).foregroundStyle(.secondary)
                    Text(t.cleanTitle).font(.body.weight(.medium)).strikethrough(t.done).lineLimit(2)
                    HStack(spacing: 6) {
                        if let d = t.date {
                            let late = !t.done && d < Day.today()
                            Text(Day.label(d) + (t.time.map { " " + $0 } ?? "")).font(.caption).foregroundStyle(late ? .red : .secondary)
                        }
                        if t.done { Text("已完成").font(.caption).foregroundStyle(.green) }
                        if ref.archived == true { Text("已交付").font(.caption).foregroundStyle(.green) }
                    }
                }
                Spacer()
                Button("查看任务") { model.openTask(t) }.buttonStyle(.bordered)
            } else if loading {
                ProgressView().controlSize(.small)
                Text("正在查找关联任务…").font(.callout).foregroundStyle(.secondary)
                Spacer()
            } else {
                Image(systemName: "link").foregroundStyle(.tertiary)
                Text("这是一篇任务笔记，但没有找到对应的滴答任务（可能已删除）").font(.callout).foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(12)
        .glassCard(radius: 14)
        .task(id: taskId) {
            loading = true
            task = await model.findTask(taskId)
            loading = false
        }
    }
}

/// 弹层：笔记 / 任务详情，带返回栈
struct DetailSheet: View {
    @EnvironmentObject var model: AppModel

    /// 标题行不再单独成一条带分割线的栏：内容直接铺满，返回 / 关闭浮在左右上角的小胶囊里
    var body: some View {
        Group {
            switch model.sheetStack.last {
            case let .note(r): NoteDetailView(noteId: r.id, fallbackTitle: r.fallbackTitle).id(r)
            case let .task(t): TaskDetailView(task: t).id(t.id)
            case nil: Color.clear
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { Color.clear.frame(height: 30) }
        .overlay(alignment: .top) {
            HStack {
                if model.sheetStack.count > 1 {
                    Button { model.popSheet() } label: { Label("返回", systemImage: "chevron.left") }
                        .buttonStyle(FloatingChipStyle())
                }
                Spacer()
                Button { model.closeSheets() } label: { Label("关闭", systemImage: "xmark") }
                    .buttonStyle(FloatingChipStyle())
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 14).padding(.top, 10)
        }
        .frame(minWidth: 660, idealWidth: 740, minHeight: 560, idealHeight: 680)
    }
}

/// 浮在内容上的小胶囊按钮（半透明磨砂）
struct FloatingChipStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 10).frame(height: 26)
            .background(.regularMaterial, in: Capsule())
            .overlay { Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5) }
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

extension String {
    var nonEmpty: String? { trimmed.isEmpty ? nil : self }
}
