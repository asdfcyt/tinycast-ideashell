import Foundation

/// WorkBuddy 钩子 → 审批请求。WorkBuddy 的钩子和 Claude Code 规范一致（配置在 `~/.workbuddy/settings.json` 的 `hooks` 里）：
/// - `PreToolUse`：`tool_name` 是 `Bash` / `Write` / `Edit` / `MultiEdit` / `mcp__服务__工具`，`tool_input` 是对象；
///   回 `hookSpecificOutput.permissionDecision` = allow / deny / ask。`ask` 在 WorkBuddy 里连「全部放行」模式下也会强制弹窗。
/// - `Stop`：一轮结束，只发通知。
/// 注意：对不管的工具只能回 `{"continue": true}`，不能回 allow（allow 会让 WorkBuddy 跳过它自己的整套权限检查）。
@MainActor
enum WorkBuddyAdapter {
    private static let neutral: [String: Any] = ["continue": true]

    private static func decision(_ d: String, _ reason: String) -> [String: Any] {
        ["hookSpecificOutput": ["hookEventName": "PreToolUse", "permissionDecision": d, "permissionDecisionReason": reason]]
    }

    static func handle(_ j: [String: Any], conn: UUID) async -> [String: Any] {
        guard AgentPrefs.isOn(.workbuddy) else { return neutral }
        let ud = UserDefaults.standard
        let event = j["hook_event_name"] as? String ?? ""
        let cwd = j["cwd"] as? String ?? ""
        let project = AgentProject.name(cwd)
        let timeout = TimeInterval(AgentPrefs.timeoutSeconds)
        let session = (j["session_id"] as? String) ?? cwd
        let runs = AgentRunTracker.shared

        switch event {
        case "UserPromptSubmit":
            runs.beat(.workbuddy, session: session, project: project, restart: true)
            ApprovalCenter.shared.dismissCompletions(source: .workbuddy, cwd: cwd)
            return neutral
        case "PostToolUse":
            runs.beat(.workbuddy, session: session, project: project, activity: AgentRunTracker.label(tool: j["tool_name"] as? String ?? "", input: j["tool_input"]))
            return neutral
        case "PreToolUse":
            runs.beat(.workbuddy, session: session, project: project, activity: AgentRunTracker.label(tool: j["tool_name"] as? String ?? "", input: j["tool_input"]))
        default: break
        }

        if event == "Stop" {
            let took = runs.end(.workbuddy, session: session)
            guard ud.bool(forKey: AgentPrefs.workbuddyDone) else { return neutral }
            let summary = (j["last_assistant_message"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? AgentTranscript.lastAssistantText(path: j["transcript_path"] as? String)
            let out = await ApprovalCenter.shared.presentCompletion(
                CursorAdapter.completion(source: .workbuddy, project: project, cwd: cwd, failed: false, summary: summary, duration: took),
                conn: conn
            )
            // WorkBuddy：Stop 钩子回 decision=block + reason，会把 reason 当作新消息继续这轮对话
            if case let .followUp(text) = out {
                runs.beat(.workbuddy, session: session, project: project, restart: true)
                return ["decision": "block", "reason": text]
            }
            return neutral
        }
        guard event == "PreToolUse" else { return neutral }

        let tool = j["tool_name"] as? String ?? ""
        let input = j["tool_input"] as? [String: Any] ?? [:]
        let a: Approval

        if tool == "Bash" {
            guard ud.bool(forKey: AgentPrefs.workbuddyShell) else { return neutral }
            let cmd = (input["command"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cmd.isEmpty else { return neutral }
            let (risk, why) = AgentRiskAssess.assess(command: cmd)
            a = Approval(source: .workbuddy, kind: .shell, project: project, cwd: cwd, detail: cmd, heading: cmd,
                         risk: risk, reasons: why, ruleKey: AgentRiskAssess.ruleKey(command: cmd), timeout: timeout)
        } else if tool.hasPrefix("mcp__") {
            guard ud.bool(forKey: AgentPrefs.workbuddyMcp) else { return neutral }
            // mcp__服务名__工具名（服务名里也可能有单下划线）
            let parts = tool.dropFirst(5).components(separatedBy: "__")
            let server = parts.count >= 2 ? parts[0] : "MCP"
            let name = parts.count >= 2 ? parts.dropFirst().joined(separator: "__") : String(tool.dropFirst(5))
            let (risk, why) = AgentRiskAssess.assess(tool: name)
            a = Approval(source: .workbuddy, kind: .mcp, project: project, cwd: cwd, detail: Self.jsonText(input) ?? "",
                         heading: "\(server) · \(name)", risk: risk, reasons: why, ruleKey: "mcp:\(server)/\(name)", timeout: timeout)
        } else if ["Write", "Edit", "MultiEdit", "NotebookEdit"].contains(tool) {
            guard ud.bool(forKey: AgentPrefs.workbuddyEdit) else { return neutral }
            let path = (input["file_path"] ?? input["path"] ?? input["notebook_path"]) as? String ?? Self.jsonText(input) ?? "?"
            a = Approval(source: .workbuddy, kind: .edit, project: project, cwd: cwd, detail: path, heading: "\(tool) \(path)",
                         risk: .low, reasons: [], ruleKey: nil, timeout: timeout)
        } else {
            return neutral
        }

        switch await ApprovalCenter.shared.review(a, conn: conn) {
        case .allow:
            return decision("allow", "已在拾忆中允许")
        case .autoAllow, .cancelled:
            return neutral
        case let .deny(why):
            return decision("deny", "用户在拾忆中拒绝了这次操作。" + (why.isEmpty ? "请换一种方式，或先向用户确认。" : "理由：\(why)"))
        case .timeout:
            if AgentPrefs.fallbackDeny {
                return decision("deny", "用户没有及时处理这次操作（\(AgentPrefs.timeoutSeconds) 秒超时），已拒绝。请先向用户确认再重试。")
            }
            return decision("ask", "拾忆里没有及时处理，交还给你在 WorkBuddy 里确认")
        }
    }

    private static func jsonText(_ any: Any?) -> String? {
        guard let any, JSONSerialization.isValidJSONObject(any),
              let d = try? JSONSerialization.data(withJSONObject: any, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return nil }
        return String(data: d, encoding: .utf8)
    }
}
