import AppKit
import SwiftUI

/// 菜单栏上的小标签：平时是「今天 N · 逾期 M」；在专注 / 休息时变成倒计时
struct MenuBarLabel: View {
    @EnvironmentObject var model: AppModel

    var body: some View { LabelContent(focus: model.focus) }

    private struct LabelContent: View {
        @EnvironmentObject var model: AppModel
        @ObservedObject var focus: FocusStore

        var body: some View {
            HStack(spacing: 4) {
                if let r = focus.run {
                    let ms = r.remainingMs(Int64(focus.now.timeIntervalSince1970 * 1000))
                    let left = max(Int(ms / 1000), 0)
                    Image(systemName: r.paused ? "pause.fill" : (r.kind.isBreak ? "cup.and.saucer.fill" : "timer"))
                    Text(String(format: "%02d:%02d", left / 60, left % 60)).monospacedDigit()
                } else {
                    Image(systemName: "checklist")
                    if model.hasDida, let ov = model.overview {
                        Text("\(ov.todayTasks().count)" + (ov.overdue.isEmpty ? "" : " · \(ov.overdue.count)"))
                    }
                }
            }
            .task { model.start() }
        }
    }
}

/// 菜单栏小组件：今天 N · 逾期 M，点圆圈直接完成。
/// 顶部一行放标题和图标按钮（快速记录 / 刷新 / 打开拾忆 / 退出），下面是三项小统计、专注条和紧凑的待办列表。
struct MenuBarView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var adding = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let ov = model.overview, model.hasDida { stats(ov) }
            Divider()
            MenuFocus(focus: model.focus)
            if adding {
                QuickAddView(compact: true).environmentObject(model)
            } else if !model.hasDida {
                Text("还没有填写滴答清单 API 口令").foregroundStyle(.secondary).padding(14)
            } else if let ov = model.overview {
                tasks(ov)
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(20)
            }
        }
        .frame(width: 380)
        .task { model.start() }
        .onAppear { refreshIfNeeded() }
        // 弹窗每次打开（窗口变成 key）都刷新一次，不用等定时器
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in refreshIfNeeded() }
    }

    @State private var lastRefresh = Date.distantPast

    private func refreshIfNeeded() {
        guard model.hasDida, Date().timeIntervalSince(lastRefresh) > 3 else { return }
        lastRefresh = Date()
        Task {
            await model.loadOverview(silent: true)
            await model.focus.refresh()
        }
    }

    /// 正在专注 / 休息时，弹窗顶部是计时条；没在计时就是一行「开始专注」
    private struct MenuFocus: View {
        @EnvironmentObject var model: AppModel
        @ObservedObject var focus: FocusStore
        var body: some View {
            VStack(spacing: 0) {
                if focus.run != nil {
                    FocusRunBar(focus: focus).padding(.horizontal, 12).padding(.vertical, 8)
                } else {
                    HStack(spacing: 8) {
                        if let b = focus.pendingBreak {
                            Button { focus.start() } label: {
                                Label("开始\(b.label) \(focus.minutes) 分钟", systemImage: "cup.and.saucer.fill").font(.callout.weight(.medium))
                            }
                            .buttonStyle(.borderless)
                            Button("跳过") { focus.skipBreak() }
                                .buttonStyle(.borderless).font(.caption).foregroundStyle(.secondary)
                                .help("跳过休息，直接专注")
                        } else {
                            Button { focus.quickFocus(focus.minutes) } label: {
                                Label("开始专注 \(focus.minutes) 分钟", systemImage: "play.fill").font(.callout.weight(.medium))
                            }
                            .buttonStyle(.borderless)
                        }
                        Spacer(minLength: 6)
                        // 关联待办：选了之后「开始专注」就会绑定它
                        FocusTaskMenu(focus: focus) {
                            HStack(spacing: 4) {
                                Image(systemName: focus.task == nil ? "link" : "link.circle.fill")
                                    .foregroundStyle(focus.task == nil ? Color.secondary : Brand.orange)
                                Text(focus.task?.cleanTitle ?? "关联待办").lineLimit(1).frame(maxWidth: 150, alignment: .trailing)
                                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9)).foregroundStyle(.tertiary)
                            }
                            .font(.caption).foregroundStyle(.secondary)
                        }
                        .fixedSize()
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                }
                Divider()
            }
        }
    }

    private func iconButton(_ icon: String, _ help: String, tint: Color = .secondary, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 26, height: 26)
                .background(Color.primary.opacity(0.06), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var header: some View {
        HStack(spacing: 6) {
            let ov = model.overview
            VStack(alignment: .leading, spacing: 1) {
                Text("今天 \(ov?.todayTasks().count ?? 0) · 逾期 \(ov?.overdue.count ?? 0)").font(.system(size: 15, weight: .semibold))
                Text(Day.label(Day.today()) + " " + Date().formatted(.dateTime.month().day().weekday())).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if model.todosLoading { ProgressView().controlSize(.small) }
            iconButton(adding ? "xmark" : "plus", adding ? "收起" : "快速记录") { adding.toggle() }
            iconButton("arrow.clockwise", "刷新") { Task { await model.loadOverview() } }
            iconButton("macwindow", "打开拾忆") {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "main")
            }
            iconButton("power", "退出") { NSApp.terminate(nil) }
        }
        .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 8)
    }

    /// 三项小统计：今天已完成 / 今天专注 / 今天的笔记
    private func stats(_ ov: DidaOverview) -> some View {
        let today = Day.today()
        let done = ov.done.filter { $0.completedDate.map { Day.string($0) == today } ?? false }.count
        let total = ov.todayTasks().count + done
        let notes = model.timeline.filter { $0.day == today }.count
        let focusMin = model.focus.summary?.todayMin
        return HStack(spacing: 0) {
            stat("checkmark.circle", "\(done)/\(total)", "已完成", .green)
            stat("timer", focusMin.map(FocusParser.formatMinutes) ?? "–", "专注", Brand.orange)
            stat("note.text", "\(notes)", "笔记", .blue)
        }
        .padding(.horizontal, 12).padding(.bottom, 8)
    }

    private func stat(_ icon: String, _ value: String, _ label: String, _ tint: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 12)).foregroundStyle(tint)
            Text(value).font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 全部直接铺开，不用滚动条：今天的全部显示；逾期最多 6 条、收集箱最多 3 条，其余提示去主窗口看
    private func tasks(_ ov: DidaOverview) -> some View {
        let overdue = ov.overdue.sorted { ($0.date ?? "") < ($1.date ?? "") }
        let today = ov.todayTasks().sorted { ($0.time ?? "99:99") < ($1.time ?? "99:99") }
        let inbox = ov.undated
        return VStack(alignment: .leading, spacing: 0) {
            if let e = model.todosError { Text(e).font(.caption).foregroundStyle(.orange).padding(.horizontal, 12).padding(.vertical, 6) }
            sectionLabel("今天", today.count, .primary)
            if today.isEmpty {
                Text("今天没有待办").font(.callout).foregroundStyle(.tertiary).padding(.horizontal, 12).padding(.vertical, 4)
            }
            ForEach(today) { MenuTaskRow(task: $0) }
            if !overdue.isEmpty {
                sectionLabel("逾期", overdue.count, .red)
                ForEach(overdue.prefix(6)) { MenuTaskRow(task: $0, overdue: true) }
                if overdue.count > 6 { more(overdue.count - 6) }
            }
            if !inbox.isEmpty {
                sectionLabel("收集箱", inbox.count, .secondary)
                ForEach(inbox.prefix(3)) { MenuTaskRow(task: $0, inbox: true) }
                if inbox.count > 3 { more(inbox.count - 3) }
            }
        }
        .padding(.vertical, 4)
    }

    private func more(_ n: Int) -> some View {
        Text("还有 \(n) 个，在拾忆里查看").font(.caption).foregroundStyle(.tertiary)
            .padding(.horizontal, 12).padding(.vertical, 3)
    }

    private func sectionLabel(_ text: String, _ count: Int, _ tint: Color) -> some View {
        HStack(spacing: 5) {
            Text(text).font(.caption.weight(.bold)).foregroundStyle(tint)
            Text("\(count)").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 2)
    }
}

