import AppKit
import Foundation
import SwiftUI
import UserNotifications

/// 专注：在应用里倒计时，结束后用滴答 MCP 的 `create_focus` 写进滴答（手机 / 电脑 / 网页的滴答里都能看到）；
/// 同时用 `get_focuses_by_time` 把滴答里已有的专注读回来显示。移植自安卓端 `FocusRepository`。
/// 计时状态存在本机（UserDefaults），退出应用也不丢：重新打开时对账，到点的会自动结算。
@MainActor
final class FocusStore: ObservableObject {
    static let cycleLength = 4
    static let choices = [15, 25, 45, 60, 90]
    private static let minRecordMs: Int64 = 60_000

    @Published private(set) var run: FocusRun?
    @Published private(set) var pending: [PendingFocus]
    @Published private(set) var summary: FocusSummary?
    @Published private(set) var pendingBreak: FocusKind?
    /// 当前这一轮已经完成的番茄数（跨天清零）
    @Published private(set) var cycle: Int
    /// 每秒一次的时钟：单独放一个对象，只有显示倒计时的那几小块订阅它，整个页面不再每秒重画
    let clock = FocusClock()
    @Published var minutes: Int
    /// 刚结束的一次专注的成果小票（含期间的记录），专注页上显示一张可关闭的卡
    @Published var receipt: Celebration?
    /// 专注中「记录」输入框里还没发出去的文字（关掉再打开不丢）
    @Published var recordDraft = ""
    @Published var task: DidaTask?
    @Published var loading = false
    @Published var error: String?

    private let api: DidaApi
    private let hasDida: () -> Bool
    /// 绑定了结审任务的专注：写回结审，不写滴答（由 AppModel 提供）
    var sjzSink: ((PendingFocus) async throws -> Void)?
    private var ticker: Timer?
    private var finishing = false
    private let defaults = UserDefaults.standard
    /// 结束 / 同步结果的提示（主窗口 Toast）
    var onMessage: ((String) -> Void)?
    /// 倒计时自然走完时回调（灵动岛用来弹出提醒）：种类、专注分钟数（休息为 0）
    var onCompleted: ((FocusKind, Int) -> Void)?
    /// 一次专注记录完成（走完或提前结束）：带着成果小票，用来在屏幕上「打印」小票
    var onTicket: ((Celebration) -> Void)?

    init(api: DidaApi, hasDida: @escaping () -> Bool) {
        self.api = api
        self.hasDida = hasDida
        let d = UserDefaults.standard
        run = d.data(forKey: "focus.session").flatMap { try? JSONDecoder().decode(FocusRun.self, from: $0) }
        pending = d.data(forKey: "focus.pending").flatMap { try? JSONDecoder().decode([PendingFocus].self, from: $0) } ?? []
        pendingBreak = d.string(forKey: "focus.break").flatMap(FocusKind.init(rawValue:)).flatMap { $0.isBreak ? $0 : nil }
        cycle = d.string(forKey: "focus.cycleDay") == Day.today() ? min(max(d.integer(forKey: "focus.cycle"), 0), Self.cycleLength) : 0
        let last = d.integer(forKey: "focus.lastMinutes")
        minutes = last > 0 ? last : FocusKind.focus.defaultMin
        if let b = pendingBreak { minutes = b.defaultMin }
        updateTicker()
        BackgroundActivity.set(run != nil)
    }

    /// 没在计时时界面上显示的种类：该休息就是休息，否则是专注
    var idleKind: FocusKind { pendingBreak ?? .focus }
    var shownKind: FocusKind { run?.kind ?? idleKind }
    private var nowMs: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    // MARK: - 计时控制

