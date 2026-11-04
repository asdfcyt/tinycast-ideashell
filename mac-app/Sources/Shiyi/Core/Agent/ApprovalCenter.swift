import AppKit
import Carbon
import Foundation

/// 审批收件箱：各个 Agent 的请求都进这里排队，卡片上批了（或超时 / 对方取消）就把结果交回去。
@MainActor
final class ApprovalCenter: ObservableObject {
    static let shared = ApprovalCenter()

    @Published private(set) var pending: [Approval] = []
    @Published private(set) var completions: [AgentCompletion] = []
    @Published private(set) var history: [ApprovalRecord] = []
    /// 「以后同类都准」记下的规则键
    @Published private(set) var rules: [String] = []
    /// 「以后同类都拒」记下的规则键（Agent 再来就直接回绝，不用你再点一次）
    @Published private(set) var denyRules: [String] = []

    private struct Waiter {
        let cont: CheckedContinuation<ApprovalOutcome, Never>
        let conn: UUID?
    }

    private struct CompletionWaiter {
        let cont: CheckedContinuation<CompletionOutcome, Never>
        let conn: UUID?
    }

    /// 同一个请求可能被 Agent 连发好几次（重试 / 多个钩子），合并成一张卡，一次决定一起回
    private var waiters: [UUID: [Waiter]] = [:]
    private var completionWaiters: [UUID: CompletionWaiter] = [:]
    private var timers: [UUID: Task<Void, Never>] = [:]
    private var holdTimers: [UUID: Task<Void, Never>] = [:]
    private var pinned = Set<UUID>()
    /// 刚手动决定过的请求，短时间内重复来就沿用结果
    private var recent: [(key: String, outcome: ApprovalOutcome, at: Date)] = []
    private var started = false
    private var hotkeysOn = false
    private var saveTask: Task<Void, Never>?

    private static var historyFile: URL { LocalStore.dir.appendingPathComponent("agent-approvals.json") }

    func start() {
        guard !started else { return }
        started = true
        AgentPrefs.register()
        // 旧版没有来源前缀的规则都是 Cursor 的
        rules = (UserDefaults.standard.stringArray(forKey: AgentPrefs.rules) ?? []).map { $0.contains("|") ? $0 : "cursor|" + $0 }
        denyRules = UserDefaults.standard.stringArray(forKey: AgentPrefs.denyRules) ?? []
        if let d = try? Data(contentsOf: Self.historyFile) {
            let dec = JSONDecoder()
            dec.dateDecodingStrategy = .secondsSince1970
            history = (try? dec.decode([ApprovalRecord].self, from: d)) ?? []
        }
        GlobalHotkey.approveYes.onPress = { MainActor.assumeIsolated { ApprovalCenter.shared.decideFirst(allow: true) } }
        GlobalHotkey.approveNo.onPress = { MainActor.assumeIsolated { ApprovalCenter.shared.decideFirst(allow: false) } }
        DispatchCenter.registerDefaults()
    }

    // MARK: 提交

    private func sameKey(_ a: Approval) -> String { "\(a.source.rawValue)|\(a.kind.rawValue)|\(a.cwd)|\(a.detail)" }