/// 菜单栏里的一行待办：圆圈 + 标题（一行）+ 右边的时间 / 逾期天数 / 项目
private struct MenuTaskRow: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    let task: DidaTask
    var overdue = false
    var inbox = false
    @State private var hover = false

    private var tint: Color {
        switch task.priority {
        case 5: return .red
        case 3: return .orange
        case 1: return .blue
        default: return Color.secondary.opacity(0.7)
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Button { Task { await model.complete(task) } } label: {
                Image(systemName: "circle").font(.system(size: 15)).foregroundStyle(tint)
            }
            .buttonStyle(.plain).help("完成")
            VStack(alignment: .leading, spacing: 0) {
                Text(task.cleanTitle).font(.system(size: 13)).lineLimit(1)
                let sub = subtitle
                if !sub.isEmpty { Text(sub).font(.system(size: 10.5)).foregroundStyle(.tertiary).lineLimit(1) }
            }
            Spacer(minLength: 6)
            if overdue, let d = task.date {
                Text("逾期 \(max(1, Day.diff(d, Day.today()))) 天").font(.caption2.weight(.medium)).foregroundStyle(.red)
            } else if let t = task.time {
                Text(t).font(.caption.weight(.medium)).foregroundStyle(.secondary).monospacedDigit()
            }
            // 悬停时出现：用这件待办开始一个专注
            if hover, model.focus.run == nil {
                Button {
                    model.focus.attach(task)
                    model.focus.quickFocus(model.focus.focusMinutes)
                } label: {
                    Image(systemName: "play.fill").font(.system(size: 10, weight: .bold)).foregroundStyle(Brand.brown)
                        .frame(width: 22, height: 22).background(Brand.orange, in: Circle())
                }
                .buttonStyle(.plain).help("专注这件事")
            }
        }
        .onHover { hover = $0 }
        .padding(.horizontal, 12).padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "main")
            model.openTask(task)
        }
    }

    /// 第二行：项目 · 标签 · 备注开头
    private var subtitle: String {
        var parts: [String] = []
        if let p = model.overview?.projectName(task.projectId) { parts.append(p) }
        if task.repeatFlag != nil { parts.append("重复") }
        parts.append(contentsOf: task.tags.prefix(2).map { "#" + $0 })
        let c = task.content.trimmed.replacingOccurrences(of: "\n", with: " ")
        if !c.isEmpty { parts.append(String(c.prefix(24))) }
        return parts.joined(separator: " · ")
    }
}