    func start() {
        guard run == nil else { return }
        let kind = idleKind
        // 先把表盘上选的分钟数记下来：skipBreak / setBreak 会把 minutes 重置回上次的值，不先存就会被冲回 25
        let chosen = minutes
        if !kind.isBreak { skipBreak() } else { setBreak(nil, keepMinutes: true) }
        minutes = chosen
        let m = min(max(chosen, kind.minMin), kind.maxMin)
        if !kind.isBreak { defaults.set(m, forKey: "focus.lastMinutes") }
        let r = FocusRun(
            taskId: kind.isBreak ? nil : task?.id,
            projectId: kind.isBreak ? nil : task?.projectId,
            title: kind.isBreak ? "" : (task?.cleanTitle ?? ""),
            startMs: nowMs, plannedMin: m, kind: kind
        )
        setRun(r)
        Notifier.shared.setup()
    }

    /// 一键开始专注时用的分钟数：该休息时 `minutes` 是休息的时长，专注要用上次的专注时长
    var focusMinutes: Int {
        guard pendingBreak != nil else { return minutes }
        let last = defaults.integer(forKey: "focus.lastMinutes")
        return last > 0 ? last : FocusKind.focus.defaultMin
    }

    /// 快捷开始：直接按 [m] 分钟开一个专注（该休息时先跳过休息）
    func quickFocus(_ m: Int) {
        guard run == nil else { return }
        if pendingBreak != nil { skipBreak() }
        minutes = m
        start()
    }

    /// 专注过程中记一句想法 / 进展：先记在这次专注里（页面上马上看到），写进任务笔记由 AppModel.recordFocus 负责
    func addRecord(_ text: String) {
        guard var s = run, !s.kind.isBreak else { return }
        let t = text.trimmed
        guard !t.isEmpty else { return }
        s.records = (s.records ?? []) + [t]
        s.recordSecs = (s.recordSecs ?? []) + [Int(s.elapsedMs(nowMs) / 1000)]
        setRun(s)
    }

    func dismissReceipt() { receipt = nil }

    func pauseOrResume() {
        guard var s = run else { return }
        if let at = s.pausedAtMs {
            s.pausedTotalMs += nowMs - at
            s.pausedAtMs = nil
        } else {
            s.pausedAtMs = nowMs
        }
        setRun(s)
    }

    /// 放弃：不记录
    func discard() { setRun(nil) }

    /// 专注进行中补关联任务
    func attach(_ t: DidaTask?) {
        task = t
        guard var s = run, !s.kind.isBreak else { return }
        s.taskId = t?.id
        s.projectId = t?.projectId
        s.title = t?.cleanTitle ?? ""
        setRun(s)
    }

    /// 结束休息：同步完成，按钮点下去立刻生效，不经过任何 await
    func endBreak() {
        guard let s = run, s.kind.isBreak else { return }
        let completed = s.isDue(nowMs)
        setBreak(nil)
        if s.kind == .longBreak { saveCycle(0) }
        setRun(nil)
        if completed {
            Self.notify(title: "\(s.kind.label)结束", body: "准备好开始下一个专注了吗？")
            onCompleted?(s.kind, 0)
        }
    }

