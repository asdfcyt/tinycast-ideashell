import SwiftUI

/// 项目与专注：一个页面。左边是列表（最上面是「专注」，下面是各个项目），右边跟着选中的那一项走——
/// 选「专注」是计时环，选项目是项目详情（相关待办旁边有「专注」按钮，点一下回到计时环并带上这个任务）。
struct ProjectsView: View {
    @EnvironmentObject var model: AppModel
    private var selected: String? { model.selectedProject }

    private var projects: [Project] {
        let order: [ProjectStatus: Int] = [.ACTIVE: 0, .SHORT: 1, .LONG: 2, .PAUSED: 3]
        return model.projects.sorted {
            let a = order[$0.projectStatus] ?? 9, b = order[$1.projectStatus] ?? 9
            return a != b ? a < b : $0.keyword.localizedCompare($1.keyword) == .orderedAscending
        }
    }

    var body: some View {
        TwoPane(leadingFraction: 0.28, leadingMin: 230, leadingMax: 340, trailingMin: 420) {
            VStack(spacing: 0) {
                FocusEntryRow(focus: model.focus, selected: selected == nil) { model.selectedProject = nil }
                    .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 6)

                HStack {
                    Text("项目").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    if model.backupLoading { ProgressView().controlSize(.mini) }
                    Spacer()
                }
                .padding(.horizontal, 18).padding(.top, 6).padding(.bottom, 2)

                if let e = model.backupError { ErrorBanner(text: e) { Task { await model.loadBackup() } }.padding(8) }
                if projects.isEmpty {
                    EmptyHint(
                        icon: "folder",
                        title: model.backupLoading ? "正在读取手机备份…" : "还没有项目",
                        detail: "项目来自手机端写进闪念贝壳的「拾忆备份」笔记。在手机上点「备份到闪念贝壳」后，回到这里刷新。"
                    )
                } else {
                    List(selection: $model.selectedProject) {
                        ForEach(projects) { p in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(p.keyword).font(.body.weight(.medium))
                                    if let n = p.next, !n.trimmed.isEmpty {
                                        Text(n).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                                Spacer()
                                TagChip(text: p.projectStatus.label, tint: statusColor(p.projectStatus))
                            }
                            .padding(.vertical, 2)
                            .tag(p.keyword)
                        }
                    }
                    .listStyle(.inset)
        .scrollContentBackground(.hidden)
                }
                if let d = model.backup?.exportedDate {
                    Text("备份导出于 " + d.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption).foregroundStyle(.tertiary).padding(8)
                }
            }
        } trailing: {
            Group {
                if let k = selected, let p = model.projects.first(where: { $0.keyword == k }) {
                    ProjectDetailView(project: p).id(k)
                } else {
                    FocusPage()
                }
            }
        }
    }

    private func statusColor(_ s: ProjectStatus) -> Color {
        switch s {
        case .ACTIVE: return .green
        case .SHORT: return .blue
        case .LONG: return .purple
        case .PAUSED: return .gray
        }
    }
}

/// 列表最上面的「专注」入口：进行中时显示倒计时，平时显示今天专注了多久
private struct FocusEntryRow: View {
    @ObservedObject var focus: FocusStore
    let selected: Bool
    let action: () -> Void

    private var nowMs: Int64 { Int64(focus.now.timeIntervalSince1970 * 1000) }

