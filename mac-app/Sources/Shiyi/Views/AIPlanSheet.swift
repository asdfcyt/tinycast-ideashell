import SwiftUI

/// AI 规划助手：① 看待办和冲突 → ② 问几个问题（今天想做什么、时间、取舍…）→ ③ 给出计划：总结、冲突怎么处理、
/// 要改期的待办、拆解出来的新任务。每一项都能取消勾选，点「应用」才写进滴答。
struct AIPlanSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    /// 在某个项目里规划时的项目名（只改这个项目的待办，新任务归到这个项目）
    var scopeName: String?
    var movable: Set<String>?
    var onApplied: () -> Void = {}

    private enum Phase { case loading(String), ask, result, failed }

    @State private var phase: Phase = .loading("AI 正在看你的待办和日程…")
    @State private var ctx: PlanContext?
    @State private var ask: AIAsk?
    @State private var plan: AIDayPlan?
    @State private var error: String?

    @State private var goals = ""
    @State private var picks: [String: Set<String>] = [:]
    @State private var custom: [String: String] = [:]

    @State private var checkedMoves: Set<String> = []
    @State private var checkedNew: Set<UUID> = []
    @State private var applying = false

    private var applyCount: Int { checkedMoves.count + checkedNew.count }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                switch phase {
                case let .loading(text): loadingView(text)
                case .ask: askView
                case .result: resultView
                case .failed: failedView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(width: 600, height: 640)
        .task { await start() }
    }

    // MARK: - 框架

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles").font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                .frame(width: 30, height: 30).background(Color.purple.gradient, in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text("AI 规划" + (scopeName.map { " · " + $0 } ?? "")).font(.title3.weight(.bold))
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { dismiss() } label: { Image(systemName: "xmark") }
                .buttonStyle(FloatingChipStyle()).keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    private var subtitle: String {
        switch phase {
        case .loading: return "先看看你的待办，再问几个问题"
        case .ask: return "按 GTD + OKR 带你过一遍：收集 → 目标 → 澄清 → 优先级 → 容量 → 取舍"
        case .result: return "确认前不会改动滴答，每一项都可以取消勾选"
        case .failed: return "出错了"
        }
    }

    private func loadingView(_ text: String) -> some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(text).font(.callout).foregroundStyle(.secondary)
        }
    }

    private var failedView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(error ?? "出错了").font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            if !model.hasLlm {
                Button("去设置 AI 模型") { dismiss(); model.section = .settings }.buttonStyle(.borderedProminent).tint(Brand.orange)
            }
        }
        .padding(20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            switch phase {
            case .ask:
                Button("跳过提问，直接规划") { Task { await makePlan(skip: true) } }
                Spacer()
                Button { Task { await makePlan(skip: false) } } label: { Label("生成计划", systemImage: "wand.and.stars") }
                    .buttonStyle(.borderedProminent).tint(Brand.orange).keyboardShortcut(.defaultAction)
            case .result:
                Button("重新回答") { phase = .ask }
                Spacer()
                Button("取消") { dismiss() }
                Button {
                    Task { await apply() }
                } label: {
                    if applying { ProgressView().controlSize(.small) } else { Text(applyCount == 0 ? "应用" : "应用（\(applyCount) 项）") }
                }
                .buttonStyle(.borderedProminent).tint(Brand.orange).keyboardShortcut(.defaultAction)
                .disabled(applyCount == 0 || applying)
            case .failed:
                Spacer()
                Button("重试") { Task { await retry() } }.buttonStyle(.borderedProminent).tint(Brand.orange)
            case .loading:
                Spacer()
            }
        }
        .controlSize(.large)
        .padding(.horizontal, 20).padding(.vertical, 12)
    }

    // MARK: - 流程

    private func start() async {
        guard ctx == nil else { return }
        var extra: [DidaTask] = []
        if model.hasDida {
            let today = Day.today()
            extra = (try? await model.dida.tasksInRange(today, Day.add(today, days: 28))) ?? []
        }
        let c = AIAssistant.context(model: model, extra: extra, movable: movable)
        ctx = c
        await loadAsk(c)
    }

    private func loadAsk(_ c: PlanContext) async {
        phase = .loading("AI 正在看你的待办和日程…")
        do {
            ask = try await AIAssistant.ask(model: model, ctx: c, scopeName: scopeName)
            phase = .ask
        } catch {
            self.error = error.localizedDescription
            phase = .failed
        }
    }

    private func retry() async {
        error = nil
        if let c = ctx {
            if ask != nil { await makePlan(skip: false) } else { await loadAsk(c) }
        } else {
            await start()
        }
    }

    private func answers() -> [(question: String, answer: String)] {
        (ask?.questions ?? []).map { q in
            var parts = q.options.filter { picks[q.id]?.contains($0) == true }
            if let c = custom[q.id]?.trimmed, !c.isEmpty { parts.append(c) }
            return (q.text, parts.joined(separator: "；"))
        }
    }

    private func makePlan(skip: Bool) async {
        guard let c = ctx else { return }
        phase = .loading("AI 正在安排…（会考虑冲突、优先级和任务的先后顺序）")
        do {
            let p = try await AIAssistant.plan(
                model: model, ctx: c, goals: goals, answers: skip ? [] : answers(), scopeName: scopeName
            )
            plan = p
            checkedMoves = Set(p.moves.map(\.id))
            checkedNew = Set(p.newTasks.map(\.id))
            phase = .result
        } catch {
            self.error = error.localizedDescription
            phase = .failed
        }
    }

    private func apply() async {
        guard let p = plan else { return }
        applying = true
        await model.applyAIPlan(
            moves: p.moves.filter { checkedMoves.contains($0.id) },
            newTasks: p.newTasks.filter { checkedNew.contains($0.id) }
        )
        applying = false
        dismiss()
        onApplied()
    }

    // MARK: - 提问

    private var askView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let intro = ask?.intro, !intro.isEmpty {
                    Text(intro).font(.title3.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                }

                if let c = ctx, !c.conflicts.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("发现 \(c.conflicts.count) 处冲突", systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline.weight(.bold)).foregroundStyle(.orange)
                        ForEach(c.conflicts.prefix(5)) { x in
                            Text("· " + x.text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        if c.conflicts.count > 5 { Text("…还有 \(c.conflicts.count - 5) 处").font(.caption).foregroundStyle(.tertiary) }
                    }
                    .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    .glassCard(radius: 14, tint: Color.orange.opacity(0.08))
                }

                VStack(alignment: .leading, spacing: 8) {
                    stageTag("收集", .blue)
                    Text("脑子里还有什么想做、还没记下来的事？").font(.callout.weight(.bold))
                    Text("先倒出来，不用整理。比如「准备周五的汇报、把论文第二节写完」，AI 会拆成具体的下一步行动并排上日期")
                        .font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $goals)
                        .font(.callout).scrollContentBackground(.hidden)
                        .padding(8).frame(height: 84)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }

                ForEach(ask?.questions ?? []) { q in
                    VStack(alignment: .leading, spacing: 8) {
                        if !q.stage.isEmpty { stageTag(q.stage, stageColor(q.stage)) }
                        Text(q.text).font(.callout.weight(.bold)).fixedSize(horizontal: false, vertical: true)
                        if !q.options.isEmpty {
                            FlowRow(spacing: 6) {
                                ForEach(q.options, id: \.self) { o in optionChip(q, o) }
                            }
                        }
                        TextField("补充一下（可不填）", text: Binding(get: { custom[q.id] ?? "" }, set: { custom[q.id] = $0 }))
                            .textFieldStyle(.roundedBorder)
                    }
                }
            }
            .padding(20)
        }
        .scrollIndicators(.hidden)
    }

    private func stageTag(_ text: String, _ tint: Color) -> some View {
        Text(text).font(.caption2.weight(.bold)).foregroundStyle(tint)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(tint.opacity(0.12), in: Capsule())
    }

    private func stageColor(_ stage: String) -> Color {
        switch stage {
        case "目标": return .purple
        case "澄清": return .teal
        case "优先级": return .red
        case "容量": return .green
        case "取舍": return .orange
        default: return .secondary
        }
    }

    private func optionChip(_ q: AIQuestion, _ o: String) -> some View {
        let on = picks[q.id]?.contains(o) == true
        return Button {
            var s = picks[q.id] ?? []
            if on { s.remove(o) } else {
                if !q.multi { s = [] }
                s.insert(o)
            }
            picks[q.id] = s
        } label: {
            Text(o).font(.callout)
                .padding(.horizontal, 11).padding(.vertical, 5)
                .foregroundStyle(on ? Color.white : Color.primary)
                .background(on ? Brand.orange : Color.primary.opacity(0.07), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 计划

    private var resultView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let p = plan {
                    if !p.summary.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("总结", systemImage: "text.alignleft").font(.subheadline.weight(.bold)).foregroundStyle(.purple)
                            Text(p.summary).font(.callout).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                        .glassCard(radius: 14, tint: Color.purple.opacity(0.08))
                    }

                    if !p.topThree.isEmpty {
                        block("今天最重要的 \(p.topThree.count) 件", icon: "star.fill", tint: .yellow) {
                            ForEach(Array(p.topThree.enumerated()), id: \.offset) { i, t in
                                let parts = t.components(separatedBy: "｜")
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text("\(i + 1)").font(.caption.weight(.bold)).foregroundStyle(.white)
                                        .frame(width: 18, height: 18).background(Brand.orange, in: Circle())
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(parts[0]).font(.callout.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                                        if parts.count > 1 { Text(parts[1]).font(.caption).foregroundStyle(.secondary) }
                                    }
                                }
                            }
                        }
                    }

                    if !p.conflicts.isEmpty {
                        block("冲突怎么处理", icon: "exclamationmark.triangle.fill", tint: .orange) {
                            ForEach(p.conflicts) { c in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(c.text).font(.callout.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                                    if !c.resolution.isEmpty {
                                        Text("→ " + c.resolution).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }
                        }
                    }

                    if !p.newTasks.isEmpty {
                        block("拆解出的新任务 \(checkedNew.count)/\(p.newTasks.count)", icon: "plus.circle.fill", tint: .green) {
                            ForEach(p.newTasks) { n in newRow(n) }
                        }
                    }

                    if !p.moves.isEmpty {
                        block("改期 \(checkedMoves.count)/\(p.moves.count)", icon: "calendar.badge.clock", tint: Brand.orange) {
                            ForEach(p.moves) { m in moveRow(m) }
                        }
                    }

                    if p.moves.isEmpty && p.newTasks.isEmpty {
                        Text("AI 觉得现在的安排不需要调整。").font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(20)
        }
        .scrollIndicators(.hidden)
    }

    private func block<C: View>(_ title: String, icon: String, tint: Color, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon).font(.subheadline.weight(.bold)).foregroundStyle(tint)
            content()
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(radius: 14)
    }

    private func check(_ on: Bool, _ toggle: @escaping () -> Void) -> some View {
        Button(action: toggle) {
            Image(systemName: on ? "checkmark.square.fill" : "square")
                .font(.system(size: 15)).foregroundStyle(on ? Brand.orange : Color.secondary)
        }
        .buttonStyle(.plain)
    }

    private func when(_ date: String?, _ time: String?) -> String {
        guard let date else { return "无日期" }
        return Day.label(date) + (time.map { " " + $0 } ?? "")
    }

    private func newRow(_ n: AINewTask) -> some View {
        HStack(alignment: .top, spacing: 10) {
            check(checkedNew.contains(n.id)) {
                if checkedNew.contains(n.id) { checkedNew.remove(n.id) } else { checkedNew.insert(n.id) }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(n.title).font(.callout.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    TagChip(text: when(n.date, n.time), tint: .green)
                    TagChip(text: "\(n.minutes) 分钟", tint: .secondary)
                    if n.priority > 0 { TagChip(text: ["", "低", "", "中", "", "高"][n.priority] + "优先级", tint: n.priority >= 5 ? .red : .orange) }
                    if let p = n.project { TagChip(text: "#" + p, tint: .blue) }
                }
                if let parent = n.parent { Text("来自：" + parent).font(.caption).foregroundStyle(.tertiary).lineLimit(1) }
                if !n.reason.isEmpty { Text(n.reason).font(.caption).foregroundStyle(.purple).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 0)
        }
    }

    private func moveRow(_ m: AIMove) -> some View {
        HStack(alignment: .top, spacing: 10) {
            check(checkedMoves.contains(m.id)) {
                if checkedMoves.contains(m.id) { checkedMoves.remove(m.id) } else { checkedMoves.insert(m.id) }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(m.task.cleanTitle).font(.callout.weight(.semibold)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Text(when(m.task.date, m.task.time)).font(.caption).foregroundStyle(.secondary)
                    Image(systemName: "arrow.right").font(.system(size: 9, weight: .bold)).foregroundStyle(.tertiary)
                    Text(when(m.date, m.time)).font(.caption.weight(.semibold)).foregroundStyle(Brand.orangeDeep)
                }
                if !m.reason.isEmpty { Text(m.reason).font(.caption).foregroundStyle(.purple).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 0)
        }
    }
}
