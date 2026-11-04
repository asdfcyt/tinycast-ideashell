// 拾忆的 Agent 钩子：Cursor / WorkBuddy 在要执行命令 / 调 MCP 前启动它。
// 用法：shiyi-hook cursor | workbuddy   （stdin 读钩子 JSON，stdout 回决定 JSON）
//
// 流程：读 stdin → 读拾忆的桥接文件（端口 / 令牌 / 超时 / 回退策略）→ POST 给拾忆，阻塞等你批 → 把拾忆的回答原样打到 stdout。
// 拾忆没开 / 连不上：立刻按回退策略回答（默认「交还给工具自己询问」），不会让 Agent 卡死。
import Foundation

setvbuf(stdout, nil, _IOFBF, 0)

let args = CommandLine.arguments
let agent = args.count > 1 ? args[1] : "cursor"
let input = FileHandle.standardInput.readDataToEndOfFile()
let payload = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any] ?? [:]
let event = payload["hook_event_name"] as? String ?? ""

func emit(_ obj: [String: Any]) -> Never {
    let d = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
    FileHandle.standardOutput.write(d)
    exit(0)
}

struct Bridge {
    var port: Int
    var token: String
    var timeout: Int
    var fallback: String
}

func loadBridge() -> Bridge? {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    let url = base.appendingPathComponent("Shiyi/agent-bridge.json")
    guard let d = try? Data(contentsOf: url),
          let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
          let port = j["port"] as? Int, let token = j["token"] as? String else { return nil }
    return Bridge(port: port, token: token, timeout: j["timeout"] as? Int ?? 90, fallback: j["fallback"] as? String ?? "ask")
}

/// 拾忆不在 / 超时：按回退策略回答
func fallback(_ b: Bridge?, why: String) -> Never {
    let deny = b?.fallback == "deny"
    if agent == "workbuddy" {
        // WorkBuddy（Claude Code 规范）：只有 PreToolUse 需要回答；其余事件直接继续
        guard event == "PreToolUse" else { emit(["continue": true]) }
        let d = deny ? "deny" : "ask"
        let reason = deny ? "拾忆没有响应（\(why)），这次操作已被拒绝。请先向用户确认再重试。" : "\(why)，交还给你在 WorkBuddy 里确认"
        emit(["hookSpecificOutput": ["hookEventName": "PreToolUse", "permissionDecision": d, "permissionDecisionReason": reason]])
    }
    let permissionEvents: Set<String> = ["beforeShellExecution", "beforeMCPExecution", "preToolUse"]
    guard permissionEvents.contains(event) else { emit([:]) }
    if deny {
        emit(["permission": "deny",
              "user_message": "\(why)，已拒绝",
              "agent_message": "拾忆没有响应（\(why)），这次操作已被拒绝。请先向用户确认再重试。"])
    }
    // preToolUse 目前不支持 ask：只能放行（Cursor 自己的权限流程仍然生效）
    if event == "preToolUse" { emit(["permission": "allow"]) }
    emit(["permission": "ask", "user_message": "\(why)，交还给你在 Cursor 里确认"])
}

guard let bridge = loadBridge(), let url = URL(string: "http://127.0.0.1:\(bridge.port)/v1/hook/\(agent)") else {
    fallback(nil, why: "拾忆还没有启动过")
}

var req = URLRequest(url: url)
req.httpMethod = "POST"
req.httpBody = input
req.setValue(bridge.token, forHTTPHeaderField: "X-Shiyi-Token")
req.setValue("application/json", forHTTPHeaderField: "Content-Type")
req.timeoutInterval = Double(bridge.timeout) + 15

let cfg = URLSessionConfiguration.ephemeral
cfg.timeoutIntervalForRequest = Double(bridge.timeout) + 15
cfg.timeoutIntervalForResource = Double(bridge.timeout) + 20
cfg.connectionProxyDictionary = [:]
let session = URLSession(configuration: cfg)
let sem = DispatchSemaphore(value: 0)
session.dataTask(with: req) { data, resp, err in
    defer { sem.signal() }
    guard err == nil, let http = resp as? HTTPURLResponse, http.statusCode == 200, let data, !data.isEmpty else {
        fallback(bridge, why: "拾忆没有开")
    }
    FileHandle.standardOutput.write(data)
    exit(0)
}.resume()
sem.wait()
exit(0)
