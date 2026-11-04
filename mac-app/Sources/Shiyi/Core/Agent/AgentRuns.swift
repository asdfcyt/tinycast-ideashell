import AppKit
import Foundation
import Darwin

/// 一个正在跑的 Agent 会话（只在运行期间存在）
struct AgentRun: Identifiable, Equatable {
    let id: String
    var source: AgentSource
    var project: String
    var started: Date
    /// 正在做什么：「Bash · npm run build」
    var activity: String?
    /// 能不能从岛上停掉它（目前只有装了新版插件的 opencode）
    var canStop = false
    /// 已经点了停止，等它收尾
    var stopping = false
    /// 它所在的进程（opencode 插件上报）：用来找到它的终端 / 编辑器窗口
    var pid: Int32?
}

/// 各 Agent 的运行状态：钩子事件（提交提问 / 每次工具调用后 / 一轮结束）驱动，只在真的在跑时显示在岛上。
/// 万一 Agent 被中途杀掉没来得及发「结束」，长时间没有动静的会话会被自动清掉。
@MainActor
final class AgentRunTracker: ObservableObject {
    static let shared = AgentRunTracker()

    @Published private(set) var runs: [AgentRun] = []
    private var sweeper: Task<Void, Never>?
    private let staleAfter: TimeInterval = 300
    /// 最近一次有动静的时间：不放进 `runs`（它一变整个岛就要重绘），清理长时间没动静的会话时才用
    private var beats: [String: Date] = [:]
    /// 「正在做什么」最快 1 秒更新一次：opencode 一秒能调好几个工具，逐条刷新会让岛一直在重排
    private var lastActivityAt: [String: Date] = [:]
    private var pendingActivity: [String: String] = [:]
    private var flushing = false
    private let activityGap: TimeInterval = 1.0

    static var enabled: Bool { UserDefaults.standard.bool(forKey: AgentPrefs.runStatus) }

    private static func key(_ s: AgentSource, _ session: String) -> String { "\(s.rawValue)|\(session)" }

    /// 有动静了（restart = 新一轮开始，重新计时）
    func beat(_ s: AgentSource, session: String, project: String, activity: String? = nil, restart: Bool = false, canStop: Bool = false, pid: Int32? = nil) {
        guard Self.enabled else { return }
        let id = Self.key(s, session)
        let now = Date()
        beats[id] = now
        if let i = runs.firstIndex(where: { $0.id == id }) {
            if restart {
                runs[i].started = now
                runs[i].activity = nil
                pendingActivity[id] = nil
                lastActivityAt[id] = now
            } else if let activity, activity != runs[i].activity {
                if now.timeIntervalSince(lastActivityAt[id] ?? .distantPast) >= activityGap {
                    runs[i].activity = activity
                    lastActivityAt[id] = now
                    pendingActivity[id] = nil
                } else {
                    pendingActivity[id] = activity
                    scheduleFlush()
                }
            }
            if runs[i].project != project { runs[i].project = project }
            if runs[i].canStop != canStop { runs[i].canStop = canStop }
            if let pid, runs[i].pid != pid { runs[i].pid = pid }
            if restart, runs[i].stopping { runs[i].stopping = false }
        } else {
            runs.append(AgentRun(id: id, source: s, project: project, started: now, activity: activity, canStop: canStop, pid: pid))
            lastActivityAt[id] = now
        }
        startSweeper()
    }

