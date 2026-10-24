import Charts
import SwiftUI

/// 专注（复刻安卓端「环」）：一个环、一件事。
/// 上半是计时环（没开始时是选好的时长），下面选 15 / 25 / 45 / 60 / 90 分钟，再选「专注什么」（可以绑滴答里的一个待办，也可以不绑）；
/// 下半是滴答里读回来的专注：今天 / 近 7 天 / 最近几次。结束后写进滴答（create_focus），手机和电脑的滴答里都看得到。
/// 一轮 4 个番茄：专注 → 短休息，第 4 个之后是长休息。计时存在本机，退出应用也不丢，到点会发系统通知。
struct FocusView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var focus: FocusStore

    @State private var newTitle = ""
    @State private var adding = false
    @State private var confirmDiscard = false
    @State private var showRecord = false

    private var nowMs: Int64 { Int64(focus.now.timeIntervalSince1970 * 1000) }

    var body: some View {
        VStack(spacing: 16) {
            if !model.hasDida {
                banner("连接滴答清单后，专注会自动计入滴答；现在开始的专注先存在本机。", action: nil)
            }
            if !focus.pending.isEmpty {
                banner("有 \(focus.pending.count) 条专注还没同步到滴答", action: ("立即同步", { Task { await focus.syncNow() } }))
            }
            if let e = focus.error { ErrorBanner(text: e) { Task { await focus.refresh() } } }

            // 两栏（2:1）：左边计时环 + 控制，右边「专注什么 / 记录」；统计、近 7 天、最近几次各自整行放在下面。
            // 窗口窄到放不下两栏时折成单列
            ViewThatFits(in: .horizontal) {
                VStack(spacing: 16) {
                    RatioColumns(leading: 2.0 / 3.0, spacing: 16) {
                        timerCard
                        VStack(spacing: 12) { rightColumn }
                    }
                    todayCard
                    weekCard
                    recentCard
                }
                .frame(minWidth: 520)
                VStack(spacing: 16) { timerCard; rightColumn; todayCard; weekCard; recentCard }
            }
        }
        .alert("放弃这次专注？", isPresented: $confirmDiscard) {
            Button("放弃", role: .destructive) { focus.discard() }
            Button("继续专注", role: .cancel) {}
        } message: {
            Text("已经专注的时间不会被记录。")
        }
    }

    @ViewBuilder private var rightColumn: some View {
        if shownKind() == .focus { taskRow }
        recordCard
    }

    private func shownKind() -> FocusKind { focus.shownKind }

    // MARK: - 计时环（复刻安卓端 TimerCard）

    private var timerCard: some View {
        let run = focus.run
        let kind = focus.shownKind
        let fraction: Double = {
            if let run { return max(min(Double(run.remainingMs(nowMs)) / Double(max(run.plannedMs, 1)), 1), 0) }
            return min(Double(focus.minutes) / Double(kind.maxMin), 1)
        }()
        let breakGreen = Color(red: 0x4F / 255, green: 0xAE / 255, blue: 0x8B / 255)
        let arc: Color = run?.paused == true ? Brand.orange.opacity(0.5) : (kind.isBreak ? breakGreen : Brand.orange)

        return VStack(spacing: 16) {
            if let run {
                Text(run.kind.label).font(.system(size: 13, weight: .bold)).foregroundStyle(arc)
            } else {
                cycleHeader(kind, breakGreen)
            }

            FocusDial(fraction: fraction, arc: arc, idle: run == nil, maxMin: kind.maxMin, minMin: kind.minMin,
                      marks: (run.map { r in r.recordList.map { Double($0.sec) * 1000 / Double(max(r.plannedMs, 1)) } } ?? []),
                      onMinutes: { focus.minutes = $0 }) {
                if let run {
                    VStack(spacing: 2) {
                        Text(clock(run.remainingMs(nowMs)))
                            .font(.system(size: 40, weight: .black, design: .rounded)).monospacedDigit().minimumScaleFactor(0.7).lineLimit(1)
                        Text(run.paused ? "已暂停" : endClock(run) + " 结束")
                            .font(.system(size: 14, weight: .semibold)).foregroundStyle(.secondary)
                        if !run.kind.isBreak {
                            Text(run.title.isEmpty ? "自由专注" : run.title)
                                .font(.caption).foregroundStyle(.tertiary).lineLimit(1).frame(maxWidth: 120)
                        }
                    }
                } else {
                    VStack(spacing: 2) {
                        Text("\(focus.minutes)")
                            .font(.system(size: 46, weight: .black, design: .rounded)).monospacedDigit()
                        Text("分钟").font(.system(size: 14, weight: .semibold)).foregroundStyle(.secondary)
                        Button { focus.start() } label: {
                            HStack(spacing: 5) {
                                Text(kind.isBreak ? "开始" : "开始").font(.system(size: 15, weight: .heavy))
                                Image(systemName: "play.fill").font(.system(size: 12, weight: .bold))
                            }
                            .foregroundStyle(Brand.brown)
                            .padding(.horizontal, 22).frame(height: 38)
                            .background(Brand.orange, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 8)
                    }
                }
            }
            .frame(maxWidth: 232)

            if let run {
                Text("共 \(run.plannedMin) 分钟 · 已\(run.kind.isBreak ? "休息" : "专注") \(spoken(run.elapsedMs(nowMs)))")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
            } else {
                Text("拖动圆环或点一下，选择时长").font(.caption).foregroundStyle(.tertiary)
            }

            if let run {
                controls(run).padding(.top, 4)
                if showRecord, !run.kind.isBreak {
                    RecordComposer(focus: focus) { showRecord = false }
                        .environmentObject(model)
                        .padding(.top, 2)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 18)
        .frame(maxWidth: .infinity)
        .animation(.snappy(duration: 0.2), value: showRecord)
        .glassCard(radius: 28)
    }

    /// 一轮 4 个番茄的进度；休息时显示休息提示
    private func cycleHeader(_ kind: FocusKind, _ green: Color) -> some View {
        VStack(spacing: 6) {
            if kind.isBreak {
                Text(kind == .longBreak ? "完成 \(FocusStore.cycleLength) 个番茄 · 长休息" : "第 \(focus.cycle) 个番茄完成 · 短休息")
                    .font(.system(size: 14, weight: .heavy)).foregroundStyle(green)
            }
            HStack(spacing: 7) {
                ForEach(0 ..< FocusStore.cycleLength, id: \.self) { i in
                    Circle()
                        .fill(i < focus.cycle ? (kind.isBreak ? green : Brand.orange) : Color.primary.opacity(0.12))
                        .frame(width: 10, height: 10)
                }
                if !kind.isBreak {
                    Text(focus.cycle == 0 ? "  开始第 1 个番茄" : "  第 \(focus.cycle + 1) 个番茄")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                }
            }
            if kind.isBreak {
                Button("跳过休息，直接专注") { focus.skipBreak() }
                    .buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(.secondary)
            }
        }
    }

    private func endClock(_ run: FocusRun) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: Date(timeIntervalSince1970: Double(run.endAtMs) / 1000))
    }

    /// 「25 分 30 秒」
    private func spoken(_ ms: Int64) -> String {
        let s = Int(max(ms, 0) / 1000)
        if s < 60 { return "\(s) 秒" }
        let m = s / 60
        return m < 60 ? "\(m) 分钟" : "\(m / 60) 小时 \(m % 60) 分"
    }

    private func clock(_ ms: Int64) -> String {
        let s = Int((Double(max(ms, 0)) / 1000).rounded(.up))
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    // MARK: - 专注什么

    private var linked: (title: String, subtitle: String?)? {
        if let run = focus.run, !run.kind.isBreak {
            return run.taskId == nil ? nil : (run.title, model.overview?.projectName(run.projectId ?? ""))
        }
        if let t = focus.task { return (t.cleanTitle, model.overview?.projectName(t.projectId)) }
        return nil
    }

    /// 「专注什么」直接展开：搜索框 + 自由专注 + 推荐的待办（今天的、逾期的、接下来的），点一下就选上。
    /// 搜索框可以搜所有未完成的待办；没有想要的就一键新建一个今天的待办并关联
    private var taskRow: some View {
        let current = focus.run?.taskId ?? focus.task?.id
        let q = newTitle.trimmed
        let found = q.isEmpty ? [] : searchResults(q)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "scope").font(.system(size: 12, weight: .semibold)).foregroundStyle(Brand.orange)
                Text("专注什么").font(.callout.weight(.semibold))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6).padding(.bottom, 2)

            // 搜索 / 新建
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.tertiary)
                TextField(model.hasDida ? "搜索待办，或输入新建…" : "连接滴答清单后可搜索", text: $newTitle)
                    .textFieldStyle(.plain).font(.callout)
                    .disabled(!model.hasDida)
                    .onSubmit {
                        if let t = found.first { pick(t) } else { addTask() }
                    }
                if adding {
                    ProgressView().controlSize(.small)
                } else if !newTitle.isEmpty {
                    Button { newTitle = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(.tertiary) }
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .padding(.bottom, 4)

            if q.isEmpty {
                pickRow(icon: current == nil ? "checkmark.circle.fill" : "circle.dashed", title: "自由专注", trailing: nil, on: current == nil) {
                    focus.attach(nil)
                }
                if candidates.isEmpty {
                    Text(model.hasDida ? "没有可选的待办" : "连接滴答清单后可以关联待办")
                        .font(.caption).foregroundStyle(.tertiary).padding(.horizontal, 6).padding(.vertical, 6)
                }
                ForEach(candidates, id: \.0) { group in
                    Text(group.0).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.tertiary)
                        .padding(.horizontal, 6).padding(.top, 6)
                    ForEach(group.1) { t in taskPick(t, current) }
                }
            } else {
                if found.isEmpty {
                    Text("没有匹配的待办").font(.caption).foregroundStyle(.tertiary).padding(.horizontal, 6).padding(.vertical, 4)
                } else {
                    Text("搜索结果 \(found.count)").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.tertiary)
                        .padding(.horizontal, 6).padding(.top, 2)
                    ForEach(found) { t in taskPick(t, current) }
                }
                if model.hasDida {
                    Divider().padding(.vertical, 3)
                    Button(action: addTask) {
                        HStack(spacing: 8) {
                            Image(systemName: "plus.circle.fill").font(.system(size: 14)).foregroundStyle(Brand.orange)
                            Text("新建「\(q)」并关联").font(.callout).lineLimit(1)
                            Spacer(minLength: 4)
                            Text("今天").font(.caption).foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 6).padding(.vertical, 5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).disabled(adding)
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(radius: 14)
    }

    private func taskPick(_ t: DidaTask, _ current: String?) -> some View {
        let sub = t.time ?? t.date.map { Day.label($0) }
        return pickRow(icon: current == t.id ? "checkmark.circle.fill" : "circle", title: t.cleanTitle, trailing: sub, on: current == t.id) {
            pick(t)
        }
    }

    private func pick(_ t: DidaTask) {
        focus.attach(t)
        newTitle = ""
    }

    /// 在所有未完成的待办里按标题 / 标签 / 清单名搜索（空格分词，都要匹配），最多 8 条
    private func searchResults(_ q: String) -> [DidaTask] {
        guard let ov = model.overview else { return [] }
        let words = q.lowercased().split(whereSeparator: { $0 == " " || $0 == "　" }).map(String.init)
        guard !words.isEmpty else { return [] }
        let all = ov.overdue + ov.upcoming + ov.undated
        let hits = all.filter { t in
            let hay = (t.cleanTitle + " " + t.tags.joined(separator: " ") + " " + (ov.projectName(t.projectId) ?? "")).lowercased()
            return words.allSatisfy { hay.contains($0) }
        }
        return Array(hits.prefix(8))
    }

    private func pickRow(icon: String, title: String, trailing: String?, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 14))
                    .foregroundStyle(on ? Brand.orange : Color.secondary.opacity(0.7))
                Text(title).font(.callout.weight(on ? .semibold : .regular)).lineLimit(1)
                Spacer(minLength: 4)
                if let trailing { Text(trailing).font(.caption).foregroundStyle(.tertiary).monospacedDigit() }
            }
            .padding(.horizontal, 6).padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(on ? Brand.orange.opacity(0.10) : Color.clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 推荐的待办：今天的最前，其次逾期、接下来、无日期，每组只列前几个
    private var candidates: [(String, [DidaTask])] {
        guard let ov = model.overview else { return [] }
        let today = Day.today()
        let todayList = ov.upcoming.filter { $0.date == today }.sorted { ($0.time ?? "99:99") < ($1.time ?? "99:99") }
        return [
            ("今天", Array(todayList.prefix(6))),
            ("逾期", Array(ov.overdue.prefix(4))),
            ("接下来", Array(ov.upcoming.filter { ($0.date ?? "") > today }.prefix(3))),
            ("无日期", Array(ov.undated.prefix(3))),
        ].filter { !$0.1.isEmpty }
    }

    private func addTask() {
        let title = newTitle.trimmed
        guard !title.isEmpty, !adding else { return }
        adding = true
        Task {
            defer { adding = false }
            do {
                let created = try await model.dida.createTask(title: title, date: Day.today(), time: nil, priority: 0)
                await model.loadOverview(silent: true)
                let t = created ?? model.overview?.upcoming.first { $0.title == title && $0.date == Day.today() }
                if let t { focus.attach(t) }
                newTitle = ""
            } catch {
                model.showNotice("新建待办失败：" + error.localizedDescription)
            }
        }
    }

    // MARK: - 控制（圆形按钮，按钮下面一行小字）

    private func controls(_ run: FocusRun) -> some View {
        HStack(alignment: .top, spacing: 6) {
            if !run.kind.isBreak {
                roundButton("xmark", "放弃", filled: false) { confirmDiscard = true }
                roundButton("square.and.pencil", "记录", filled: false, on: showRecord) { showRecord.toggle() }
            }
            roundButton(run.paused ? "play.fill" : "pause.fill", run.paused ? "继续" : "暂停", filled: false) { focus.pauseOrResume() }
            roundButton(run.kind.isBreak ? "forward.end.fill" : "checkmark", run.kind.isBreak ? "结束休息" : "结束并记录", filled: true) {
                Task { await focus.finish() }
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// 所有按钮同样大小、同样宽的格子，圆心和文字都落在同一条线上
    private func roundButton(_ icon: String, _ label: String, filled: Bool, on: Bool = false, action: @escaping () -> Void) -> some View {
        VStack(spacing: 7) {
            Button(action: action) {
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(filled ? Brand.brown : (on ? Brand.orange : Color.primary))
                    .frame(width: 56, height: 56)
                    .background(filled ? Brand.orange : (on ? Brand.orange.opacity(0.16) : Color.primary.opacity(0.08)), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(width: 78, alignment: .top)
    }

    // MARK: - 专注中记录（参考安卓端「记录」）

    private func at(_ sec: Int) -> String { String(format: "%02d:%02d", sec / 60, sec % 60) }

    /// 这一次专注里已经写下的记录（输入框在计时环下面的「记录」按钮里）
    @ViewBuilder private var recordCard: some View {
        if let run = focus.run, !run.kind.isBreak, !run.recordList.isEmpty {
            let list = run.recordList
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        SectionTitle(text: "专注记录", count: list.count)
                        Spacer()
                        if model.recording { ProgressView().controlSize(.small) }
                    }
                    ForEach(Array(list.enumerated().reversed()), id: \.offset) { _, r in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(at(r.sec)).font(.caption.weight(.semibold)).foregroundStyle(Brand.orange).monospacedDigit()
                            Text(r.text).font(.callout).textSelection(.enabled)
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
        }
    }

    // MARK: - 滴答里读回来的

    private var todayCard: some View {
        HStack(spacing: 12) {
            if let s = focus.summary {
                StatTile(value: FocusParser.formatMinutes(s.todayMin), label: "今天专注" + (s.todayPomos > 0 ? "（\(s.todayPomos) 个番茄）" : ""), tint: Brand.orange)
                StatTile(value: FocusParser.formatMinutes(s.weekMin), label: "近 7 天" + (s.weekPomos > 0 ? "（\(s.weekPomos) 个番茄）" : ""))
            } else {
                StatTile(value: focus.loading ? "…" : "—", label: model.hasDida ? "今天专注" : "未连接滴答")
                StatTile(value: focus.loading ? "…" : "—", label: "近 7 天")
            }
        }
    }

    @ViewBuilder private var weekCard: some View {
        if let s = focus.summary, s.weekMin > 0 {
            let days = s.daily()
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    SectionTitle(text: "近 7 天")
                    Chart(days, id: \.day) { d in
                        BarMark(x: .value("日期", shortDay(d.day)), y: .value("分钟", d.minutes))
                            .foregroundStyle(d.day == Day.today() ? Brand.orange : Brand.orange.opacity(0.45))
                            .cornerRadius(3)
                    }
                    .chartXAxis { AxisMarks { _ in AxisValueLabel().font(.caption2) } }
                    .frame(height: 130)

                    let byTask = s.byTask.filter { $0.value.weekMin > 0 }.sorted { $0.value.weekMin > $1.value.weekMin }.prefix(5)
                    if !byTask.isEmpty {
                        Divider()
                        ForEach(Array(byTask), id: \.key) { id, f in
                            HStack {
                                Text(title(for: id, in: s)).lineLimit(1)
                                Spacer()
                                Text(FocusParser.formatMinutes(f.weekMin)).foregroundStyle(.secondary).monospacedDigit()
                            }
                            .font(.callout)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private var recentCard: some View {
        if let s = focus.summary, !s.sessions.isEmpty {
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    SectionTitle(text: "最近几次")
                    ForEach(Array(s.sessions.reversed().prefix(8))) { x in
                        HStack(spacing: 10) {
                            Text(timeRange(x)).font(.caption).foregroundStyle(.secondary).monospacedDigit().frame(width: 128, alignment: .leading)
                            Text(x.taskId.map { title(for: $0, in: s) } ?? "自由专注").lineLimit(1)
                            Spacer()
                            Text("\(x.minutes) 分钟").foregroundStyle(.secondary).monospacedDigit()
                        }
                        .font(.callout)
                    }
                }
            }
        }
    }

    private func title(for id: String, in s: FocusSummary) -> String {
        s.titles[id] ?? model.localTask(id)?.cleanTitle ?? "（未命名任务）"
    }

    private func timeRange(_ x: FocusSession) -> String {
        let a = Date(timeIntervalSince1970: Double(x.startMs) / 1000), b = Date(timeIntervalSince1970: Double(x.endMs) / 1000)
        let day = Day.string(a)
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        let label = day == Day.today() ? "今天" : (day == Day.add(Day.today(), days: -1) ? "昨天" : String(day.dropFirst(5)))
        return "\(label) \(f.string(from: a))–\(f.string(from: b))"
    }

    private func shortDay(_ s: String) -> String {
        let p = s.split(separator: "-")
        guard p.count == 3, let m = Int(p[1]), let d = Int(p[2]) else { return s }
        return "\(m)/\(d)"
    }

    private func banner(_ text: String, action: (String, () -> Void)?) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle").foregroundStyle(Brand.orange)
            Text(text).font(.callout)
            Spacer(minLength: 0)
            if let action { Button(action.0, action: action.1).buttonStyle(.link) }
        }
        .padding(10)
        .glassCard(radius: 12, tint: Brand.orange.opacity(0.18))
    }
}

/// 侧边栏里的「专注」页
struct FocusPage: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Text("专注").font(.largeTitle.bold())
                    if model.focus.loading { ProgressView().controlSize(.small) }
                    Spacer()
                }
                FocusView(focus: model.focus)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .frame(maxWidth: 1000, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(AmbientBackground())
        .task {
            await model.focus.settle()
            if !model.isFresh("focus", key: "f", within: 60) {
                await model.focus.refresh()
                model.stamp("focus", key: "f")
            }
        }
    }
}


/// 计时圆盘：粗圆环 + 60 根刻度 + 四个方位的数值 + 可拖的把手（没开始时）。尺寸、比例和安卓端 TimerCard 一致。
struct FocusDial<Center: View>: View {
    var fraction: Double
    var arc: Color
    var idle: Bool
    var maxMin: Int
    var minMin: Int
    /// 专注中记录的位置（占整段时长的比例），在圆环上画成小圆点
    var marks: [Double] = []
    var onMinutes: (Int) -> Void
    @ViewBuilder var center: Center

    @State private var last: Double?

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let s = side / 300
            let stroke = 26 * s
            let outerR = side / 2 - 2 * s
            let ringR = outerR - stroke / 2
            let tickOuter = outerR - stroke - 8 * s
            let labelR = tickOuter - 10 * s - 14 * s
            let c = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)

            ZStack {
                Circle().stroke(Color.primary.opacity(0.09), lineWidth: stroke)
                    .frame(width: ringR * 2, height: ringR * 2)
                Circle().trim(from: 0, to: fraction)
                    .stroke(arc, style: StrokeStyle(lineWidth: stroke, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: ringR * 2, height: ringR * 2)
                    .animation(idle ? nil : .linear(duration: 0.5), value: fraction)

                Canvas { ctx, _ in
                    for i in 0 ..< 60 {
                        let long = i % 5 == 0
                        let len = (long ? 10 : 5) * s
                        let rad = Double(i) * 6 * .pi / 180 - .pi / 2
                        let dx = cos(rad), dy = sin(rad)
                        var p = Path()
                        p.move(to: CGPoint(x: c.x + dx * tickOuter, y: c.y + dy * tickOuter))
                        p.addLine(to: CGPoint(x: c.x + dx * (tickOuter - len), y: c.y + dy * (tickOuter - len)))
                        let on = Double(i) / 60 < fraction || (i == 0 && fraction > 0)
                        ctx.stroke(p, with: .color(Color.primary.opacity(on ? 0.55 : 0.16)),
                                   style: StrokeStyle(lineWidth: (long ? 2 : 1.2) * s, lineCap: .round))
                    }
                }

                ForEach(Array(marks.enumerated()), id: \.offset) { _, m in
                    let a = (360 * (1 - min(max(m, 0), 1)) - 90) * .pi / 180
                    let p = CGPoint(x: c.x + cos(a) * ringR, y: c.y + sin(a) * ringR)
                    Circle().fill(Color.white).frame(width: stroke * 0.6, height: stroke * 0.6).position(p)
                    Circle().fill(arc).frame(width: stroke * 0.24, height: stroke * 0.24).position(p)
                }

                if idle {
                    ForEach(Array([(maxMin, 0.0), (maxMin / 4, 90.0), (maxMin / 2, 180.0), (maxMin * 3 / 4, 270.0)].enumerated()), id: \.offset) { _, item in
                        let rad = (item.1 - 90) * .pi / 180
                        Text("\(item.0)")
                            .font(.system(size: 12, weight: .bold)).foregroundStyle(.secondary)
                            .position(x: c.x + cos(rad) * labelR, y: c.y + sin(rad) * labelR)
                    }
                    // 把手
                    let a = (360 * fraction - 90) * .pi / 180
                    let h = CGPoint(x: c.x + cos(a) * ringR, y: c.y + sin(a) * ringR)
                    Circle().fill(Color.black.opacity(0.18)).frame(width: stroke * 0.92, height: stroke * 0.92)
                        .position(x: h.x, y: h.y + 1.5)
                    Circle().fill(Color.white).frame(width: stroke * 0.84, height: stroke * 0.84).position(h)
                    Circle().fill(arc).frame(width: stroke * 0.32, height: stroke * 0.32).position(h)
                }

                center
                    .position(c)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in if idle { pick(v.location, c) } }
                    .onEnded { _ in last = nil }
            )
        }
        .aspectRatio(1, contentMode: .fit)
    }

    /// 点 / 拖的位置 → 分钟数；防止从 0 点附近一跨就从最大值跳到最小值
    private func pick(_ p: CGPoint, _ c: CGPoint) {
        let dx = p.x - c.x, dy = p.y - c.y
        // 点到圆心附近（开始按钮、数字）不改时长
        guard hypot(dx, dy) > 62 || last != nil else { return }
        var deg = atan2(dx, -dy) * 180 / .pi
        if deg < 0 { deg += 360 }
        var f = deg / 360
        let ref = last ?? fraction
        if ref > 0.75 && f < 0.25 { f = 1 } else if ref < 0.25 && f > 0.75 { f = 0 }
        let m = min(max(Int((f * Double(maxMin)).rounded()), minMin), maxMin)
        last = Double(m) / Double(maxMin)
        if m != Int((fraction * Double(maxMin)).rounded()) { onMinutes(m) }
    }
}

/// 两栏按比例分宽（leading : 1 - leading），顶对齐，高度取两栏里高的那个
struct RatioColumns: Layout {
    var leading: CGFloat = 2.0 / 3.0
    var spacing: CGFloat = 16

    private func widths(_ total: CGFloat) -> (CGFloat, CGFloat) {
        let avail = max(total - spacing, 0)
        return (avail * leading, avail * (1 - leading))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        let w = proposal.width ?? 520   // 没给宽度时报最小宽度，ViewThatFits 才会选两栏
        let (lw, tw) = widths(w)
        let a = subviews[0].sizeThatFits(ProposedViewSize(width: lw, height: nil))
        let b = subviews[1].sizeThatFits(ProposedViewSize(width: tw, height: nil))
        return CGSize(width: w, height: max(a.height, b.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let (lw, tw) = widths(bounds.width)
        subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.minY), anchor: .topLeading, proposal: ProposedViewSize(width: lw, height: nil))
        subviews[1].place(at: CGPoint(x: bounds.minX + lw + spacing, y: bounds.minY), anchor: .topLeading, proposal: ProposedViewSize(width: tw, height: nil))
    }
}
