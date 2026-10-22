import Foundation

// 移植自安卓端 `FocusRepository.kt`（FocusKind / FocusRun / PendingFocus）和 `DidaHabits.kt`（FocusParser）。

/// 倒计时的种类：专注 / 短休息 / 长休息。休息不记入滴答，也不绑定任务
enum FocusKind: String, Codable, CaseIterable, Identifiable {
    case focus = "FOCUS", shortBreak = "SHORT_BREAK", longBreak = "LONG_BREAK"
    var id: String { rawValue }

    var label: String {
        switch self {
        case .focus: return "专注"
        case .shortBreak: return "短休息"
        case .longBreak: return "长休息"
        }
    }

    var defaultMin: Int {
        switch self {
        case .focus: return 25
        case .shortBreak: return 5
        case .longBreak: return 15
        }
    }

    var isBreak: Bool { self != .focus }
    var maxMin: Int { isBreak ? 60 : 120 }
    var minMin: Int { isBreak ? 1 : 5 }
}

/// 正在进行的一次专注（倒计时）。起止用挂钟毫秒时间戳存盘，进程被杀后也能接着算。
/// 暂停：记下暂停开始的时刻；继续时把这段加进 pausedTotalMs，所以「已专注」不含暂停的时间。
struct FocusRun: Codable, Equatable {
    var taskId: String?
    var projectId: String?
    var title: String = ""
    var startMs: Int64
    var plannedMin: Int
    var pausedAtMs: Int64?
    var pausedTotalMs: Int64 = 0
    var kind: FocusKind = .focus
    /// 专注过程中记下的想法 / 进展，以及各自是在专注开始后第几秒记的（可选：老版本存下来的计时里没有）
    var records: [String]?
    var recordSecs: [Int]?

    var recordList: [(sec: Int, text: String)] {
        let r = records ?? [], s = recordSecs ?? []
        return r.enumerated().map { (sec: $0 < s.count ? s[$0] : 0, text: $1) }
    }

    var paused: Bool { pausedAtMs != nil }
    var plannedMs: Int64 { Int64(plannedMin) * 60_000 }

    /// 已专注多久（不含暂停），最多不超过计划时长
    func elapsedMs(_ now: Int64) -> Int64 { min(max((pausedAtMs ?? now) - startMs - pausedTotalMs, 0), plannedMs) }
    func remainingMs(_ now: Int64) -> Int64 { plannedMs - elapsedMs(now) }
    /// 倒计时已走完（容许 1 秒误差）
    func isDue(_ now: Int64) -> Bool { !paused && remainingMs(now) <= 1000 }
    /// 进行中时，倒计时归零的挂钟时刻
    var endAtMs: Int64 { startMs + pausedTotalMs + plannedMs }
}

/// 刚结束的一次专注的小结（只在本次运行里显示一张卡）
struct FocusReceipt: Identifiable {
    let id = UUID()
    var title: String
    var minutes: Int
    var completed: Bool
    var records: [(sec: Int, text: String)]
}

/// 已经结束、但还没成功写进滴答的一条记录（断网 / 接口失败时留在本机，之后自动重试）
struct PendingFocus: Codable, Equatable {
    var startMs: Int64
    var endMs: Int64
    var taskId: String?
    var title: String
}

/// 一次专注：起止时刻（毫秒时间戳）
struct FocusSession: Identifiable, Hashable {
    var startMs: Int64
    var endMs: Int64
    var taskId: String?
    var title: String?
    var id: Int64 { startMs }
    var minutes: Int { Int((Double(endMs - startMs) / 60000).rounded()) }
}

struct TaskFocus {
    var todayMin = 0, todayCount = 0, weekMin = 0, weekCount = 0
}

struct FocusSummary {
    var todayMin = 0
    var todayPomos = 0
    var weekMin = 0
    var weekPomos = 0
    var byTask: [String: TaskFocus] = [:]
    var titles: [String: String] = [:]
    /// 范围内每一次专注，按开始时间从早到晚
    var sessions: [FocusSession] = []

    /// 近 7 天每天的专注分钟（含今天）
    func daily(days: Int = 7) -> [(day: String, minutes: Int)] {
        let today = Day.today()
        var by: [String: Int] = [:]
        for s in sessions { by[Day.string(Date(timeIntervalSince1970: Double(s.startMs) / 1000)), default: 0] += s.minutes }
        return (0 ..< days).map { i in
            let d = Day.add(today, days: i - (days - 1))
            return (d, by[d] ?? 0)
        }
    }
}

