import Foundation

/// opencode 插件 → 审批请求。插件（`~/.config/opencode/plugins/shiyi.js`）把 opencode 的事件转成：
/// - `busy`：一轮开始（运行状态）；`pre` / `post`：工具调用前 / 后；`idle`：一轮结束（验收卡）；
/// - `permission`：opencode 自己的权限询问（`permission.asked`）。
/// 回复 `{decision: allow | deny | neutral, reason?, followup?}`：allow = 你批了；neutral = 交还 opencode 自己处理；
/// deny = 插件会让这次工具调用失败并把理由告诉模型；followup = 验收卡里追加的指令，插件会发给同一个会话。
/// 结审的 opencode 服务（默认 4196 端口）是「只观察」：只会收到 `busy` / `post` / `idle`（`observe = true`），
/// 验收卡只展示、不能追加指令；不会有 `pre` / `permission`，结审自己的 Agent 流程不受影响。
@MainActor
enum OpenCodeAdapter {
    private static let neutral: [String: Any] = ["decision": "neutral"]

    /// opencode 自带的工具；其余的（带下划线的）当作 MCP / 自定义工具
    private static let builtin: Set<String> = [
        "bash", "read", "edit", "write", "patch", "multiedit", "apply_patch", "glob", "grep", "list", "ls",
        "webfetch", "websearch", "codesearch", "task", "todowrite", "todoread", "skill", "question", "lsp", "batch",
    ]
    private static let editTools: Set<String> = ["edit", "write", "patch", "multiedit", "apply_patch"]

