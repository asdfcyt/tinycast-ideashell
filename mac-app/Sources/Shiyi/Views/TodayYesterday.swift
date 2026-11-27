import AppKit
import SwiftUI

// MARK: - 昨天（回顾）

/// 昨天的复盘，一张可折叠的卡片，上下两块：
/// - 日常（非结审）：滴答完成的待办、笔记、Daily Note，交给 AI 写一小段洞察，按天存在本机文件里，有缓存就不再调用；
/// - 结审：只用结审里的事实（日报、台账、任务）拼成「完成情况 / 线索进展 / 要留意」，**不经过 AI**。
/// 不搬运日报里的逐条工作日志；要看全文点「打开日报」。结审日报没有时点一下再生成（不会自动往项目里写）。
struct YesterdayCard: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var focus: FocusStore
    /// yyyy-MM-dd
    let day: String
    let done: [DidaTask]
    let missed: [DidaTask]

    /// 从结审日报里拆出来的几块
    struct DailyReport {
        struct Clue { let id: String; let title: String; var note: String }
        let summary: SjzSummary
        var tasks: [String] = []
        var docs: [String] = []
        /// 新增材料：(类别, 编号, 标题)
        var materials: [(kind: String, id: String, title: String)] = []
        /// 本期有进展的线索（新增、状态变化、补充记录）
        var clues: [Clue] = []
        /// 线索总数 / 待核实 / 已核实 / 已排除 / 已出取证单 / 本期新增 / 有新进展
        var clueStat: [Int] = []
        /// 其他风险与关注 / 下一步安排
        var risks: [String] = []
        var next: [String] = []
    }

    struct Seg: Identifiable {
        var id: String { title }
        let title: String
        let icon: String
        let tint: Color
        let text: String
        /// 0...1：画一条进度条
        var progress: Double? = nil
    }

    /// AI 对「日常」的洞察，按天存在本机文件里
    struct Insight: Codable {
        struct Theme: Codable, Identifiable {
            var id: String { name }
            let name: String
            let detail: String
        }
        var summary: String
        var themes: [Theme]
        var mood: String
        /// 对 AI 调度 / 项目进度的分析（旧缓存里没有）
        var dispatch: String?
        var progress: String?
        var suggestions: [String]
        var questions: [String]
        var madeAt: Date
    }

    @AppStorage("today.yesterday.open") private var open = true

    /// 上次读到的结审日报 / 记录 / 笔记，按天放内存里
    private struct Snapshot {
        var report: DailyReport?
        var caps: [SjzCapture]
        var notes: [(title: String, text: String)]
        var dailyLines: [String]
    }
    private static var cache: [String: Snapshot] = [:]

    init(focus: FocusStore, day: String, done: [DidaTask], missed: [DidaTask]) {
        self.focus = focus
        self.day = day
        self.done = done
        self.missed = missed
        _insight = State(initialValue: Self.loadInsight(day))
        // 切页面回来时，上次读到的数据先用着，不要等网络再冒出来
        if let c = Self.cache[day] {
            _report = State(initialValue: c.report)
            _caps = State(initialValue: c.caps)
            _notes = State(initialValue: c.notes)
            _dailyLines = State(initialValue: c.dailyLines)
            _reportLoaded = State(initialValue: true)
        }
    }

    @ObservedObject private var ledger = DispatchLedger.shared
    @State private var report: DailyReport?
    @State private var caps: [SjzCapture] = []
    @State private var reportLoaded = false
    @State private var generating = false
    /// 点了生成但昨天没有工作记录：不再显示生成按钮
    @State private var noRecords = false
    @State private var showAllMissed = false
    /// 昨天的笔记 / Daily Note（给 AI 的素材）
    @State private var notes: [(title: String, text: String)] = []
    @State private var dailyLines: [String] = []
    @State private var insight: Insight?
    @State private var aiBusy = false
    @State private var aiError = ""

    private var project: String {
        model.sjzPin.project.isEmpty ? (model.sjzOverview?.projects.first?.name ?? "") : model.sjzPin.project
    }

    // MARK: 日常（非结审）的素材

    private var plainDone: [DidaTask] { done.filter { !SjzTasks.owns($0.id) } }
    private var plainMissed: [DidaTask] { missed.filter { !SjzTasks.owns($0.id) } }
    private var sjzMissed: Int { missed.filter { SjzTasks.owns($0.id) }.count }
    /// 要不要显示 AI 洞察卡：日常、AI 调度、项目进度任何一项有内容
    private var showInsight: Bool { hasPlain || !dispatchSegs.isEmpty || !projectFacts.isEmpty }
    private var hasPlain: Bool { !plainDone.isEmpty || !notes.isEmpty || !dailyLines.isEmpty || !plainMissed.isEmpty }

    // MARK: 结审：事实拼成的几句话，不经过 AI

    private func capCount(_ k: String) -> Int { caps.filter { $0.kind == k }.count }

    private static func clip(_ t: String, _ n: Int = 16) -> String { t.count > n ? String(t.prefix(n)) + "…" : t }
    private static func cn(_ n: Int) -> String {
        let d = ["零", "一", "两", "三", "四", "五", "六", "七", "八", "九", "十"]
        return n >= 0 && n <= 10 ? d[n] : "\(n)"
    }
    private static func quote(_ t: String, _ n: Int = 16) -> String { "「" + clip(t, n) + "」" }
    /// 「A」「B」等
    private static func list(_ items: [String], total: Int? = nil, max: Int = 2) -> String {
        let shown = items.prefix(max).joined(separator: "、")
        return shown + ((total ?? items.count) > max ? "等" : "")
    }

    /// 读起来像人说的话：做了什么 → 线索现状 → 要留意的事
    private var sjzSegments: [Seg] {
        guard model.hasSjz, !project.isEmpty, reportLoaded else { return [] }
        let r = report
        var doneS: [String] = []
        var clueS: String?
        var watchS: String?

        // 1. 做了什么
        var did: [String] = []
        if let tasks = r?.tasks, !tasks.isEmpty {
            did.append("办结了\(Self.cn(tasks.count))项任务（\(Self.list(tasks.map { Self.quote($0, 14) }, total: tasks.count))）")
        }
        if let ms = r?.materials, !ms.isEmpty {
            let kinds = Dictionary(grouping: ms, by: \.kind)
            for k in ["证据", "法规", "数据", "资料清单"] {
                guard let l = kinds[k] else { continue }
                did.append("新增\(Self.cn(l.count))份\(k)（\(Self.list(l.map { Self.quote($0.title, 14) }, total: l.count))）")
            }
        } else {
            for (k, l) in [("evidence", "证据"), ("regulation", "法规"), ("data", "数据"), ("datalist", "资料清单")] where capCount(k) > 0 {
                did.append("新增\(Self.cn(capCount(k)))份\(l)")
            }
        }
        if let docs = r?.docs, !docs.isEmpty { did.append("更新了\(Self.cn(docs.count))份文书（\(Self.list(docs.map { Self.quote($0, 14) }, total: docs.count))）") }
        let ideas = caps.filter { $0.kind == "idea" }
        if !ideas.isEmpty {
            let names = ideas.map { Self.quote($0.title.isEmpty ? $0.summary : $0.title, 18) }
            did.append("记下了\(Self.cn(ideas.count))个想法（\(Self.list(names, max: 1))）")
        }
        if did.isEmpty {
            doneS.append("昨天结审里没有新的动作")
        } else {
            doneS.append("昨天" + did.joined(separator: "，"))
        }
        if sjzMissed > 0 { doneS.append("另有\(Self.cn(sjzMissed))项结审任务昨天到期，还没完成") }

        // 2. 线索现状
        if let r, r.clueStat.count == 7, r.clueStat[0] > 0 {
            let s = r.clueStat
            var t = "线索库里现有\(Self.cn(s[0]))条线索"
            if s[1] == s[0] { t += "，都还在待核实" }
            else {
                var st: [String] = []
                if s[1] > 0 { st.append("\(Self.cn(s[1]))条待核实") }
                if s[2] > 0 { st.append("\(Self.cn(s[2]))条已核实") }
                if s[3] > 0 { st.append("\(Self.cn(s[3]))条已排除") }
                if s[4] > 0 { st.append("\(Self.cn(s[4]))条已出取证单") }
                if !st.isEmpty { t += "，其中" + st.joined(separator: "、") }
            }
            if s[5] > 0 || s[6] > 0 {
                var ch: [String] = []
                if s[5] > 0 { ch.append("新增\(Self.cn(s[5]))条") }
                if s[6] > 0 { ch.append("\(Self.cn(s[6]))条有新进展") }
                t += "；昨天" + ch.joined(separator: "、")
                let hot = r.clues.map { c in c.title.isEmpty ? c.id : Self.quote(c.title, 16) }
                if !hot.isEmpty { t += "（" + Self.list(hot, max: 2) + "）" }
            } else {
                t += "，昨天没有变化"
            }
            clueS = t
        } else if capCount("clue") > 0 {
            clueS = "昨天新增\(Self.cn(capCount("clue")))条线索"
        }

        // 3. 要留意的事
        var watch: [String] = (r?.risks ?? []).map { Self.trimEnd($0).replacingOccurrences(of: "「", with: "").replacingOccurrences(of: "」", with: "") }
        let hasDocRisk = watch.contains { $0.contains("必备文书") }
        if let n = r?.next.first(where: { !$0.hasPrefix("核实") && !(hasDocRisk && $0.contains("必备文书")) }) {
            watch.append("下一步" + Self.trimEnd(n))
        }
        if !watch.isEmpty { watchS = watch.prefix(2).joined(separator: "；") }

        var out: [Seg] = []
        if !doneS.isEmpty { out.append(.init(title: "完成情况", icon: "checkmark.circle.fill", tint: .green, text: doneS.joined(separator: "。") + "。")) }
        if let clueS { out.append(.init(title: "线索进展", icon: "magnifyingglass.circle.fill", tint: .blue, text: clueS + "。")) }
        if let watchS { out.append(.init(title: "要留意", icon: "exclamationmark.circle.fill", tint: .orange, text: watchS + "。")) }
        return out
    }

    /// 没有 AI（或还没生成）时，日常部分自己拼的一句话
    private var plainFallback: String? {
        var parts: [String] = []
        if !plainDone.isEmpty { parts.append("完成了\(Self.cn(plainDone.count))项待办（\(Self.list(plainDone.map { Self.quote($0.cleanTitle, 14) }, total: plainDone.count, max: 3))）") }
        if !notes.isEmpty { parts.append("记了\(Self.cn(notes.count))篇笔记（\(Self.list(notes.map { Self.quote($0.title, 14) }, max: 2))）") }
        if !dailyLines.isEmpty { parts.append("Daily Note 里随手记了\(Self.cn(dailyLines.count))条") }
        var t = parts.isEmpty ? "" : "昨天" + parts.joined(separator: "，") + "。"
        if !plainMissed.isEmpty { t += "还有\(Self.cn(plainMissed.count))件没做完。" }
        return t.isEmpty ? nil : t
    }

    private static func trimEnd(_ s: String) -> String { s.trimmingCharacters(in: CharacterSet(charactersIn: "。；：: ")) }

    private var canGenerate: Bool { model.hasSjz && !project.isEmpty && reportLoaded && report == nil && !noRecords }

    // MARK: 界面

    /// 第一张卡（折叠箭头放在它的标题行里）
    private var firstKey: String { "plain" }

    /// 每个部分一张自己的卡，用淡淡的底色区分
    private func card<C: View>(_ tint: Color, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard(radius: 16, tint: tint.opacity(0.10))
    }

    /// 卡片标题行：图标 + 名称 + 说明（第一张卡左边是折叠箭头）
    private func cardHeader<T: View>(_ key: String, icon: String, tint: Color, title: String, note: String, @ViewBuilder trailing: () -> T) -> some View {
        HStack(spacing: 8) {
            if firstKey == key { chevron }
            Image(systemName: icon).foregroundStyle(tint)
            Text(firstKey == key ? "昨天 · " + title : title).font(.subheadline.weight(.semibold))
            if !note.isEmpty { Text(note).font(.caption).foregroundStyle(.tertiary) }
            Spacer(minLength: 8)
            trailing()
        }
    }

    var body: some View {
        let segs = sjzSegments
        if showInsight || !segs.isEmpty || canGenerate {
            VStack(alignment: .leading, spacing: 10) {
                if open {
                    card(Brand.orange) { insightPart(segs) }
                    if !plainMissed.isEmpty { card(.red) { missedBlock } }
                } else {
                    card(Brand.orange) { collapsedRow(segs) }
                }
            }
            .task(id: project + day) { await load(); await autoAI() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in Task { await load() } }
            .onReceive(NotificationCenter.default.publisher(for: .sjzCapturesChanged)) { _ in Task { await load() } }
        } else {
            Color.clear.frame(height: 0).task(id: project + day) { await load(); await autoAI() }
        }
    }

    private var chevron: some View {
        Button { withAnimation(.easeOut(duration: 0.15)) { open.toggle() } } label: {
            Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold)).foregroundStyle(.tertiary)
                .rotationEffect(.degrees(open ? 90 : 0)).frame(width: 16, height: 16).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(open ? "折叠「昨天」" : "展开「昨天」")
    }

    /// 折叠时只剩一行：昨天 + 一句话
    private func collapsedRow(_ segs: [Seg]) -> some View {
        let line = insight?.summary ?? plainFallback ?? segs.first?.text ?? "昨天"
        return HStack(spacing: 8) {
            chevron
            Text("昨天").font(.subheadline.weight(.semibold))
            Text(line).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { open = true } }
    }

    private var hasAIContent: Bool { !plainDone.isEmpty || !notes.isEmpty || !dailyLines.isEmpty || !dispatchSegs.isEmpty || !projectFacts.isEmpty }

    private func block<C: View>(_ title: String, icon: String, tint: Color, tag: String? = nil, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Label(title, systemImage: icon).font(.caption.weight(.bold)).foregroundStyle(tint)
                Spacer(minLength: 8)
                if let tag {
                    Text(tag).font(.caption2.weight(.semibold)).foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                        .help("来自结审的日报与台账，不经过 AI")
                }
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: 日常（AI 洞察）

    private func insightPart(_ segs: [Seg]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            cardHeader("plain", icon: "sparkles", tint: Brand.orange, title: "AI 洞察", note: "") {
                if aiBusy { ProgressView().controlSize(.small) }
                if let r = report {
                    Button { model.openSjzPreview(project: project, capture: r.summary.asCapture) } label: {
                        Label("打开日报", systemImage: "doc.text")
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                        .help("在拾忆里打开结审的昨日日报全文")
                }
                if hasAIContent {
                    Button { Task { await generateAI() } } label: {
                        Label(insight == nil ? "生成洞察" : "重新生成", systemImage: insight == nil ? "wand.and.stars" : "arrow.clockwise")
                    }
                    .buttonStyle(.bordered).controlSize(.small).disabled(aiBusy || !model.hasLlm)
                }
            }
            if !model.hasLlm, hasAIContent {
                HStack(spacing: 8) {
                    Text("需要先配置 AI 模型").font(.callout).foregroundStyle(.secondary)
                    Button("去设置") { SettingsWindow.show(.account) }.buttonStyle(.link)
                }
            }
            if !aiError.isEmpty { Text(aiError).font(.caption).foregroundStyle(.orange) }

            if let ins = insight {
                Text(ins.summary).font(.callout).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                if let d = ins.dispatch, !d.isEmpty {
                    block("AI 调度", icon: "bolt.horizontal.fill", tint: .purple) {
                        Text(d).font(.callout).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let g = ins.progress, !g.isEmpty {
                    block("项目进度", icon: "chart.bar.fill", tint: .pink) {
                        Text(g).font(.callout).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else if aiBusy {
                Text("正在读昨天的待办、笔记、AI 调度和项目进度，十几秒…").font(.callout).foregroundStyle(.secondary)
            } else if let t = plainFallback {
                Text(t).font(.callout).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
            }

            // 结审：日报与台账里的事实，不经过 AI
            ForEach(segs) { g in
                block(g.title, icon: g.icon, tint: g.tint, tag: "结审") {
                    Text(g.text).font(.callout).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                }
            }
            if canGenerate {
                Button { Task { await generate() } } label: {
                    HStack(spacing: 6) {
                        if generating { ProgressView().controlSize(.small) } else { Image(systemName: "doc.badge.plus") }
                        Text("结审里还没有昨天的日报，点这里生成（补上线索进展和风险）")
                    }
                    .font(.callout)
                }
                .buttonStyle(.link).disabled(generating)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: AI 调度（昨天派了哪些活）

    private static func tokens(_ n: Int) -> String { n >= 10000 ? String(format: "%.1f 万", Double(n) / 10000) : "\(n)" }

    private var dispatchSegs: [Seg] {
        let all = ledger.jobs
        guard !all.isEmpty else { return [] }
        let from = Self.startOfDay(day)
        let to = Day.cal.date(byAdding: .day, value: 1, to: from) ?? from
        let ys = all.filter { $0.createdAt >= from && $0.createdAt < to }.sorted { $0.createdAt < $1.createdAt }
        let active = all.filter { $0.state.isActive }
        var out: [Seg] = []

        if ys.isEmpty {
            out.append(.init(title: "派活情况", icon: "bolt.fill", tint: .purple, text: "昨天没有派活。"))
        } else {
            let ok = ys.filter { $0.state == .done }.count
            let fail = ys.filter { $0.state == .failed }.count
            let stop = ys.filter { $0.state == .cancelled || $0.state == .interrupted }.count
            let live = ys.filter { $0.state.isActive }.count
            var res: [String] = []
            if ok > 0 { res.append("\(Self.cn(ok))次完成") }
            if fail > 0 { res.append("\(Self.cn(fail))次没跑成") }
            if stop > 0 { res.append("\(Self.cn(stop))次中途停了") }
            if live > 0 { res.append("\(Self.cn(live))次还没跑完") }
            var t = "昨天一共派出\(Self.cn(ys.count))次活"
            if !res.isEmpty { t += "：" + res.joined(separator: "，") }
            let byTarget = Dictionary(grouping: ys, by: \.targetTitle).sorted { $0.value.count > $1.value.count }.prefix(3)
            if byTarget.count > 0 { t += "。主要交给 " + byTarget.map { "\($0.key) \(Self.cn($0.value.count))次" }.joined(separator: "、") }
            out.append(.init(title: "派活情况", icon: "bolt.fill", tint: .purple, text: t + "。"))

            let what = ys.map { j -> String in
                let line = j.prompt.split(separator: "\n").first.map(String.init) ?? j.prompt
                return Self.quote(line.trimmed, 22)
            }
            out.append(.init(title: "派了什么", icon: "text.alignleft", tint: .indigo, text: Self.list(what, max: 3) + (what.count > 3 ? "（共 \(Self.cn(what.count)) 项）" : "")))

            let tok = ys.compactMap(\.usage).reduce(0) { $0 + $1.tokens }
            let cost = ys.compactMap { $0.usage?.cost }.reduce(0, +)
            if tok > 0 {
                var u = "共用约 \(Self.tokens(tok)) token"
                if cost > 0 { u += String(format: "（约 $%.2f）", cost) }
                out.append(.init(title: "用量", icon: "gauge.with.dots.needle.33percent", tint: .teal, text: u + "。"))
            }
        }
        var watch: [String] = []
        let failedOpen = all.filter { $0.state == .failed && $0.dismissed != true }
        if !failedOpen.isEmpty { watch.append("还有\(Self.cn(failedOpen.count))个任务没跑成，可以到「调度」页重跑") }
        if !active.isEmpty { watch.append("现在有\(Self.cn(active.count))个任务在跑或排队") }
        if !watch.isEmpty { out.append(.init(title: "要留意", icon: "exclamationmark.circle.fill", tint: .orange, text: watch.joined(separator: "；") + "。")) }
        return out
    }

    // MARK: 项目进度（普通项目：拾忆「项目」里的关键词项目，不含结审审计项目）

    /// 每个项目一行事实，只给 AI 看
    private var projectFacts: [String] {
        let today = Day.today()
        let ov = model.overview
        let open = ((ov?.overdue ?? []) + (ov?.upcoming ?? []) + (ov?.undated ?? [])).filter { !SjzTasks.owns($0.id) }
        let recentDone = (ov?.done ?? []).filter { !SjzTasks.owns($0.id) }
        let log = model.backup?.workspace.focusLog ?? []
        var out: [String] = []
        for p in model.projects where p.projectStatus != .PAUSED {
            let mine = open.filter { p.matches($0.title, tags: $0.tags) }
            let overdue = mine.filter { ($0.date ?? "9999") < today }.count
            let dueToday = mine.filter { $0.date == today }.count
            let doneY = plainDone.filter { p.matches($0.title, tags: $0.tags) }.count
            let done3 = recentDone.filter { p.matches($0.title, tags: $0.tags) }.count
            let notesAll = model.timeline.filter { p.matches($0.text ?? ($0.title + " " + ($0.summary ?? "")), tags: $0.tags) }
            let notesY = notesAll.filter { $0.day == day }.count
            let ago = notesAll.compactMap(\.day).max().map { Day.diff($0, today) }
            let focusY = log.filter { $0.project == p.keyword && Day.string($0.startDate) == day }.reduce(0) { $0 + $1.minutes }
            let next = p.next?.trimmed ?? ""
            guard !mine.isEmpty || done3 > 0 || !notesAll.isEmpty || focusY > 0 || !next.isEmpty else { continue }
            var parts: [String] = ["未完成 \(mine.count) 项"]
            if overdue > 0 { parts.append("其中逾期 \(overdue) 项") }
            if dueToday > 0 { parts.append("今天到期 \(dueToday) 项") }
            var y: [String] = []
            if doneY > 0 { y.append("完成 \(doneY) 项待办") }
            if notesY > 0 { y.append("记了 \(notesY) 篇相关笔记") }
            if focusY > 0 { y.append("专注 \(focusY) 分钟") }
            parts.append("昨天" + (y.isEmpty ? "没有动静" : y.joined(separator: "、")))
            if done3 > 0 { parts.append("近三天共完成 \(done3) 项") }
            if let ago { parts.append(ago <= 0 ? "今天刚提到过" : "上次提到是 \(ago) 天前（超过 \(p.stale) 天算久没动）") }
            if !next.isEmpty { parts.append("记下的下一步：" + String(next.prefix(40))) }
            out.append("\(p.keyword)（\(p.projectStatus.label)）：" + parts.joined(separator: "；"))
            if out.count >= 8 { break }
        }
        return out
    }

    @ViewBuilder private var missedBlock: some View {
        let shown = showAllMissed ? plainMissed : Array(plainMissed.prefix(3))
        HStack(spacing: 6) {
            Text("昨天没做完").font(.caption.weight(.semibold)).foregroundStyle(.red)
            Text("\(plainMissed.count)").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            Spacer()
            Button("全部改到今天") { Task { await model.moveToToday(plainMissed) } }
                .buttonStyle(.link).font(.caption).disabled(model.scheduling)
        }
        .padding(.horizontal, 14).padding(.top, 2).padding(.bottom, 2)
        ForEach(Array(shown.enumerated()), id: \.element.id) { i, t in
            TaskLine(task: t, overdue: true, focus: focus)
            if i < shown.count - 1 { Divider().padding(.leading, 46) }
        }
        if plainMissed.count > 3 {
            Divider().padding(.leading, 46)
            Button(showAllMissed ? "收起" : "展开其余 \(plainMissed.count - 3) 件") { withAnimation(.easeOut(duration: 0.15)) { showAllMissed.toggle() } }
                .buttonStyle(.link).font(.callout).padding(.horizontal, 14).padding(.vertical, 9)
        } else {
            Color.clear.frame(height: 4)
        }
    }

    // MARK: AI（只处理非结审的内容）

    private static let aiSystem = """
    你是用户的私人「每日洞察」助手，类似 flomo 的 AI 洞察。你会拿到用户「昨天」的这些材料：
    - 日常：完成的待办、没做完的待办、写下的笔记、Daily Note 里的随手记（不含审计工作项目）；
    - dispatch：昨天他让 AI Agent（Claude Code 等）干了哪些活、结果如何、用量多少、现在还有什么在跑；
    - projectProgress：他自己维护的几个普通项目（不是审计项目）的进度：未完成/逾期任务、昨天的动静、多久没提到、他记下的下一步。
    请像一位细心、不评判的朋友，帮他看清昨天，并轻轻推他一把迎接今天。

    请输出：
    1. summary：一个自然段（110~160 字，不分点），只谈日常：昨天主要忙了哪几件事（引用他真正写过的待办、笔记关键词），从文字里看到的节奏、状态或变化，没收尾的想法或没做完的事一句话带过。没有日常内容就写一句话说明。
    2. dispatch：分析 AI 调度（不超过 80 字）：派活的节奏与结果、有没有失败或空转的、用量是否合理、哪些活值得今天接着跟进。没有 dispatch 材料就留空字符串。
    3. progress：分析项目进度（不超过 90 字）：哪些项目在推进、哪些久没动或积压了逾期、该先照顾哪个，给出轻重缓急的判断。没有 projectProgress 材料就留空字符串。

    原则：语气温和、不责备、不制造焦虑；不用「拖延」之类的词；只依据给出的材料，没写过的事不要编造；信息很少就少说；不要照抄数字，要说背后的意思；不要复述结审日报里的具体工作记录（那部分另有人写）。

    只输出一个 JSON 对象，不要其他文字：
    {"summary":"","dispatch":"","progress":""}
    """

    private static let insightFile = "yesterday-insight.json"

    private static func loadAll() -> [String: Insight] {
        guard let t = LocalStore.read(insightFile), let d = t.data(using: .utf8) else { return [:] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode([String: Insight].self, from: d)) ?? [:]
    }

    private static func loadInsight(_ day: String) -> Insight? { loadAll()[day] }

    private static func saveInsight(_ i: Insight, day: String) {
        var all = loadAll()
        all[day] = i
        for k in all.keys.sorted().dropLast(7) { all[k] = nil }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        if let d = try? enc.encode(all), let t = String(data: d, encoding: .utf8) { LocalStore.write(insightFile, t) }
    }

    /// 打开卡片时：有缓存直接用；没有且配了 AI、昨天有日常内容时自动写一次（每天最多自动一次）
    private func autoAI() async {
        if insight == nil { insight = Self.loadInsight(day) }
        // 旧缓存没有调度 / 进度分析，而现在有这两类材料：重写一次
        let stale = insight != nil && insight?.dispatch == nil && insight?.progress == nil && (!dispatchSegs.isEmpty || !projectFacts.isEmpty)
        guard insight == nil || stale, model.hasLlm, !aiBusy, hasAIContent else { return }
        let tried = "today.yesterday.insight2.tried." + day
        guard !UserDefaults.standard.bool(forKey: tried) else { return }
        UserDefaults.standard.set(true, forKey: tried)
        await generateAI()
    }

    private func generateAI() async {
        guard model.hasLlm else { aiError = "还没配置 AI 模型，请先到「设置 → AI 模型」填写接口地址和 Key。"; return }
        guard !aiBusy else { return }
        aiBusy = true
        aiError = ""
        defer { aiBusy = false }
        let payload: [String: Any] = [
            "date": day,
            "doneTasks": plainDone.map(\.cleanTitle),
            "missedTasks": plainMissed.map(\.cleanTitle),
            "notes": notes.prefix(12).map { ["title": $0.title, "text": String($0.text.prefix(200))] },
            "dailyNotes": Array(dailyLines.prefix(24)),
            "dispatch": dispatchSegs.map { "\($0.title)：\($0.text)" },
            "projectProgress": projectFacts,
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            let reply = try await model.llm.chatJSON(system: Self.aiSystem, user: String(data: data, encoding: .utf8) ?? "{}", timeout: 90)
            guard let obj = LlmClient.extractJSON(reply), let sum = (obj["summary"] as? String)?.trimmed, !sum.isEmpty else {
                aiError = "AI 返回的内容格式不对，请重试"
                return
            }
            func strings(_ k: String) -> [String] { (obj[k] as? [Any])?.compactMap { ($0 as? String)?.trimmed }.filter { !$0.isEmpty } ?? [] }
            let themes: [Insight.Theme] = ((obj["themes"] as? [[String: Any]]) ?? []).prefix(3).compactMap { t in
                guard let n = (t["name"] as? String)?.trimmed, !n.isEmpty else { return nil }
                return .init(name: n, detail: (t["detail"] as? String)?.trimmed ?? "")
            }
            let ins = Insight(summary: sum, themes: themes, mood: "",
                              dispatch: (obj["dispatch"] as? String)?.trimmed.nonEmpty, progress: (obj["progress"] as? String)?.trimmed.nonEmpty,
                              suggestions: Array(strings("suggestions").prefix(2)), questions: [], madeAt: Date())
            insight = ins
            Self.saveInsight(ins, day: day)
        } catch { aiError = error.localizedDescription }
    }

    // MARK: 读取

    private static func startOfDay(_ s: String) -> Date { Day.startOfDay(Day.parse(s) ?? Date()) }

    private func load() async {
        defer { Self.cache[day] = Snapshot(report: report, caps: caps, notes: notes, dailyLines: dailyLines) }
        // 日常：昨天的笔记 + Daily Note
        notes = model.timeline.filter { $0.day == day && !$0.tags.contains("daily-note") }.map {
            ($0.title, ($0.summary ?? $0.text ?? "").trimmed.replacingOccurrences(of: "\n", with: " "))
        }
        if model.hasIdeashell, let days = try? await model.daily.days(from: day, to: day) {
            dailyLines = (days[day]?.entries ?? []).filter { !$0.struck }.map { "\($0.time) \($0.text)".replacingOccurrences(of: "\n", with: " ") }
        }
        // 结审：昨天写进结审的记录（只看顶层）+ 昨天那一份日报
        guard model.hasSjz else { reportLoaded = true; return }
        if model.sjzPin.project.isEmpty { await model.refreshSjzTarget() }
        if model.sjzOverview == nil { await model.refreshSjzOverview() }
        let p = project
        guard !p.isEmpty else { reportLoaded = true; return }
        let from = Self.startOfDay(day)
        let to = Day.cal.date(byAdding: .day, value: 1, to: from) ?? from
        if let all = try? await model.sjz.captures(project: p, since: from, limit: 200) {
            let list = all.filter { c in c.parentId.isEmpty && (c.date.map { $0 >= from && $0 < to } ?? false) }
            if list != caps { caps = list }
        }
        do {
            let list = try await model.sjz.summaries(project: p, limit: 30)
            if let s = list.first(where: { $0.kind == "daily" && $0.period.hasPrefix(day) }) {
                let d = try await model.sjz.captureDetail(project: p, id: SjzSummary.idPrefix + s.path)
                report = Self.parse(d.content, summary: s)
            } else if report != nil { report = nil }
        } catch {}
        reportLoaded = true
    }

    /// 生成昨天的日报（按事实汇总，不调用 AI）；昨天没有工作记录就提示一下
    private func generate() async {
        let p = project
        guard !p.isEmpty, !generating else { return }
        generating = true
        defer { generating = false }
        do {
            let r = try await model.sjz.generateSummary(project: p, kind: "daily", date: day)
            if r.summary == nil {
                noRecords = true
                model.showNotice(r.message.isEmpty ? "昨天没有工作记录，没有生成日报" : r.message)
                return
            }
            await load()
        } catch { model.showNotice(error.localizedDescription) }
    }

    private static let idPrefixRE = RX(#"^[A-Za-z]+-\d+(\.\d+)?\s+"#, multiline: false)
    private static let dateSuffixRE = RX(#"\s*[（(]\d{4}-\d{2}-\d{2}[）)]\s*$"#, multiline: false)
    private static let datedRE = RX(#"^\d{4}-\d{2}-\d{2}\b"#, multiline: false)
    private static let clueStatRE = RX(#"线索共\s*(\d+)\s*条：待核实\s*(\d+)、已核实\s*(\d+)、已排除\s*(\d+)、已出取证单\s*(\d+)。本期新增\s*(\d+)\s*条，有新进展\s*(\d+)\s*条"#, multiline: false)

    /// 日报是 Markdown：只取「已完成任务 / 有更新的文书」「线索进展」「风险与关注」「下一步安排」，工作日志流水不要
    static func parse(_ md: String, summary: SjzSummary) -> DailyReport {
        var r = DailyReport(summary: summary)
        var section = ""
        var sub = ""
        for raw in md.components(separatedBy: "\n") {
            let l = raw.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("####") {
                guard section.hasPrefix("三、") else { continue }
                let t = String(l.drop(while: { $0 == "#" || $0 == " " }))
                let id = t.split(separator: " ").first.map(String.init) ?? ""
                r.clues.append(.init(id: id, title: String(t.dropFirst(id.count)).trimmed.mdPlain, note: ""))
                continue
            }
            if l.hasPrefix("#") {
                let level = l.prefix(while: { $0 == "#" }).count
                let t = String(l.drop(while: { $0 == "#" || $0 == " " }))
                if level <= 2 { section = t; sub = "" } else { sub = t }
                continue
            }
            if section.hasPrefix("三、") {
                if let m = Self.clueStatRE.first(in: l) { r.clueStat = (1 ... 7).map { Int(m.group($0)) ?? 0 }; continue }
                if l.hasPrefix("状态："), !r.clues.isEmpty {
                    // 「状态：待核实 · 本期新增 · 补充 2 条」
                    r.clues[r.clues.count - 1].note = String(l.dropFirst(3)).mdPlain
                    continue
                }
            }
            guard raw.hasPrefix("- ") else { continue }
            var t = String(l.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            if t.isEmpty || t.hasPrefix("……") { continue }
            if section.hasPrefix("二、完成情况") {
                if sub == "已完成任务" {
                    t = Self.dateSuffixRE.replace(in: Self.idPrefixRE.replace(in: t, with: ""), with: "")
                    r.tasks.append(t.mdPlain)
                } else if sub == "有更新的文书" {
                    r.docs.append(t.mdPlain)
                } else if sub == "新增材料" {
                    // 「【证据】E-0023 标题」
                    if let a = t.firstIndex(of: "【"), let b = t.firstIndex(of: "】"), a < b {
                        let kind = String(t[t.index(after: a)..<b])
                        let rest = String(t[t.index(after: b)...]).trimmed
                        let id = rest.split(separator: " ").first.map(String.init) ?? ""
                        r.materials.append((kind, id, String(rest.dropFirst(id.count)).trimmed.mdPlain))
                    }
                }
            } else if section.hasPrefix("四、") {
                // 逾期任务在下面的「逾期」里，不重复
                if t.hasPrefix("逾期未完成任务") { continue }
                r.risks.append(t.mdPlain)
            } else if section.hasPrefix("五、") {
                // 带日期的是未来几天到期的任务，不重复
                if Self.datedRE.first(in: t) != nil { continue }
                r.next.append(t.mdPlain)
            }
        }
        return r
    }
}