enum FocusParser {
    /// [texts]：(是否番茄钟, 返回文本)
    static func summarize(_ texts: [(Bool, String)], today: Date) -> FocusSummary {
        let todayStart = Int64(Day.startOfDay(today).timeIntervalSince1970 * 1000)
        var seen = Set<String>()
        var out = FocusSummary()
        for (isPomo, text) in texts {
            var found: [JSON] = []
            for v in DidaParser.parseAny(text) {
                DidaParser.collectObjects(v, { DidaParser.str($0, "startTime") != nil && DidaParser.str($0, "endTime") != nil }, &found)
            }
            for o in found {
                guard let start = DidaParser.parseMs(DidaParser.str(o, "startTime")),
                      let end = DidaParser.parseMs(DidaParser.str(o, "endTime")), end > start else { continue }
                let id = DidaParser.str(o, "id") ?? "\(isPomo ? "pomo" : "timing")-\(start)"
                guard seen.insert(id).inserted else { continue }
                let minutes = Int((Double(end - start) / 60000).rounded())
                let isToday = start >= todayStart
                out.weekMin += minutes
                if isPomo { out.weekPomos += 1 }
                if isToday {
                    out.todayMin += minutes
                    if isPomo { out.todayPomos += 1 }
                }
                var ids: [String] = []
                if let t = DidaParser.str(o, "taskId"), !t.isEmpty { ids.append(t) }
                for case let b as JSON in (o["tasks"] as? [Any]) ?? [] {
                    guard let tid = DidaParser.str(b, "taskId") ?? DidaParser.str(b, "id"), !tid.isEmpty else { continue }
                    if !ids.contains(tid) { ids.append(tid) }
                    if let title = DidaParser.str(b, "title"), !title.isEmpty { out.titles[tid] = title }
                }
                out.sessions.append(FocusSession(startMs: start, endMs: end, taskId: ids.first, title: ids.compactMap { out.titles[$0] }.first))
                for tid in ids {
                    var f = out.byTask[tid] ?? TaskFocus()
                    if isToday { f.todayMin += minutes; f.todayCount += 1 }
                    f.weekMin += minutes
                    f.weekCount += 1
                    out.byTask[tid] = f
                }
            }
        }
        out.sessions.sort { $0.startMs < $1.startMs }
        return out
    }

    static func formatMinutes(_ min: Int) -> String {
        if min < 60 { return "\(min) 分钟" }
        if min % 60 == 0 { return "\(min / 60) 小时" }
        return "\(min / 60) 小时 \(min % 60) 分钟"
    }
}

extension DidaApi {
    /// type：0 番茄钟 / 1 正计时。区间为 [from, toExclusive)
    func focusRaw(from: String, toExclusive: String, type: Int) async throws -> String {
        try await mcp.callText("get_focuses_by_time", [
            "from_time": Day.dueString(from),
            "to_time": Day.dueString(toExclusive),
            "type": type,
        ])
    }

    /// 近 7 天（含今天）的专注记录；番茄钟与正计时都读，两个都失败才抛异常
    func focusWeek() async throws -> FocusSummary {
        let today = Day.today()
        let from = Day.add(today, days: -6), to = Day.add(today, days: 1)
        async let pomo: Result<String, Error> = Self.attempt { try await focusRaw(from: from, toExclusive: to, type: 0) }
        async let timing: Result<String, Error> = Self.attempt { try await focusRaw(from: from, toExclusive: to, type: 1) }
        let a = await pomo, b = await timing
        if case let .failure(e) = a, case .failure = b { throw e }
        return FocusParser.summarize([(true, (try? a.get()) ?? ""), (false, (try? b.get()) ?? "")], today: Date())
    }

    private static func attempt(_ f: () async throws -> String) async -> Result<String, Error> {
        do { return .success(try await f()) } catch { return .failure(error) }
    }

    /// 写入一条专注记录（番茄钟，type 0）；taskId 为空 = 不关联任务。起止时间用 UTC（带 Z）
    func createFocus(startMs: Int64, endMs: Int64, taskId: String?) async throws {
        func iso(_ ms: Int64) -> String {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime]
            return f.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
        }
        var args: JSON = ["start_time": iso(startMs), "end_time": iso(endMs), "type": 0, "client_timezone": TimeZone.current.identifier]
        if let taskId, !taskId.isEmpty { args["task_id"] = taskId }
        _ = try await mcp.callText("create_focus", args)
    }
}