    /// 提交一张审批请求，等决定。
    /// 只有「该你拍板」的才弹卡片：风险没到你设的门槛、只读命令、已记住放行的，都静默放行；已记住拒绝的直接回绝。
    func review(_ a: Approval, conn: UUID?) async -> ApprovalOutcome {
        let ud = UserDefaults.standard
        let scoped = scopedKey(a)

        // 你说过「以后都不行」的
        if let k = scoped, denyRules.contains(k) {
            log(a, result: "拒绝", by: "自动 · 已记住的拒绝", comment: nil)
            return .deny("你之前在拾忆里选了「以后同类都拒绝」。如确实需要，请让用户去拾忆「AI 调度台」里移除这条规则。")
        }
        // 已记住放行
        if a.risk != .high, let k = scoped, rules.contains(k) { return .autoAllow }
        // 风险没到门槛：不打扰（高风险永远要问）
        if !AgentPrefs.needsHuman(a.risk) { return .autoAllow }
        // 门槛设成「全部」时，纯只读命令仍可自动放行
        if a.kind == .shell, a.risk == .low, ud.bool(forKey: AgentPrefs.autoReadOnly), AgentRiskAssess.isReadOnly(a.detail) {
            return .autoAllow
        }

        let key = sameKey(a)
        recent.removeAll { Date().timeIntervalSince($0.at) > 15 }
        if let r = recent.first(where: { $0.key == key }) { return r.outcome }

        return await withCheckedContinuation { (cont: CheckedContinuation<ApprovalOutcome, Never>) in
            // 已有一张一模一样、还在等的：并进去，不再弹第二张
            if let ex = pending.first(where: { sameKey($0) == key }) {
                waiters[ex.id, default: []].append(Waiter(cont: cont, conn: conn))
                return
            }
            pending.append(a)
            waiters[a.id] = [Waiter(cont: cont, conn: conn)]
            let id = a.id
            let secs = a.timeout
            timers[id] = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(secs * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.resolve(id, .timeout, by: "超时")
            }
            if ud.bool(forKey: AgentPrefs.sound) { NSSound(named: "Funk")?.play() }
            pendingChanged()
        }
    }

    // MARK: 决定

    func allow(_ id: UUID) { resolve(id, .allow, by: "手动") }

    func deny(_ id: UUID, comment: String = "") {
        let c = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        resolve(id, .deny(c), by: "手动", comment: c.isEmpty ? nil : c)
    }

    /// 准，并且以后同类（同一来源的同一条命令 / 工具）都不用再问
    func allowAlways(_ id: UUID) {
        guard let a = pending.first(where: { $0.id == id }) else { return }
        if let k = scopedKey(a), a.risk != .high, !rules.contains(k) {
            rules.append(k)
            UserDefaults.standard.set(rules, forKey: AgentPrefs.rules)
        }
        resolve(id, .allow, by: "手动 · 并记住")
    }

    /// 拒，并且以后同类都直接回绝（「定了不做的事」不用每次再拒一遍）
    func denyAlways(_ id: UUID) {
        guard let a = pending.first(where: { $0.id == id }) else { return }
        if let k = scopedKey(a), !denyRules.contains(k) {
            denyRules.append(k)
            UserDefaults.standard.set(denyRules, forKey: AgentPrefs.denyRules)
        }
        resolve(id, .deny("用户拒绝了这个操作，并且以后同类操作都会被拒绝。请换一种不需要它的做法，或先问用户。"), by: "手动 · 并记住")
    }

    /// 规则按来源分开记：在 Cursor 里记住的，不会顺带放行 WorkBuddy 里的同名命令
    private func scopedKey(_ a: Approval) -> String? {
        a.ruleKey.map { "\(a.source.rawValue)|\($0)" }
    }

    func removeRule(_ key: String) {
        rules.removeAll { $0 == key }
        UserDefaults.standard.set(rules, forKey: AgentPrefs.rules)
    }

    func removeDenyRule(_ key: String) {
        denyRules.removeAll { $0 == key }
        UserDefaults.standard.set(denyRules, forKey: AgentPrefs.denyRules)
    }

    func decideFirst(allow: Bool) {
        guard let a = pending.first else { return }
        if allow { self.allow(a.id) } else { deny(a.id) }
    }

    /// 对方（钩子进程）断开了：Agent 被中止 / 钩子超时被杀，这张审批请求不用批了
    func dropConnection(_ conn: UUID) {
        for (id, ws) in waiters {
            guard ws.contains(where: { $0.conn == conn }) else { continue }
            let left = ws.filter { $0.conn != conn }
            if left.isEmpty { resolve(id, .cancelled, by: "已取消") } else { waiters[id] = left }
        }
        // 验收卡不跟着钩子一起消失：对方走了就标记「不再等」，卡片留着让你读完
        for (id, w) in completionWaiters where w.conn == conn { releaseCompletion(id, .cancelled) }
    }