    /// 结束并记录。倒计时走完或「提前结束」都走这里：按实际专注的时长记，不足 1 分钟不记。先落盘再上传。
    func finish() async {
        guard let s = run else { return }
        // 休息的结束不能被「上一次专注还在上传 / 刷新」挡住：上传卡住时 finishing 会一直是 true，休息就结束不了
        if s.kind.isBreak { endBreak(); return }
        guard !finishing else { return }
        finishing = true
        defer { finishing = false }
        let n = nowMs
        let elapsed = s.elapsedMs(n)
        let completed = s.isDue(n)
        if completed { onPomodoroCompleted() }
        setRun(nil)
        guard elapsed >= Self.minRecordMs else {
            onMessage?("不足 1 分钟，没有记录")
            return
        }
        pending.append(PendingFocus(startMs: s.startMs, endMs: s.startMs + elapsed, taskId: s.taskId, title: s.title))
        savePending()
        await flush()
        let mins = max(Int((Double(elapsed) / 60000).rounded()), 1)
        let synced = pending.isEmpty
        let toSjz = SjzTasks.owns(s.taskId ?? "")
        let head = completed ? "番茄完成" : "专注已记录"
        let recs = s.recordList
        // 今日累计：滴答里读回来的、本机小票里记的，取大的，再加上这一次
        let base = max(summary?.todayMin ?? 0, TicketStore.shared.todayMinutes)
        let c = Celebration(
            title: s.title, minutes: mins, round: completed ? cycle : 0, completed: completed,
            records: recs.map { Celebration.Entry(tag: String(format: "%02d:%02d", $0.sec / 60, $0.sec % 60), text: $0.text) },
            todayMin: base + mins,
            cheer: Cheer.pomodoro(hasRecords: !recs.isEmpty, completed: completed)
        )
        TicketStore.shared.add(c)
        receipt = c
        onMessage?("\(head)：\(mins) 分钟" + (recs.isEmpty ? "" : "，\(recs.count) 条记录") + (synced ? (toSjz ? "，已写入结审" : "，已写入滴答") : "，已存在本机，稍后同步"))
        if completed {
            Self.notify(title: "番茄完成", body: "专注了 \(mins) 分钟" + (pendingBreak.map { "，休息一下（\($0.label)）" } ?? ""))
            onCompleted?(.focus, mins)
        }
        onTicket?(c)
        await refresh()
        checkGoal()
    }

    /// 对账：倒计时到点了就结束并记录，再把之前没传成功的记录补传
    func settle() async {
        if let s = run, s.isDue(nowMs) { await finish() }
        else if !pending.isEmpty {
            let before = pending.count
            await flush()
            if pending.count < before { await refresh() }
        }
    }

    func syncNow() async {
        await flush()
        await refresh()
        if pending.isEmpty { onMessage?("专注记录已同步到滴答") }
    }

    func skipBreak() {
        if pendingBreak == .longBreak { saveCycle(0) }
        setBreak(nil)
    }

    // MARK: - 滴答里的专注