    static func handle(_ j: [String: Any], conn: UUID) async -> [String: Any] {
        guard AgentPrefs.isOn(.opencode) else { return neutral }
        let ud = UserDefaults.standard
        let event = j["event"] as? String ?? ""
        let session = j["session_id"] as? String ?? ""
        let cwd = j["cwd"] as? String ?? ""
        let observe = j["observe"] as? Bool ?? false
        var project = AgentProject.name(cwd)
        // 结审的会话标题是「团队/Agent」：带上，区分是哪个 Agent 在跑
        if observe, let t = j["title"] as? String, !t.isEmpty, !t.hasPrefix("New session"), !t.hasPrefix("Child session") { project += " · " + t }
        let runs = AgentRunTracker.shared
        // 新版插件（v3）才能响应「停止」；结审那种只观察的不让停
        let canStop = !observe && (j["v"] as? Int ?? 0) >= 3
        let pid = (j["pid"] as? Int).map { Int32($0) }
        let timeout = TimeInterval(AgentPrefs.timeoutSeconds)

        switch event {
        case "busy":
            runs.beat(.opencode, session: session, project: project, restart: true, canStop: canStop, pid: pid)
            // 结审里好几个 Agent 同时在跑：别人开始新一轮不要把你还没看的卡片收掉
            if !observe { ApprovalCenter.shared.dismissCompletions(source: .opencode, cwd: cwd) }
            return neutral

        case "post":
            runs.beat(.opencode, session: session, project: project, activity: label(j), canStop: canStop, pid: pid)
            return neutral

        case "idle":
            let took = runs.end(.opencode, session: session)
            // 你在岛上点了停止：不弹验收卡
            if j["aborted"] as? Bool == true { return neutral }
            guard ud.bool(forKey: AgentPrefs.opencodeDone) else { return neutral }
            if observe, !ud.bool(forKey: AgentPrefs.opencodeObserveCards) { return neutral }
            let failed = j["failed"] as? Bool ?? false
            let summary = j["last_assistant_message"] as? String ?? ""
            var card = CursorAdapter.completion(source: .opencode, project: project, cwd: cwd, failed: failed, summary: summary, duration: took)
            if observe { card.canFollowUp = false }
            // 从拾忆派出去的任务（opencode run 一轮结束进程就退出了，没法在钩子里等你回话）：
            // 追加指令改成「接着这个会话再跑一轮」
            if j["dispatch"] as? Bool == true {
                card.canFollowUp = false
                card.viaDispatch = true
                card.sessionId = session
            }
            let out = await ApprovalCenter.shared.presentCompletion(card, conn: conn)
            if case let .followUp(text) = out {
                runs.beat(.opencode, session: session, project: project, restart: true, canStop: canStop, pid: pid)
                return ["decision": "neutral", "followup": text]
            }
            return neutral

        case "pre":
            guard !observe else { return neutral }
            runs.beat(.opencode, session: session, project: project, activity: label(j), canStop: canStop, pid: pid)
            let tool = (j["tool"] as? String ?? "").lowercased()
            let args = j["args"] as? [String: Any] ?? [:]
            let a: Approval
            if tool == "bash" {
                guard ud.bool(forKey: AgentPrefs.opencodeShell) else { return neutral }
                let cmd = (args["command"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cmd.isEmpty else { return neutral }
                let (risk, why) = AgentRiskAssess.assess(command: cmd)
                a = Approval(source: .opencode, kind: .shell, project: project, cwd: cwd, detail: cmd, heading: cmd,
                             risk: risk, reasons: why, ruleKey: AgentRiskAssess.ruleKey(command: cmd), timeout: timeout)
            } else if editTools.contains(tool) {
                guard ud.bool(forKey: AgentPrefs.opencodeEdit) else { return neutral }
                let path = (args["filePath"] ?? args["file_path"] ?? args["path"]) as? String ?? "?"
                a = Approval(source: .opencode, kind: .edit, project: project, cwd: cwd, detail: path, heading: "\(tool) \(path)",
                             risk: .low, reasons: [], ruleKey: nil, timeout: timeout)
            } else if !builtin.contains(tool), tool.contains("_") {
                guard ud.bool(forKey: AgentPrefs.opencodeMcp) else { return neutral }
                let parts = tool.split(separator: "_", maxSplits: 1).map(String.init)
                let server = parts.count == 2 ? parts[0] : "MCP"
                let name = parts.count == 2 ? parts[1] : tool
                let (risk, why) = AgentRiskAssess.assess(tool: name)
                a = Approval(source: .opencode, kind: .mcp, project: project, cwd: cwd, detail: Self.jsonText(args) ?? "",
                             heading: "\(server) · \(name)", risk: risk, reasons: why, ruleKey: "mcp:\(server)/\(name)", timeout: timeout)
            } else {
                return neutral
            }
            return await decide(a, conn: conn)

        case "permission":
            guard !observe else { return neutral }
            // opencode 自己在问：和上面同样的口径，由你的审批策略决定要不要打扰你
            let permission = (j["permission"] as? String ?? "").lowercased()
            let patterns = (j["patterns"] as? [String]) ?? []
            let joined = patterns.joined(separator: "\n")
            let a: Approval
            if permission == "bash" {
                guard ud.bool(forKey: AgentPrefs.opencodeShell), !patterns.isEmpty else { return neutral }
                let (risk, why) = AgentRiskAssess.assess(command: patterns.joined(separator: " ; "))
                a = Approval(source: .opencode, kind: .shell, project: project, cwd: cwd, detail: joined, heading: patterns[0],
                             risk: risk, reasons: why, ruleKey: AgentRiskAssess.ruleKey(command: patterns[0]), timeout: timeout)
            } else if editTools.contains(permission) {
                guard ud.bool(forKey: AgentPrefs.opencodeEdit) else { return neutral }
                a = Approval(source: .opencode, kind: .edit, project: project, cwd: cwd, detail: joined, heading: "\(permission) \(patterns.first ?? "")",
                             risk: .low, reasons: [], ruleKey: nil, timeout: timeout)
            } else {
                // 读目录外的文件、联网、子任务等其他权限：跟 MCP 开关走，是否弹卡仍由审批策略决定
                guard ud.bool(forKey: AgentPrefs.opencodeMcp) else { return neutral }
                a = Approval(source: .opencode, kind: .mcp, project: project, cwd: cwd, detail: joined,
                             heading: "\(permission) · \(patterns.first ?? "")", risk: .medium, reasons: ["opencode 在请求权限：\(permission)"],
                             ruleKey: nil, timeout: timeout)
            }
            return await decide(a, conn: conn)

        default:
            return neutral
        }
    }

    private static func decide(_ a: Approval, conn: UUID) async -> [String: Any] {
        switch await ApprovalCenter.shared.review(a, conn: conn) {
        case .allow:
            return ["decision": "allow"]
        case .autoAllow, .cancelled:
            return neutral
        case let .deny(why):
            return ["decision": "deny", "reason": "用户在拾忆中拒绝了这次操作。" + (why.isEmpty ? "请换一种方式，或先向用户确认。" : "理由：\(why)")]
        case .timeout:
            if AgentPrefs.fallbackDeny {
                return ["decision": "deny", "reason": "用户没有及时处理这次操作（\(AgentPrefs.timeoutSeconds) 秒超时），已拒绝。请先向用户确认再重试。"]
            }
            return neutral
        }
    }

    private static func label(_ j: [String: Any]) -> String {
        let tool = j["tool"] as? String ?? ""
        return AgentRunTracker.label(tool: tool.prefix(1).uppercased() + tool.dropFirst(), input: j["args"])
    }

    private static func jsonText(_ any: Any?) -> String? {
        guard let any, JSONSerialization.isValidJSONObject(any),
              let d = try? JSONSerialization.data(withJSONObject: any, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return nil }
        return String(data: d, encoding: .utf8)
    }
}