    private func resolve(_ id: UUID, _ outcome: ApprovalOutcome, by: String, comment: String? = nil) {
        guard let idx = pending.firstIndex(where: { $0.id == id }) else { return }
        let a = pending.remove(at: idx)
        timers.removeValue(forKey: id)?.cancel()
        let ws = waiters.removeValue(forKey: id) ?? []
        let result: String
        switch outcome {
        case .allow, .autoAllow: result = "允许"
        case .deny: result = "拒绝"
        case .timeout: result = "超时"
        case .cancelled: result = "取消"
        }
        switch outcome {
        case .allow, .deny: recent.append((sameKey(a), outcome, Date()))
        default: break
        }
        log(a, result: result, by: by, comment: comment)
        pendingChanged()
        for w in ws { w.cont.resume(returning: outcome) }
    }

    // MARK: 完成卡片

    /// Agent 做完一轮：弹出验收卡。
    /// 卡片的生命周期和「对方等不等你」分开：对方最多等你 `wait` 秒（悬停 / 正在输入会顺延，上限 10 分钟），
    /// 之后它继续往下走，卡片仍留在岛上，直到你点「知道了」/ 在 Agent 里开始新一轮。
    func presentCompletion(_ c: AgentCompletion, conn: UUID?) async -> CompletionOutcome {
        // 同项目的旧卡片作废（新一轮已经结束了）
        for old in completions where old.source == c.source && old.cwd == c.cwd { finishCompletion(old.id, .dismissed) }
        var c = c
        c.deadline = Date().addingTimeInterval(c.canFollowUp ? c.wait : 0)
        c.detached = !c.canFollowUp && !c.viaDispatch
        completions.append(c)
        let id = c.id
        if AgentPrefs.defaults.bool(forKey: AgentPrefs.sound) { NSSound(named: "Glass")?.play() }
        pendingChanged()
        if AgentPrefs.defaults.bool(forKey: AgentPrefs.doneAI) { enrich(c) }
        // 兜底：放了很久没人理的卡片自己清掉
        timers[id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 30 * 60 * 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.finishCompletion(id, .dismissed)
        }
        guard c.canFollowUp else { return .dismissed }
        return await withCheckedContinuation { (cont: CheckedContinuation<CompletionOutcome, Never>) in
            guard completions.contains(where: { $0.id == id }) else { cont.resume(returning: .dismissed); return }
            completionWaiters[id] = CompletionWaiter(cont: cont, conn: conn)
            holdTimers[id] = Task { [weak self] in
                let started = Date()
                while !Task.isCancelled {
                    guard let self, let i = self.completions.firstIndex(where: { $0.id == id }) else { return }
                    let rem = self.completions[i].deadline.timeIntervalSinceNow
                    if rem > 0 { try? await Task.sleep(nanoseconds: UInt64(rem * 1_000_000_000) + 50_000_000); continue }
                    // 你还在看 / 正在打字：再等一轮
                    if self.pinned.contains(id), Date().timeIntervalSince(started) < 600 {
                        self.completions[i].deadline = Date().addingTimeInterval(max(c.wait, 15))
                        continue
                    }
                    self.releaseCompletion(id, .timeout)
                    return
                }
            }
        }
    }

    /// 卡片上鼠标悬停 / 输入框有字时调用：对方的等待时间顺延
    func pinCompletion(_ id: UUID, _ on: Bool) {
        if on { pinned.insert(id) } else { pinned.remove(id) }
        guard on, let i = completions.firstIndex(where: { $0.id == id }), !completions[i].detached else { return }
        let want = Date().addingTimeInterval(max(completions[i].wait, 15))
        if want > completions[i].deadline { completions[i].deadline = want }
    }

    /// 对方不再等了（超时 / 钩子断开）：放它继续，卡片保留
    private func releaseCompletion(_ id: UUID, _ outcome: CompletionOutcome) {
        holdTimers.removeValue(forKey: id)?.cancel()
        if let i = completions.firstIndex(where: { $0.id == id }) { completions[i].detached = true }
        completionWaiters.removeValue(forKey: id)?.cont.resume(returning: outcome)
    }

