import SwiftUI

/// 重新规划：弹窗 + 日历。
/// 调研了 Todoist（逾期区的「重新安排」+ 日期选择器）、Sunsama（每天容量、顺延 / 推迟）、Morgen（先出方案、预览、确认才生效）、Motion（全自动）：
/// 这里取「先预排、可预览、可手动改、确认才写入」。
/// 左边是待安排的任务（逾期的在最前面）；右边是月历，每天显示已有几件 + 这次排进去几件，超出每天上限会变红。
/// 点一个任务再点日历上的某天，或者直接把任务拖到某天；「智能排期」按优先级把逾期 / 无日期的任务填进最近有空的日子。
struct ReplanSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    /// 要排的任务（逾期 / 无日期 / 项目里的相关待办）
    let candidates: [DidaTask]
    var title = "重新规划"
    /// 在某个项目里规划时的项目名：AI 规划只动这个项目的待办，新任务归到这个项目
    var scopeName: String?

    @State private var draft: [String: String] = [:]
    @State private var selected: String?
    @State private var focusDay: String?
    @State private var month = Day.startOfDay(Date())
    @State private var perDay = 5
    @State private var skipWeekends = false
    @State private var occupied: [DidaTask] = []
    @State private var leftover = 0
    @State private var ready = false
    @State private var applying = false
    // AI 排期
    @State private var aiBusy = false
    @State private var aiError: String?
    @State private var aiResult: AIPlanResult?
    @State private var aiReasons: [String: String] = [:]
    @State private var aiBackup: [String: String]?
    @State private var showAIPlan = false
    /// 点了智能排期却没有可排的任务
    @State private var emptyHint = false

    private var today: String { Day.today() }

    // MARK: - 数据

    private func rank(_ t: DidaTask) -> Int {
        guard let d = t.date else { return 1 }
        return d < today ? 0 : 2
    }

    /// 待安排：逾期（最早的在前）→ 无日期 → 已有未来日期的
    private var items: [DidaTask] {
        candidates.filter { ($0.repeatFlag ?? "").isEmpty && !$0.done }.sorted { a, b in
            let ra = rank(a), rb = rank(b)
            if ra != rb { return ra < rb }
            let da = a.date ?? "9999", db = b.date ?? "9999"
            if da != db { return da < db }
            return a.priority > b.priority
        }
    }

    /// 不参与排期、已经有日期的未完成任务（用来算每天已经有几件）
    private func fixedTasks(_ ids: Set<String>) -> [DidaTask] {
        var seen = Set<String>()
        var out: [DidaTask] = []
        for t in (model.overview?.upcoming ?? []) + occupied where !t.done && t.date != nil && !ids.contains(t.id) && seen.insert(t.id).inserted {
            out.append(t)
        }
        return out
    }

    /// 每天：(原有几件, 这次排进来几件)
    private func loads(_ items: [DidaTask], fixed: [DidaTask]) -> [String: (fixed: Int, planned: Int)] {
        var out: [String: (fixed: Int, planned: Int)] = [:]
        for t in fixed { if let d = t.date, d >= today { out[d, default: (0, 0)].fixed += 1 } }
        for t in items where draft[t.id] == nil {
            if let d = t.date, d >= today { out[d, default: (0, 0)].fixed += 1 }
        }
        for (_, d) in draft { out[d, default: (0, 0)].planned += 1 }
        return out
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日 EEE"
        return f
    }()

    private func dayText(_ d: String) -> String {
        guard let date = Day.parse(d) else { return d }
        let p = Self.dayFormatter.string(from: date)
        switch Day.diff(today, d) {
        case 0: return "今天 · " + p
        case 1: return "明天 · " + p
        default: return p
        }
    }

    // MARK: - 操作

    private func assign(_ id: String, to day: String) {
        guard day >= today, items.contains(where: { $0.id == id }) else { return }
        draft[id] = day
        focusDay = day
        selected = nextUnassigned(after: id)
    }

    private func unassign(_ id: String) {
        draft.removeValue(forKey: id)
        selected = id
    }

    private func nextUnassigned(after id: String) -> String? {
        let list = items
        let start = (list.firstIndex { $0.id == id } ?? -1) + 1
        return (list[start...] + list[..<min(start, list.count)]).first { draft[$0.id] == nil }?.id
    }

    /// 智能排期：逾期 / 无日期的按「优先级高 → 日期早」填进每天不超过上限的最近一天；已有未来日期的原位不动
    private func smart() {
        aiResult = nil; aiReasons = [:]; aiBackup = nil; aiError = nil
        let all = items
        let movable = all.filter { rank($0) < 2 }
        let stay = all.filter { rank($0) == 2 }
        let ids = Set(all.map(\.id))
        let plan = Scheduler.plan(
            tasks: movable, existing: fixedTasks(ids) + stay,
            options: ScheduleOptions(perDay: perDay, includeOverdue: true, skipWeekends: skipWeekends)
        )
        var d: [String: String] = [:]
        for i in plan.items { d[i.task.id] = i.date }
        draft = d
        leftover = plan.leftover.count
        if let first = plan.items.first?.date {
            focusDay = first
            if let m = Day.parse(first) { month = m }
        }
        selected = all.first { draft[$0.id] == nil }?.id
    }

    /// 智能排期：配置了 AI 模型就用 AI 排，没配置（或 AI 没排成）就按规则排
    private func smartOrAI() {
        // 没有逾期 / 无日期的任务时，排期什么也不会发生：明确告诉用户，而不是没反应
        guard items.contains(where: { rank($0) < 2 }) else {
            withAnimation(.easeOut(duration: 0.2)) { emptyHint = true }
            return
        }
        emptyHint = false
        if model.hasLlm { aiPlan() } else { smart() }
    }

    /// AI 排期：把任务和每天已有的安排交给大模型，得到方案后只放进草稿预览，由用户确认才写入
    private func aiPlan() {
        guard model.hasLlm else { smart(); return }
        let all = items
        let movable = all.filter { rank($0) < 2 }
        guard !movable.isEmpty else { smart(); return }
        let busy = fixedTasks(Set(all.map(\.id))) + all.filter { rank($0) == 2 }
        let backup = draft
        aiBusy = true; aiError = nil
        Task {
            do {
                let r = try await AIPlanner.plan(
                    client: model.llm, tasks: movable, busy: busy, perDay: perDay, skipWeekends: skipWeekends,
                    projectName: { model.overview?.projectName($0) }
                )
                var d: [String: String] = [:]
                var why: [String: String] = [:]
                for i in r.items { d[i.id] = i.date; why[i.id] = i.reason }
                aiBackup = backup
                draft = d
                aiReasons = why
                aiResult = r
                leftover = r.skipped
                if let first = r.items.map(\.date).min() {
                    focusDay = first
                    if let m = Day.parse(first) { month = m }
                }
                selected = all.first { draft[$0.id] == nil }?.id
            } catch {
                // AI 没排成：退回规则排期，并说明原因
                smart()
                aiError = "AI 排期没成功（" + error.localizedDescription + "），已改用规则智能排期。"
            }
            aiBusy = false
        }
    }

    private func undoAI() {
        if let b = aiBackup { draft = b }
        aiResult = nil; aiReasons = [:]; aiBackup = nil
        selected = items.first { draft[$0.id] == nil }?.id
    }

    private func allOverdueToToday() {
        aiResult = nil; aiReasons = [:]; aiBackup = nil
        for t in items where rank(t) == 0 { draft[t.id] = today }
        focusDay = today
        month = Day.startOfDay(Date())
        selected = items.first { draft[$0.id] == nil }?.id
    }

    private func apply() {
        let moves: [(DidaTask, String, String?)] = items.compactMap { t in
            guard let d = draft[t.id] else { return nil }
            // 原来逾期 / 无日期的排成全天；本来就有未来日期的保留时间点
            return (t, d, (t.date ?? "") >= today ? t.time : nil)
        }
        applying = true
        Task {
            await model.applyMoves(moves)
            dismiss()
        }
    }

    // MARK: - 界面

    var body: some View {
        let all = items
        let ids = Set(all.map(\.id))
        let fixed = fixedTasks(ids)
        let load = loads(all, fixed: fixed)
        VStack(spacing: 0) {
            topBar
            Divider()
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    aiCard(all)
                    taskList(all)
                }
                .frame(width: 300)
                Divider()
                VStack(spacing: 0) {
                    calendarHeader
                    calendar(load)
                    Divider().padding(.top, 10)
                    dayDetail(all, fixed: fixed)
                }
                .frame(maxWidth: .infinity)
            }
            Divider()
            bottomBar(all)
        }
        .frame(width: 840, height: 620)
        .sheet(isPresented: $showAIPlan) {
            AIPlanSheet(
                scopeName: scopeName,
                movable: scopeName == nil ? nil : Set(candidates.map(\.id)),
                onApplied: { dismiss() }
            )
            .environmentObject(model)
            .dismissOnOutsideClick()
        }
        .task {
            if model.hasDida {
                occupied = (try? await model.dida.tasksInRange(today, Day.add(today, days: 90))) ?? []
            }
            if !ready {
                ready = true
                smart()
            }
        }
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title3.weight(.bold))
                Text("点任务再点日历，或把任务拖到某天；确认后才会写进滴答")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Button { showAIPlan = true } label: {
                if aiBusy {
                    HStack(spacing: 6) { ProgressView().controlSize(.small); Text("分析中…") }
                } else {
                    Label("AI 规划", systemImage: "sparkles")
                }
            }
            .buttonStyle(.bordered).controlSize(.large).disabled(aiBusy)
            .help(model.hasLlm ? "AI 先看待办和冲突、问你几个问题，再给出总结、改期和拆解好的任务" : "需要先在设置里配置 AI 模型")
            Button { smartOrAI() } label: { Label("智能排期", systemImage: "wand.and.stars") }
                .buttonStyle(.borderedProminent).tint(Brand.orange).controlSize(.large).disabled(aiBusy)
                .help(model.hasLlm ? "已配置 AI 模型：由 AI 按优先级、逾期时间、每天的负载和任务先后顺序来排" : "按优先级和每天的上限自动排；配置 AI 模型后会改用 AI 排")
            Menu {
                Button("逾期的全部放到今天") { allOverdueToToday() }
                Button("清空所有安排") { draft = [:]; aiResult = nil; aiReasons = [:]; selected = items.first?.id }
            } label: {
                Image(systemName: "ellipsis.circle").font(.title3)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    // 左：AI 说明 + 待安排

    /// AI 排期的状态 / 结果说明：告诉用户 AI 怎么排的，确认前可撤销
    @ViewBuilder private func aiCard(_ all: [DidaTask]) -> some View {
        if aiBusy {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("AI 正在分析待办和每天的安排…").font(.callout).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(12).glassCard(radius: 12, tint: Color.purple.opacity(0.10))
            .padding(.horizontal, 12).padding(.top, 12)
        } else if emptyHint {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(.green).frame(width: 18)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("没有需要排期的任务").font(.callout.weight(.bold))
                        Text(all.isEmpty
                             ? "现在没有逾期的、也没有未设日期的待办，不用重新安排。"
                             : "没有逾期或未设日期的待办。下面「已有日期」的任务保持原日期，智能排期不会改动它们。")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Text(all.isEmpty
                             ? "想调整已排好的日程，可以在日历里直接改，或试试「AI 规划」。"
                             : "想挪动它们：点任务再点日历上的某天，或把任务拖过去；也可以试试「AI 规划」。")
                            .font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                HStack(spacing: 14) {
                    if model.hasLlm { Button("AI 规划") { showAIPlan = true } }
                    Button("知道了") { emptyHint = false }
                }
                .buttonStyle(.link).font(.callout)
                .padding(.leading, 26)   // 图标宽 18 + 间距 8：和上面的文字左对齐
            }
            .padding(12).glassCard(radius: 12, tint: Color.green.opacity(0.10))
            .padding(.horizontal, 12).padding(.top, 12)
        } else if let e = aiError {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(e).font(.callout).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                HStack(spacing: 12) {
                    if !model.hasLlm { Button("去设置") { dismiss(); SettingsWindow.show(.ai) }.buttonStyle(.link) }
                    Button("知道了") { aiError = nil }.buttonStyle(.link)
                }
                .font(.callout)
            }
            .padding(12).glassCard(radius: 12, tint: Color.orange.opacity(0.10))
            .padding(.horizontal, 12).padding(.top, 12)
        } else if let r = aiResult {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles").foregroundStyle(.purple)
                    Text("AI 已安排 \(r.items.count) 件").font(.callout.weight(.bold))
                    if r.skipped > 0 { TagChip(text: "\(r.skipped) 件未排", tint: .orange) }
                    Spacer(minLength: 0)
                }
                if !r.summary.isEmpty {
                    Text(r.summary).font(.callout).foregroundStyle(.primary.opacity(0.85))
                        .lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 14) {
                    Button("撤销方案") { undoAI() }
                    Button("收起说明") { aiResult = nil }
                }
                .buttonStyle(.link).font(.callout)
            }
            .padding(12).glassCard(radius: 12, tint: Color.purple.opacity(0.10))
            .padding(.horizontal, 12).padding(.top, 12)
        }
    }

    private func taskList(_ all: [DidaTask]) -> some View {
        let groups: [(String, Color, [DidaTask])] = [
            ("逾期", .red, all.filter { rank($0) == 0 }),
            ("无日期", .secondary, all.filter { rank($0) == 1 }),
            ("已有日期", .secondary, all.filter { rank($0) == 2 }),
        ].filter { !$0.2.isEmpty }
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                if all.isEmpty {
                    Text("没有需要重新安排的待办").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 200)
                }
                ForEach(groups, id: \.0) { g in
                    HStack(spacing: 6) {
                        Text(g.0).font(.subheadline.weight(.bold)).foregroundStyle(g.1)
                        Text("\(g.2.count)").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 4).padding(.top, 8).padding(.bottom, 2)
                    ForEach(g.2) { t in row(t) }
                }
            }
            .padding(12)
        }
        .scrollIndicators(.hidden)
    }

    private func row(_ t: DidaTask) -> some View {
        let isSel = selected == t.id
        let to = draft[t.id]
        return HStack(alignment: .top, spacing: 10) {
            Circle().fill(priorityColor(t.priority)).frame(width: 8, height: 8).padding(.top, 6)
            VStack(alignment: .leading, spacing: 4) {
                Text(t.cleanTitle).font(.callout.weight(.medium)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Text(subtitle(t)).font(.caption).foregroundStyle(rank(t) == 0 ? Color.red : Color.secondary).lineLimit(1)
                    Spacer(minLength: 4)
                    if let to {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.right").font(.system(size: 9, weight: .bold))
                            Text(shortDay(to)).font(.caption.weight(.semibold))
                            Button { unassign(t.id) } label: { Image(systemName: "xmark.circle.fill").font(.caption) }
                                .buttonStyle(.plain).foregroundStyle(.tertiary).help("取消这条安排")
                        }
                        .foregroundStyle(Brand.orangeDeep)
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(Brand.orange.opacity(0.16), in: Capsule())
                    } else {
                        Text("未安排").font(.caption).foregroundStyle(.tertiary)
                    }
                }
                if let why = aiReasons[t.id], !why.isEmpty, to != nil {
                    Text("AI：" + why).font(.caption).foregroundStyle(.purple).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSel ? Brand.orange.opacity(0.14) : Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay { if isSel { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Brand.orange.opacity(0.6), lineWidth: 1) } }
        .contentShape(Rectangle())
        .onTapGesture { selected = t.id }
        .draggable(t.id)
    }

    private func subtitle(_ t: DidaTask) -> String {
        var parts: [String] = []
        if let d = t.date {
            parts.append(d < today ? "逾期 \(max(1, Day.diff(d, today))) 天" : "原定 " + shortDay(d))
        } else {
            parts.append("无日期")
        }
        if let p = model.overview?.projectName(t.projectId) { parts.append(p) }
        return parts.joined(separator: " · ")
    }

    private func shortDay(_ d: String) -> String {
        switch Day.diff(today, d) {
        case 0: return "今天"
        case 1: return "明天"
        default:
            guard let date = Day.parse(d) else { return d }
            let c = Day.cal.dateComponents([.month, .day], from: date)
            return "\(c.month ?? 0)/\(c.day ?? 0)"
        }
    }

    private func priorityColor(_ p: Int) -> Color {
        switch p {
        case 5: return .red
        case 3: return .orange
        case 1: return .blue
        default: return Color.secondary.opacity(0.4)
        }
    }

    // 右：日历

    private var monthTitle: String {
        let c = Day.cal.dateComponents([.year, .month], from: month)
        return "\(c.year ?? 0)年\(c.month ?? 0)月"
    }

    private var canGoBack: Bool {
        !Day.cal.isDate(month, equalTo: Date(), toGranularity: .month)
    }

    @State private var showPrefs = false

    private var calendarHeader: some View {
        HStack(spacing: 6) {
            Button { shiftMonth(-1) } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.borderless).disabled(!canGoBack)
            Text(monthTitle).font(.headline).frame(minWidth: 100)
            Button { shiftMonth(1) } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.borderless)
            Button("今天") { month = Day.startOfDay(Date()); focusDay = today }
                .buttonStyle(.bordered).controlSize(.small)
            Spacer(minLength: 8)
            Button { showPrefs.toggle() } label: {
                Label("每天 \(perDay) 件" + (skipWeekends ? " · 跳过周末" : ""), systemImage: "slider.horizontal.3")
                    .font(.callout)
            }
            .buttonStyle(.bordered).controlSize(.small)
            .popover(isPresented: $showPrefs, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 12) {
                    Stepper(value: $perDay, in: 1 ... 12) {
                        Text("每天最多 \(perDay) 件").monospacedDigit()
                    }
                    Toggle("跳过周末", isOn: $skipWeekends).toggleStyle(.switch)
                    Text("排期时每天不超过这个数；超出的天会在日历上标红。").font(.caption).foregroundStyle(.secondary)
                        .frame(width: 220, alignment: .leading)
                }
                .padding(16)
            }
        }
        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 8)
    }

    private func shiftMonth(_ n: Int) {
        month = Day.cal.date(byAdding: .month, value: n, to: month) ?? month
    }

    private func calendar(_ load: [String: (fixed: Int, planned: Int)]) -> some View {
        let grid = AppModel.calendarGrid(for: month)
        return VStack(spacing: 6) {
            HStack(spacing: 6) {
                ForEach(["一", "二", "三", "四", "五", "六", "日"], id: \.self) { w in
                    Text(w).font(.caption.weight(.semibold)).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                }
            }
            ForEach(0 ..< 6, id: \.self) { r in
                HStack(spacing: 6) {
                    ForEach(0 ..< 7, id: \.self) { c in
                        dayCell(grid[r * 7 + c], load: load)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
    }

    private func dayCell(_ d: String, load: [String: (fixed: Int, planned: Int)]) -> some View {
        let l = load[d] ?? (0, 0)
        let total = l.fixed + l.planned
        let inMonth = Day.cal.isDate(Day.parse(d) ?? Date(), equalTo: month, toGranularity: .month)
        let past = d < today
        let over = total > perDay
        let number = String(Int(d.suffix(2)) ?? 0)
        let fill: Color = over ? Color.red.opacity(0.16) : (l.planned > 0 ? Brand.orange.opacity(0.16) : Color.primary.opacity(0.045))
        return VStack(spacing: 2) {
            Text(number)
                .font(.system(size: 13, weight: d == today ? .bold : .medium))
                .foregroundStyle(d == today ? Brand.orange : Color.primary)
            Group {
                if total == 0 {
                    Text(" ")
                } else if l.planned > 0 {
                    Text("\(total)").foregroundStyle(over ? Color.red : Brand.orangeDeep).fontWeight(.bold)
                } else {
                    Text("\(total)").foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 10))
        }
        .frame(maxWidth: .infinity).frame(height: 42)
        .background(fill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(d == focusDay ? Brand.orange : Color.clear, lineWidth: 1.6)
        }
        .opacity(past ? 0.28 : (inMonth ? 1 : 0.5))
        .contentShape(Rectangle())
        .onTapGesture {
            guard !past else { return }
            if let s = selected { assign(s, to: d) } else { focusDay = d }
        }
        .dropDestination(for: String.self) { ids, _ in
            guard !past, let id = ids.first else { return false }
            assign(id, to: d)
            return true
        }
        .help(past ? "不能排到过去" : "\(dayText(d)) · 原有 \(l.fixed) 件，新排 \(l.planned) 件")
    }

    private func dayDetail(_ all: [DidaTask], fixed: [DidaTask]) -> some View {
        let d = focusDay ?? today
        let existing = fixed.filter { $0.date == d } + all.filter { draft[$0.id] == nil && $0.date == d }
        let planned = all.filter { draft[$0.id] == d }
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(dayText(d)).font(.callout.weight(.bold))
                Spacer()
                Text("原有 \(existing.count) · 新排 \(planned.count)").font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(planned) { t in
                        HStack(spacing: 8) {
                            Circle().fill(Brand.orange).frame(width: 6, height: 6)
                            Text(t.cleanTitle).lineLimit(1)
                            Spacer()
                            Button { unassign(t.id) } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.plain).foregroundStyle(.tertiary)
                        }
                        .font(.callout)
                    }
                    ForEach(existing) { t in
                        HStack(spacing: 8) {
                            Circle().fill(Color.secondary.opacity(0.5)).frame(width: 6, height: 6)
                            Text(t.cleanTitle).lineLimit(1).foregroundStyle(.secondary)
                            Spacer()
                            if let tm = t.time { Text(tm).font(.caption).foregroundStyle(.tertiary).monospacedDigit() }
                        }
                        .font(.callout)
                    }
                    if existing.isEmpty && planned.isEmpty {
                        Text("这天还没有安排").font(.callout).foregroundStyle(.tertiary)
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // 底部

    private func bottomBar(_ all: [DidaTask]) -> some View {
        let unplacedOverdue = all.filter { rank($0) == 0 && draft[$0.id] == nil }.count
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("已安排 \(draft.count) / \(all.count) 件").font(.callout.weight(.semibold))
                if unplacedOverdue > 0 {
                    Text("还有 \(unplacedOverdue) 件逾期没有安排").font(.caption).foregroundStyle(.red)
                } else if leftover > 0 {
                    Text("有 \(leftover) 件没有排进去").font(.caption).foregroundStyle(.orange)
                }
            }
            Spacer()
            Button("取消") { dismiss() }.keyboardShortcut(.cancelAction).controlSize(.large)
            Button {
                apply()
            } label: {
                if applying { ProgressView().controlSize(.small) } else { Text(draft.isEmpty ? "确认应用" : "确认应用（\(draft.count) 件）") }
            }
            .buttonStyle(.borderedProminent).tint(Brand.orange).controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(draft.isEmpty || applying)
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
    }
}