    /// 把被压住的最新一条「正在做什么」补上
    private func scheduleFlush() {
        guard !flushing else { return }
        flushing = true
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((self?.activityGap ?? 1) * 1_000_000_000))
            guard let self else { return }
            self.flushing = false
            let now = Date()
            for (id, text) in self.pendingActivity {
                if let i = self.runs.firstIndex(where: { $0.id == id }), self.runs[i].activity != text { self.runs[i].activity = text }
                self.lastActivityAt[id] = now
            }
            self.pendingActivity.removeAll()
        }
    }

    /// 进程已经不在了（被杀掉 / 终端关了）：这一行没有意义，直接清掉
    nonisolated private static func isDead(_ pid: Int32?) -> Bool {
        guard let pid else { return false }
        return kill(pid, 0) != 0 && errno == ESRCH
    }

    private func dropDead() {
        let dead = runs.filter { Self.isDead($0.pid) }
        guard !dead.isEmpty else { return }
        dead.forEach { forget($0.id) }
        runs.removeAll { r in dead.contains { $0.id == r.id } }
    }

    /// 打开正在跑的 Agent 所在的窗口：桌面 App 直接激活；opencode 往上找它所在的终端 / 编辑器
    func open(_ r: AgentRun) {
        if Self.isDead(r.pid) { dropDead(); return }
        if r.source != .opencode {
            ApprovalCenter.shared.openSource(r.source)
            return
        }
        let pid = r.pid
        Task { [weak self] in
            let app: NSRunningApplication? = await Task.detached(priority: .userInitiated) {
                guard let pid else { return nil }
                return Self.hostApp(of: pid)
            }.value
            if let app {
                app.activate(options: [.activateAllWindows])
            } else if NSWorkspace.shared.urlForApplication(withBundleIdentifier: r.source.bundleID) != nil {
                ApprovalCenter.shared.openSource(r.source)
            } else {
                _ = self
                AppModel.current?.showNotice("这个 opencode 没有窗口（后台任务，或旧版插件没上报位置）")
            }
        }
    }

    /// 顺着父进程一路往上，找到第一个有图形界面的 App（终端 / 编辑器），不算拾忆自己
    nonisolated private static func hostApp(of pid: Int32) -> NSRunningApplication? {
        var cur = pid
        for _ in 0 ..< 16 {
            var info = proc_bsdinfo()
            let n = proc_pidinfo(cur, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
            guard n > 0 else { return nil }
            let parent = Int32(info.pbi_ppid)
            guard parent > 1 else { return nil }
            if parent == getpid() { return nil }
            if let app = NSRunningApplication(processIdentifier: parent), app.activationPolicy == .regular { return app }
            cur = parent
        }
        return nil
    }

    /// 从岛上停掉一个正在跑的 Agent
    func stop(_ r: AgentRun) {
        if Self.isDead(r.pid) { dropDead(); return }
        guard r.canStop, let i = runs.firstIndex(where: { $0.id == r.id }), !runs[i].stopping else { return }
        switch r.source {
        case .opencode:
            runs[i].stopping = true
            AgentBridge.requestStop(session: String(r.id.dropFirst(r.source.rawValue.count + 1)))
            // 15 秒还没停下来：恢复按钮，可以再点
            let id = r.id
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                if let self, let j = self.runs.firstIndex(where: { $0.id == id }), self.runs[j].stopping { self.runs[j].stopping = false }
            }
        default:
            break
        }
    }

    /// 结束；返回这一轮跑了多久
    @discardableResult
    func end(_ s: AgentSource, session: String) -> TimeInterval? {
        let id = Self.key(s, session)
        guard let r = runs.first(where: { $0.id == id }) else { return nil }
        runs.removeAll { $0.id == id }
        forget(id)
        return Date().timeIntervalSince(r.started)
    }

    func clear(_ s: AgentSource) {
        if runs.contains(where: { $0.source == s }) {
            runs.filter { $0.source == s }.forEach { forget($0.id) }
            runs.removeAll { $0.source == s }
        }
    }

    private func forget(_ id: String) {
        beats[id] = nil
        lastActivityAt[id] = nil
        pendingActivity[id] = nil
    }

    private func startSweeper() {
        guard sweeper == nil else { return }
        sweeper = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard let self else { return }
                self.dropDead()
                let waiting = Set(ApprovalCenter.shared.pending.map(\.source))
                let now = Date()
                // 正在等你批的不算「没动静」
                let stale = self.runs.filter { now.timeIntervalSince(self.beats[$0.id] ?? now) > self.staleAfter && !waiting.contains($0.source) }
                if !stale.isEmpty {
                    stale.forEach { self.forget($0.id) }
                    self.runs.removeAll { r in stale.contains { $0.id == r.id } }
                }
                if self.runs.isEmpty { self.sweeper = nil; return }
            }
        }
    }

    /// 工具调用的一句话描述
    static func label(tool: String, input: Any?) -> String {
        let name = tool.isEmpty ? "工具" : tool
        guard let d = input as? [String: Any] else { return name }
        if let cmd = d["command"] as? String {
            var c = AgentRiskAssess.stripCd(cmd).replacingOccurrences(of: "\n", with: " ")
            if c.count > 70 { c = String(c.prefix(70)) + "…" }
            return "\(name) · \(c)"
        }
        if let p = (d["file_path"] ?? d["filePath"] ?? d["path"] ?? d["target_file"] ?? d["notebook_path"]) as? String, !p.isEmpty {
            return "\(name) · \(URL(fileURLWithPath: p).lastPathComponent)"
        }
        return name
    }
}