    private var subtitle: String {
        if let run = focus.run {
            let s = Int((Double(max(run.remainingMs(nowMs), 0)) / 1000).rounded(.up))
            let clock = String(format: "%02d:%02d", s / 60, s % 60)
            return (run.paused ? "已暂停 " : "") + clock + " · " + (run.kind.isBreak ? run.kind.label : (run.title.isEmpty ? "自由专注" : run.title))
        }
        if let m = focus.summary?.todayMin, m > 0 { return "今天 " + FocusParser.formatMinutes(m) }
        return "开始一个番茄"
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: focus.run == nil ? "timer" : "timer.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(Brand.orange)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text("专注").font(.body.weight(.semibold))
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Brand.orange.opacity(0.16) : Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected ? Brand.orange.opacity(0.7) : .clear, lineWidth: 1.2))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct ProjectDetailView: View {
    @EnvironmentObject var model: AppModel
    let project: Project

    @State private var mentions: [NoteInfo] = []
    @State private var loading = false
    @State private var error: String?

    private var ws: Workspace { model.backup?.workspace ?? Workspace() }

    private var lastMention: String? { mentions.compactMap(\.day).max() }

    private var taskNotes: [(key: String, ref: TaskNoteRef)] {
        model.allTaskNotes
            .filter { ($0.value.project ?? "").lowercased() == project.keyword.lowercased() }
            .sorted { ($0.value.createdAt ?? 0) > ($1.value.createdAt ?? 0) }
            .map { ($0.key, $0.value) }
    }

    private var openTasks: [DidaTask] {
        guard let ov = model.overview else { return [] }
        return (ov.overdue + ov.upcoming + ov.undated).filter { project.matches($0.title, tags: $0.tags) }
    }

    @State private var showReplan = false

    /// 一键推迟：把这个项目里有日期的未完成待办整体往后顺延（规则同安卓端：逾期的从今天起算，保留时间点，重复任务不动）
    private var postponeMenu: some View {
        let movable = openTasks.filter { $0.date != nil && ($0.repeatFlag ?? "").isEmpty }
        return HStack(spacing: 10) {
            Menu {
                ForEach([("1 天", 1), ("2 天", 2), ("3 天", 3), ("1 周", 7), ("2 周", 14)], id: \.1) { c in
                    Button("推迟 \(c.0)") { Task { await model.postpone(openTasks, days: c.1) } }
                }
            } label: {
                Label("一键推迟", systemImage: "clock.arrow.circlepath")
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .disabled(movable.isEmpty || model.scheduling)
            .help(movable.isEmpty ? "没有可以推迟的任务：只推迟有日期、且不是重复的未完成任务" : "把 \(movable.count) 项有日期的待办整体往后顺延")

            Button { showReplan = true } label: { Label("重新规划", systemImage: "calendar.badge.clock") }
                .buttonStyle(.borderless)
                .disabled(model.scheduling)
        }
        .font(.callout)
        .sheet(isPresented: $showReplan) {
            ReplanSheet(candidates: openTasks, title: "重新规划 · " + project.keyword).environmentObject(model)
        }
    }

    private var focusLast30: Int {
        let from = Day.add(Day.today(), days: -29)
        return ws.focusLog.filter { $0.project.lowercased() == project.keyword.lowercased() && Day.string($0.startDate) >= from }
            .reduce(0) { $0 + $1.minutes }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                statsRow
                if let error { ErrorBanner(text: error) { Task { await load() } } }

                if let home = ws.homes[project.keyword] {
                    Button { model.openNote(home, title: project.keyword + " · 项目主页") } label: {
                        Label("打开项目主页笔记", systemImage: "house")
                    }
                    .buttonStyle(.bordered)
                }

                if !openTasks.isEmpty {
                    Card {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                SectionTitle(text: "相关待办", count: openTasks.count)
                                Spacer()
                                postponeMenu
                            }
                            ForEach(openTasks.prefix(10)) { t in
                                HStack(spacing: 6) {
                                    TaskRow(task: t, showDate: true)
                                    Button {
                                        model.focus.attach(t)
                                        model.selectedProject = nil
                                    } label: { Image(systemName: "play.circle.fill").font(.system(size: 18)).foregroundStyle(Brand.orange) }
                                        .buttonStyle(.plain)
                                        .help("专注这个任务")
                                }
                            }
                        }
                    }
                }

                if !taskNotes.isEmpty {
                    Card {
                        VStack(alignment: .leading, spacing: 6) {
                            SectionTitle(text: "任务笔记", count: taskNotes.count)
                            ForEach(taskNotes, id: \.key) { item in
                                Button { model.openNote(item.ref.noteId, title: item.ref.deliverable) } label: {
                                    HStack {
                                        Image(systemName: item.ref.archived == true ? "checkmark.seal" : "doc.text")
                                            .foregroundStyle(item.ref.archived == true ? Color.green : .secondary)
                                        Text(item.ref.deliverable?.nonEmpty ?? "任务笔记").lineLimit(1)
                                        Spacer()
                                        if let c = item.ref.createdAt {
                                            Text(Date(timeIntervalSince1970: Double(c) / 1000).formatted(.dateTime.month().day()))
                                                .font(.caption).foregroundStyle(.tertiary)
                                        }
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            SectionTitle(text: "提及的笔记", count: loading ? nil : mentions.count)
                            if loading { ProgressView().controlSize(.small) }
                        }
                        if mentions.isEmpty && !loading {
                            Text("没有找到提到「\(project.terms.joined(separator: "」「"))」的笔记").foregroundStyle(.secondary)
                        }
                        ForEach(mentions) { n in
                            NoteRow(note: n, showDay: true).onTapGesture { model.openNote(n.id, title: n.title) }
                            if n.id != mentions.last?.id { Divider() }
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 780, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(AmbientBackground())
        .task(id: project.keyword) { await load() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(project.keyword).font(.largeTitle.bold())
                TagChip(text: project.projectStatus.label, tint: project.projectStatus == .PAUSED ? .gray : .green)
            }
            if let n = project.next, !n.trimmed.isEmpty {
                Label(n, systemImage: "arrow.turn.down.right").font(.body).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if !(project.tags ?? []).isEmpty {
                HStack(spacing: 4) { ForEach(project.tags ?? [], id: \.self) { TagChip(text: "#" + $0) } }
            }
        }
    }

    private var statsRow: some View {
        HStack(spacing: 12) {
            StatTile(value: lastMentionText, label: "最近提及", tint: isStale ? .orange : .primary)
            StatTile(value: loading ? "…" : "\(mentions.count)", label: "提及的笔记")
            StatTile(value: "\(taskNotes.count)", label: "任务笔记")
            StatTile(value: focusLast30 > 0 ? "\(focusLast30 / 60)h\(focusLast30 % 60)m" : "–", label: "近 30 天专注")
        }
    }

    private var isStale: Bool {
        guard let d = lastMention else { return false }
        return Day.diff(d, Day.today()) > project.stale && project.projectStatus != .PAUSED
    }

    private var lastMentionText: String {
        if loading && mentions.isEmpty { return "…" }
        guard let d = lastMention else { return "–" }
        let n = Day.diff(d, Day.today())
        return n <= 0 ? "今天" : "\(n) 天前"
    }

    private func load() async {
        guard model.hasIdeashell else { return }
        // 5 分钟内切回来直接用上次的结果，不再为每个关键词各搜一遍
        if let hit = model.mentionCache[project.keyword], Date().timeIntervalSince(hit.at) < 300 {
            mentions = hit.notes
            return
        }
        loading = true
        error = nil
        defer { loading = false }
        let terms = Array(project.terms.prefix(4))
        var all: [NoteInfo] = []
        var firstError: Error?
        let api = model.ideashell
        await withTaskGroup(of: Result<[NoteInfo], Error>.self) { group in
            for t in terms {
                group.addTask {
                    do { return .success(try await api.searchNotes(t, limit: 20)) }
                    catch { return .failure(error) }
                }
            }
            for await r in group {
                switch r {
                case let .success(ns): all += ns
                case let .failure(e): firstError = e
                }
            }
        }
        var seen = Set<String>()
        mentions = all
            .filter { !BackupService.isBackupNote($0) && seen.insert($0.id).inserted }
            .filter { project.matches($0.text ?? ($0.title + " " + ($0.summary ?? "")), tags: $0.tags) }
            .sorted { ($0.createdAt ?? "") > ($1.createdAt ?? "") }
        if mentions.isEmpty, let e = firstError { error = e.localizedDescription }
        else { model.mentionCache[project.keyword] = (Date(), mentions) }
    }
}