    /// 在 Agent 里开始了新一轮：这个项目的旧验收卡不用留了
    func dismissCompletions(source: AgentSource, cwd: String) {
        for c in completions where c.source == source && c.cwd == cwd { finishCompletion(c.id, .dismissed) }
    }

    func followUp(_ id: UUID, text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let c = completions.first(where: { $0.id == id }) else { return }
        if c.viaDispatch {
            // 对方一轮跑完就退出了：由拾忆接着这个会话再跑一轮
            finishCompletion(id, .dismissed)
            let sid = c.sessionId, dir = c.cwd
            Task {
                let r = await DispatchCenter.shared.continueOpenCode(sessionId: sid, dir: dir, text: t)
                if !r.ok { Notifier.post(id: "dispatch.fail", title: "继续 opencode 会话失败", body: r.message) }
            }
            return
        }
        if completionWaiters[id] != nil {
            // 对方还在等：直接把这句话作为下一条消息交回去
            finishCompletion(id, .followUp(t))
        } else {
            // 对方已经走了：复制到剪贴板、打开它；有辅助功能权限就顺手粘贴（不替你按回车）
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(t, forType: .string)
            openSource(c.source)
            // 没有桌面 App 可打开的 Agent（opencode 在终端里）只复制，不乱粘贴到别的 App 里
            if AXIsProcessTrusted(), NSWorkspace.shared.urlForApplication(withBundleIdentifier: c.source.bundleID) != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                    let src = CGEventSource(stateID: .combinedSessionState)
                    for down in [true, false] {
                        let ev = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: down) // V
                        ev?.flags = .maskCommand
                        ev?.post(tap: .cghidEventTap)
                    }
                }
            }
            finishCompletion(id, .dismissed)
        }
    }

    func dismissCompletion(_ id: UUID) { finishCompletion(id, .dismissed) }

    private func finishCompletion(_ id: UUID, _ outcome: CompletionOutcome) {
        guard let idx = completions.firstIndex(where: { $0.id == id }) else { return }
        completions.remove(at: idx)
        pinned.remove(id)
        timers.removeValue(forKey: id)?.cancel()
        holdTimers.removeValue(forKey: id)?.cancel()
        let w = completionWaiters.removeValue(forKey: id)
        pendingChanged()
        w?.cont.resume(returning: outcome)
    }

    /// 打开对应的 Agent 软件（想自己接着看 / 接着聊时）
    func openSource(_ s: AgentSource) {
        let ws = NSWorkspace.shared
        guard let url = ws.urlForApplication(withBundleIdentifier: s.bundleID) else { return }
        ws.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    /// 用配置好的大模型给这张卡写一句结论 + 几个最可能的后续指令（可选功能，默认关闭）
    private func enrich(_ c: AgentCompletion) {
        guard let model = AppModel.current, model.hasLlm, c.summary.count > 20 else { return }
        let id = c.id
        let system = """
        你是「AI 调度台」的助理。下面是一个编程 / 办公 Agent 刚结束一轮任务时的最后一条回复。
        请：1) 用一句话（不超过 40 字）概括它做成了什么、有什么需要用户注意或决定的；
        2) 给出最多 3 个用户此刻最可能发给 Agent 的后续指令，label 不超过 10 字，instruction 是可直接发给 Agent 的完整指令；
        如果 Agent 在向用户提问，第一个后续指令应当是对该问题的合理默认回答。
        只输出 JSON：{"conclusion":"","next":[{"label":"","instruction":""}]}
        """
        Task { [weak self] in
            guard let reply = try? await model.llm.chatJSON(system: system, user: String(c.summary.prefix(2400)), timeout: 25),
                  let obj = LlmClient.extractJSON(reply) else { return }
            let concl = (obj["conclusion"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let opts: [AgentCompletion.Option] = ((obj["next"] as? [[String: Any]]) ?? []).prefix(3).compactMap {
                guard let l = $0["label"] as? String, let i = $0["instruction"] as? String, !l.isEmpty, !i.isEmpty else { return nil }
                return AgentCompletion.Option(label: l, instruction: i)
            }
            guard let self, let idx = self.completions.firstIndex(where: { $0.id == id }) else { return }
            if let concl, !concl.isEmpty { self.completions[idx].conclusion = concl }
            if !opts.isEmpty { self.completions[idx].options = opts }
        }
    }

    // MARK: 展示位置

    private var total: Int { pending.count + completions.count }

    private func pendingChanged() {
        refreshSurface()
        if pending.isEmpty, hotkeysOn {
            hotkeysOn = false
            GlobalHotkey.approveYes.unregister()
            GlobalHotkey.approveNo.unregister()
        } else if !pending.isEmpty, !hotkeysOn {
            hotkeysOn = true
            let mods = UInt32(controlKey | optionKey)
            GlobalHotkey.approveYes.register(keyCode: 16, modifiers: mods) // Y
            GlobalHotkey.approveNo.register(keyCode: 45, modifiers: mods)  // N
        }
    }

    /// 灵动岛模式在岛里展示；菜单栏模式（或岛不可用）用右上角悬浮卡片
    func refreshSurface() {
        if IslandController.shared.syncAgents() {
            ApprovalPanelController.shared.sync(count: 0)
        } else {
            ApprovalPanelController.shared.sync(count: total)
        }
    }

    // MARK: 流水账

    private func log(_ a: Approval, result: String, by: String, comment: String?) {
        let r = ApprovalRecord(
            source: a.source, kind: a.kind, project: a.project, heading: a.heading,
            detail: String(a.detail.prefix(600)), result: result, by: by, comment: comment,
            seconds: Int(Date().timeIntervalSince(a.created))
        )
        history.insert(r, at: 0)
        if history.count > 300 { history.removeLast(history.count - 300) }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled, let self else { return }
            let enc = JSONEncoder()
            enc.dateEncodingStrategy = .secondsSince1970
            if let d = try? enc.encode(self.history) { try? d.write(to: Self.historyFile, options: .atomic) }
        }
    }

    func clearHistory() {
        history = []
        try? FileManager.default.removeItem(at: Self.historyFile)
    }

    // MARK: 钩子入口 / 演示

    /// 本机服务收到钩子请求：交给对应的适配器，返回要打给钩子进程 stdout 的 JSON
    func handleHook(agent: String, body: Data, conn: UUID) async -> Data {
        let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        let out: [String: Any]
        switch agent {
        case "cursor": out = await CursorAdapter.handle(obj, conn: conn)
        case "workbuddy": out = await WorkBuddyAdapter.handle(obj, conn: conn)
        case "opencode": out = await OpenCodeAdapter.handle(obj, conn: conn)
        default: out = [:]
        }
        return (try? JSONSerialization.data(withJSONObject: out)) ?? Data("{}".utf8)
    }

    /// 设置页的「发一张测试审批请求」
    func demo() {
        let cmd = "cd ~/project && rm -rf node_modules && npm install"
        let (risk, why) = AgentRiskAssess.assess(command: cmd)
        let a = Approval(
            source: .cursor, kind: .shell, project: "演示项目", cwd: "~/project", detail: cmd,
            heading: "演示", risk: risk, reasons: why, ruleKey: nil,
            timeout: TimeInterval(AgentPrefs.timeoutSeconds)
        )
        Task { _ = await review(a, conn: nil) }
        let text = "已把登录模块拆成三个文件，并补了类型。npm run build 通过。\n\n需要我顺便补上单元测试吗？"
        let c = AgentCompletion(
            source: .cursor, project: "演示项目", cwd: "~/project", failed: false, summary: text, asksQuestion: true,
            canFollowUp: true, wait: 60, conclusion: nil, options: AgentTranscript.defaultOptions(failed: false, asks: true)
        )
        Task { _ = await presentCompletion(c, conn: nil) }
    }
}