    func refresh() async {
        guard hasDida() else { summary = nil; return }
        loading = true
        defer { loading = false }
        do {
            summary = try await api.focusWeek()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - 内部

    private func onPomodoroCompleted() {
        let n = cycle + 1
        if n >= Self.cycleLength {
            saveCycle(Self.cycleLength)
            setBreak(.longBreak)
        } else {
            saveCycle(n)
            setBreak(.shortBreak)
        }
    }

    private func setBreak(_ k: FocusKind?, keepMinutes: Bool = false) {
        pendingBreak = k
        if let k { defaults.set(k.rawValue, forKey: "focus.break") } else { defaults.removeObject(forKey: "focus.break") }
        if !keepMinutes {
            let last = defaults.integer(forKey: "focus.lastMinutes")
            minutes = k?.defaultMin ?? (last > 0 ? last : FocusKind.focus.defaultMin)
        }
    }

    private func saveCycle(_ n: Int) {
        cycle = n
        defaults.set(n, forKey: "focus.cycle")
        defaults.set(Day.today(), forKey: "focus.cycleDay")
    }

    private func setRun(_ r: FocusRun?) {
        run = r
        BackgroundActivity.set(r != nil)
        if let r, let data = try? JSONEncoder().encode(r) { defaults.set(data, forKey: "focus.session") }
        else { defaults.removeObject(forKey: "focus.session") }
        clock.set(Date())
        updateTicker()
        Self.cancelScheduled()
        if let r { if r.paused { Self.scheduleNag(r) } else { Self.schedule(r) } }
    }

    /// 按顺序补传；碰到一条失败就停（多半是断网，别连着失败）
    private func flush() async {
        for p in pending {
            let sjz = SjzTasks.owns(p.taskId ?? "")
            if !sjz && !hasDida() { continue }
            do {
                if sjz {
                    guard let sink = sjzSink else { continue }
                    try await sink(p)
                } else {
                    try await api.createFocus(startMs: p.startMs, endMs: p.endMs, taskId: p.taskId)
                }
            } catch {
                self.error = "同步专注失败：" + error.localizedDescription
                break
            }
            pending.removeAll { $0 == p }
            savePending()
        }
    }

    private func savePending() {
        if let d = try? JSONEncoder().encode(pending) { defaults.set(d, forKey: "focus.pending") }
    }

    private func updateTicker() {
        if run != nil, !(run?.paused ?? true) {
            guard ticker == nil else { return }
            ticker = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            ticker?.tolerance = 0.1
        } else {
            ticker?.invalidate()
            ticker = nil
        }
    }

    private func tick() {
        clock.set(Date())
        if let s = run, s.isDue(nowMs) { Task { await finish() } }
    }

    // MARK: - 系统通知（到点提醒；应用退出后也会响）

    private static let notifyId = "shiyi.focus.end"
    private static let warnId = "shiyi.focus.warn"
    private static let nagId = "shiyi.focus.paused"

    /// 到点提醒 + 「还剩 5 分钟」（专注 ≥ 15 分钟时）；应用退出后也会响
    private static func schedule(_ r: FocusRun) {
        guard NotifyPrefs.on("notify.focus") else { return }
        let left = Double(r.endAtMs) / 1000 - Date().timeIntervalSince1970
        Notifier.schedule(
            id: notifyId,
            title: r.kind.isBreak ? "\(r.kind.label)结束" : "番茄完成",
            body: r.kind.isBreak ? "准备好开始下一个专注了吗？" : "专注了 \(r.plannedMin) 分钟，休息一下",
            after: left
        )
        if !r.kind.isBreak, r.plannedMin >= 15, left > 5 * 60 + 5 {
            Notifier.schedule(id: warnId, title: "还剩 5 分钟", body: r.title.isEmpty ? "再坚持一下，马上完成这个番茄" : "「\(r.title)」再坚持一下", after: left - 5 * 60)
        }
    }

    /// 暂停超过 5 分钟还没继续，提醒一下
    private static func scheduleNag(_ r: FocusRun) {
        guard NotifyPrefs.on("notify.focus") else { return }
        Notifier.schedule(
            id: nagId,
            title: r.kind.isBreak ? "休息暂停着" : "专注暂停了 5 分钟",
            body: r.kind.isBreak ? "继续休息，还是直接开始下一个专注？" : "继续专注，还是结束并记录？",
            after: 5 * 60
        )
    }

    private static func cancelScheduled() {
        Notifier.cancel([notifyId, warnId, nagId])
    }

    /// 立刻发一条（相同 id 会替换已排好的那条，避免响两次）
    private static func notify(title: String, body: String) {
        guard NotifyPrefs.on("notify.focus") else { return }
        Notifier.post(id: notifyId, title: title, body: body)
    }

    /// 今日专注量第一次达到每日目标时提醒一次
    private func checkGoal() {
        guard NotifyPrefs.on("notify.goal"), let m = summary?.todayMin else { return }
        let stored = defaults.integer(forKey: "focus.goalMin")
        let goal = stored > 0 ? stored : 120
        let day = Day.today()
        guard m >= goal, defaults.string(forKey: "notify.goalDay") != day else { return }
        defaults.set(day, forKey: "notify.goalDay")
        Notifier.post(id: "shiyi.focus.goal", title: "今日专注目标达成", body: "今天已经专注 \(FocusParser.formatMinutes(m))，目标 \(FocusParser.formatMinutes(goal))。")
    }
}


/// 每秒走一次的时钟（只在计时进行中才会被 FocusStore 驱动）
@MainActor
final class FocusClock: ObservableObject {
    @Published private(set) var now = Date()
    func set(_ d: Date) { now = d }
    var nowMs: Int64 { Int64(now.timeIntervalSince1970 * 1000) }
}
