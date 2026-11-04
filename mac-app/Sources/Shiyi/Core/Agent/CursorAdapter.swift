import Foundation

/// Cursor 钩子 → 审批请求。输入是 Cursor 通过 stdin 给钩子的 JSON，返回要打到钩子 stdout 的 JSON。
/// 拦截点：`beforeShellExecution`（命令）、`beforeMCPExecution`（MCP）、`preToolUse` + matcher Delete（删文件）；
/// `stop`（Agent 做完了）只发通知，不阻塞。
@MainActor
enum CursorAdapter {
    private static let permissionEvents: Set<String> = ["beforeShellExecution", "beforeMCPExecution", "preToolUse"]

    static func handle(_ j: [String: Any], conn: UUID) async -> [String: Any] {
        let event = j["hook_event_name"] as? String ?? ""
        let allow: [String: Any] = ["permission": "allow"]
        let neutral: [String: Any] = permissionEvents.contains(event) ? allow : [:]
        let ud = UserDefaults.standard
        guard AgentPrefs.isOn(.cursor) else { return neutral }

        let roots = j["workspace_roots"] as? [String] ?? []
        let cwd = (j["cwd"] as? String) ?? roots.first ?? ""
        let projectPath = roots.first ?? cwd
        let project = AgentProject.name(projectPath)
        let timeout = TimeInterval(AgentPrefs.timeoutSeconds)
        let session = (j["conversation_id"] as? String) ?? projectPath
        let runs = AgentRunTracker.shared
        if permissionEvents.contains(event) {
            var input: Any? = j["tool_input"]
            if input == nil, let c = j["command"] as? String { input = ["command": c] }
            runs.beat(.cursor, session: session, project: project, activity: AgentRunTracker.label(tool: Self.toolName(j, event), input: input))
        }

        let a: Approval
        switch event {
        case "beforeSubmitPrompt":
            runs.beat(.cursor, session: session, project: project, restart: true)
            ApprovalCenter.shared.dismissCompletions(source: .cursor, cwd: cwd)
            return ["continue": true]

        case "postToolUse":
            runs.beat(.cursor, session: session, project: project, activity: AgentRunTracker.label(tool: j["tool_name"] as? String ?? "", input: j["tool_input"]))
            return [:]

        case "stop":
            let took = runs.end(.cursor, session: session)
            guard ud.bool(forKey: AgentPrefs.cursorDone) else { return [:] }
            let status = j["status"] as? String ?? "completed"
            guard status != "aborted" else { return [:] }
            let summary = AgentTranscript.lastAssistantText(path: j["transcript_path"] as? String)
            let out = await ApprovalCenter.shared.presentCompletion(
                Self.completion(source: .cursor, project: project, cwd: cwd, failed: status == "error", summary: summary, duration: took),
                conn: conn
            )
            // Cursor：stop 钩子返回 followup_message 就会自动接着发这条消息（loop_limit 之内）
            if case let .followUp(text) = out {
                runs.beat(.cursor, session: session, project: project, restart: true)
                return ["followup_message": text]
            }
            return [:]

        case "beforeShellExecution":
            guard ud.bool(forKey: AgentPrefs.cursorShell) else { return neutral }
            let cmd = (j["command"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cmd.isEmpty else { return neutral }
            let (risk, why) = AgentRiskAssess.assess(command: cmd)
            a = Approval(source: .cursor, kind: .shell, project: project, cwd: cwd, detail: cmd, heading: cmd,
                         risk: risk, reasons: why, ruleKey: AgentRiskAssess.ruleKey(command: cmd), timeout: timeout)

        case "beforeMCPExecution":
            guard ud.bool(forKey: AgentPrefs.cursorMcp) else { return neutral }
            let tool = j["tool_name"] as? String ?? "?"
            let server = j["mcp_server_name"] as? String ?? "MCP"
            let input = (j["tool_input"] as? String) ?? Self.jsonText(j["tool_input"]) ?? ""
            let (risk, why) = AgentRiskAssess.assess(tool: tool)
            a = Approval(source: .cursor, kind: .mcp, project: project, cwd: cwd, detail: Self.pretty(input),
                         heading: "\(server) · \(tool)", risk: risk, reasons: why, ruleKey: "mcp:\(server)/\(tool)", timeout: timeout)

        case "preToolUse":
            guard (j["tool_name"] as? String) == "Delete", ud.bool(forKey: AgentPrefs.cursorDelete) else { return neutral }
            let input = j["tool_input"] as? [String: Any] ?? [:]
            let path = (input["path"] ?? input["file_path"] ?? input["target_file"]) as? String ?? Self.jsonText(input) ?? "?"
            a = Approval(source: .cursor, kind: .delete, project: project, cwd: cwd, detail: path, heading: path,
                         risk: .medium, reasons: ["删除后不可恢复"], ruleKey: nil, timeout: timeout)

        default:
            return neutral
        }

        switch await ApprovalCenter.shared.review(a, conn: conn) {
        case .allow, .autoAllow:
            return allow
        case let .deny(why):
            return [
                "permission": "deny",
                "user_message": why.isEmpty ? "已在拾忆中拒绝" : "已在拾忆中拒绝：\(why)",
                "agent_message": "用户在拾忆中拒绝了这次操作。" + (why.isEmpty ? "请换一种方式，或先向用户确认。" : "理由：\(why)"),
            ]
        case .timeout:
            if AgentPrefs.fallbackDeny {
                return [
                    "permission": "deny",
                    "user_message": "拾忆里 \(AgentPrefs.timeoutSeconds) 秒内没有处理，已拒绝",
                    "agent_message": "用户没有及时处理这次操作（超时），已拒绝。请先向用户确认再重试。",
                ]
            }
            // preToolUse 目前不支持 ask：只能放行（Cursor 自己的权限流程仍然生效）
            if event == "preToolUse" { return allow }
            return ["permission": "ask", "user_message": "拾忆里没有及时处理，交还给你在 Cursor 里确认"]
        case .cancelled:
            return neutral
        }
    }

    private static func toolName(_ j: [String: Any], _ event: String) -> String {
        switch event {
        case "beforeShellExecution": return "Shell"
        case "beforeMCPExecution": return (j["tool_name"] as? String) ?? "MCP"
        default: return (j["tool_name"] as? String) ?? ""
        }
    }

    /// 完成卡片（Cursor / WorkBuddy 共用）
    static func completion(source: AgentSource, project: String, cwd: String, failed: Bool, summary: String, duration: TimeInterval? = nil) -> AgentCompletion {
        let wait = AgentPrefs.completionWaitSeconds
        // 回执（```shiyi 代码块）：先取出来，正文里不再显示这段 JSON
        let parsed = ReceiptParser.extract(summary)
        var text = AgentTranscript.tidy(parsed.text)
        let receipt = parsed.receipt
        if let notices = receipt?.notices, !notices.isEmpty {
            let lines = notices.map { n in "- " + (n.title.isEmpty ? n.text : (n.text.isEmpty ? "**\(n.title)**" : "**\(n.title)**：\(n.text)")) }
            text += (text.isEmpty ? "" : "\n\n") + lines.joined(separator: "\n")
        }
        let receiptOptions = Self.options(from: receipt?.asks ?? [])
        let asks = !receiptOptions.isEmpty || !(receipt?.asks.isEmpty ?? true) || AgentTranscript.asksQuestion(text)
        var c = AgentCompletion(
            source: source, project: project, cwd: cwd, failed: failed, summary: text, asksQuestion: asks,
            canFollowUp: wait > 0, wait: TimeInterval(wait), conclusion: nil,
            options: receiptOptions.isEmpty ? AgentTranscript.defaultOptions(failed: failed, asks: asks) : receiptOptions, duration: duration
        )
        c.optionsFromReceipt = !receiptOptions.isEmpty
        c.laters = receipt?.laters ?? []
        c.receiptMalformed = parsed.malformed
        return c
    }

    /// 回执里的提问 → 验收卡上的选项按钮（点选项 = 把「关于「问题」：选项」发回给 Agent）
    private static func options(from asks: [AgentReceipt.Ask]) -> [AgentCompletion.Option] {
        var out: [AgentCompletion.Option] = []
        for a in asks {
            for (i, o) in a.options.enumerated() {
                let label = asks.count > 1 && !a.title.isEmpty ? "\(a.title) · \(o)" : o
                let instruction = a.title.isEmpty ? o : "关于「\(a.title)」：\(o)"
                out.append(.init(label: label, instruction: instruction, recommended: a.recommend == i))
            }
        }
        return Array(out.prefix(6))
    }

    private static func jsonText(_ any: Any?) -> String? {
        guard let any, JSONSerialization.isValidJSONObject(any),
              let d = try? JSONSerialization.data(withJSONObject: any, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return nil }
        return String(data: d, encoding: .utf8)
    }

    /// MCP 参数是 JSON 字符串：能解析就排好版再显示
    private static func pretty(_ s: String) -> String {
        guard let d = s.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) else { return s }
        return jsonText(o) ?? s
    }
}
