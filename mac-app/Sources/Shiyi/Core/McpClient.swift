import Foundation

enum McpEndpoints {
    static let ideashell = "https://api.ideashell.cn/ideashell/mcp"
    static let dida = "https://mcp.dida365.com"
}

enum McpError: LocalizedError {
    case noCredential
    case auth(Int?)
    case http(Int, String)
    case rpc(Int, String)
    case tool(String)
    case proto(String)
    case sessionExpired

    var errorDescription: String? {
        switch self {
        case .noCredential: return "还没有填写凭证"
        case .auth: return "凭证无效或已失效，请重新填写"
        case let .http(code, body): return "HTTP \(code)" + (body.isEmpty ? "" : "：\(body)")
        case let .rpc(code, msg): return "MCP 错误 \(code)：\(msg)"
        case let .tool(msg): return msg
        case let .proto(msg): return msg
        case .sessionExpired: return "MCP 会话已过期"
        }
    }
}

/// 通用 MCP（Streamable HTTP）客户端，闪念贝壳与滴答清单共用；协议细节与安卓端 `McpClient.kt` 一致：
/// 每次 POST JSON-RPC，响应可能是 JSON 或 SSE；握手 initialize → 记录 `Mcp-Session-Id` → notifications/initialized；
/// 会话过期（404）自动重建一次。
actor McpClient {
    private static let protocolVersion = "2025-03-26"

    private let endpoint: URL
    private let tokenProvider: @Sendable () -> String?
    private let urlSession: URLSession

    private var sessionId: String?
    private var initialized = false
    private var initTask: Task<Void, Error>?
    private var idGen = 0

    init(endpoint: String, tokenProvider: @escaping @Sendable () -> String?) {
        self.endpoint = URL(string: endpoint)!
        self.tokenProvider = tokenProvider
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 40
        cfg.waitsForConnectivity = false
        urlSession = URLSession(configuration: cfg)
    }

    /// 凭证变更后调用：下次请求重新握手
    func reset() {
        sessionId = nil
        initialized = false
        initTask = nil
        toolList = nil
    }

    /// `tools/list` 的结果（每个会话只读一次）：只用来按名字 / schema 找「关键词搜索」类工具
    private var toolList: [JSON]?

    /// 在服务端的工具清单里找一个按关键词搜索的工具并调用，返回文本；服务端没有这类工具返回 nil。
    /// 工具名按 `nameHints` 优先，其次任何名字里同时有 search 和 `mustContain` 的；参数名从 inputSchema 里找（keywords / query / 嵌套对象里的都行）。
    func callKeywordSearch(_ query: String, nameHints: [String], mustContain: String) async throws -> String? {
        if toolList == nil {
            let r = try await request("tools/list", [:])
            toolList = (r["tools"] as? [Any])?.compactMap { $0 as? JSON } ?? []
        }
        let tools = toolList ?? []
        func name(_ t: JSON) -> String { (t["name"] as? String) ?? "" }
        let tool = nameHints.compactMap { h in tools.first { name($0) == h } }.first
            ?? tools.first { let n = name($0).lowercased(); return n.contains("search") && n.contains(mustContain) }
        guard let tool, let schema = tool["inputSchema"] as? JSON, var args = Self.keywordArgs(schema, query) else { return nil }
        if let props = schema["properties"] as? JSON, props["client_timezone"] != nil { args["client_timezone"] = TimeZone.current.identifier }
        return try await callText(name(tool), args)
    }

    /// 按 schema 生成「把关键词填进去」的参数：先找 keywords / query 之类的字符串（或字符串数组）参数，再往嵌套对象里找，最后退到唯一必填的字符串参数
    private static func keywordArgs(_ schema: JSON, _ q: String) -> JSON? {
        guard let props = schema["properties"] as? JSON else { return nil }
        func kind(_ p: JSON) -> String? {
            guard let t = p["type"] as? String else { return nil }
            if t == "array" {
                let itemType = (p["items"] as? JSON)?["type"] as? String
                return itemType == "string" ? "strings" : nil
            }
            return t
        }
        for k in ["keywords", "keyword", "query", "search", "searchText", "search_text", "text", "q", "content", "title"] {
            guard let p = props[k] as? JSON else { continue }
            switch kind(p) {
            case "string": return [k: q]
            case "strings": return [k: [q]]
            default: break
            }
        }
        for (k, v) in props {
            if let p = v as? JSON, kind(p) == "object", let inner = keywordArgs(p, q) { return [k: inner] }
        }
        let required = (schema["required"] as? [Any])?.compactMap { $0 as? String } ?? []
        if required.count == 1, let p = props[required[0]] as? JSON, kind(p) == "string" { return [required[0]: q] }
        return nil
    }

    func callText(_ name: String, _ arguments: JSON = [:]) async throws -> String {
        let result = try await request("tools/call", ["name": name, "arguments": arguments])
        let content = (result["content"] as? [Any]) ?? []
        let text = content.compactMap { $0 as? JSON }
            .filter { ($0["type"] as? String) == "text" }
            .compactMap { $0["text"] as? String }
            .joined(separator: "\n")
        if (result["isError"] as? Bool) == true {
            throw McpError.tool(text.isEmpty ? "\(name) 调用失败" : text)
        }
        return text
    }

    // MARK: - 内部

    private func ensureInitialized() async throws {
        if initialized { return }
        if let t = initTask { return try await t.value }
        let t = Task { try await self.doInitialize() }
        initTask = t
        do {
            try await t.value
            initialized = true
            initTask = nil
        } catch {
            initTask = nil
            throw error
        }
    }

    private func doInitialize() async throws {
        _ = try await requestOnce("initialize", [
            "protocolVersion": Self.protocolVersion,
            "capabilities": [String: Any](),
            "clientInfo": ["name": "shiyi-mac", "version": "0.1.0"],
        ])
        // 通知没有返回内容；失败不影响后续调用（鉴权错误在 initialize 时已暴露）
        _ = try? await post(["jsonrpc": "2.0", "method": "notifications/initialized"])
    }

    private func request(_ method: String, _ params: JSON?) async throws -> JSON {
        for attempt in 0 ... 1 {
            try await ensureInitialized()
            do {
                return try await requestOnce(method, params)
            } catch McpError.sessionExpired {
                if attempt == 1 { throw McpError.proto("MCP 会话反复过期，请稍后再试") }
                reset()
            }
        }
        throw McpError.proto("MCP 请求失败")
    }

    private func requestOnce(_ method: String, _ params: JSON?) async throws -> JSON {
        idGen += 1
        let id = idGen
        var body: JSON = ["jsonrpc": "2.0", "id": id, "method": method]
        if let params { body["params"] = params }
        let reply = try await post(body)

        let message = reply.messages.first { ($0["id"] as? Int) == id }
            ?? reply.messages.last { $0["result"] != nil || $0["error"] != nil }
        guard let message else {
            throw McpError.proto("响应中没有 JSON-RPC 结果：\(reply.snippet)")
        }
        if let err = message["error"] as? JSON {
            throw McpError.rpc((err["code"] as? Int) ?? 0, (err["message"] as? String) ?? "未知错误")
        }
        return (message["result"] as? JSON) ?? [:]
    }

    private struct RawReply {
        let messages: [JSON]
        let snippet: String
    }

    private func post(_ body: JSON) async throws -> RawReply {
        var token = (tokenProvider() ?? "").trimmed
        if token.lowercased().hasPrefix("bearer ") { token = String(token.dropFirst(7)).trimmed }
        if token.isEmpty { throw McpError.noCredential }

        let sent = sessionId
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        if let sent { req.setValue(sent, forHTTPHeaderField: "Mcp-Session-Id") }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await urlSession.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw McpError.proto("无效的响应") }
        if let sid = http.value(forHTTPHeaderField: "Mcp-Session-Id") { sessionId = sid }

        let text = String(data: data, encoding: .utf8) ?? ""
        if http.statusCode == 401 || http.statusCode == 403 { throw McpError.auth(http.statusCode) }
        if http.statusCode == 404 && sent != nil { throw McpError.sessionExpired }
        if !(200 ..< 300).contains(http.statusCode) { throw McpError.http(http.statusCode, String(text.prefix(200))) }

        let isSse = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased().contains("text/event-stream")
        let payloads: [String] = isSse ? Self.parseSse(text) : (text.trimmed.isEmpty ? [] : [text])
        var messages: [JSON] = []
        for payload in payloads {
            guard let d = payload.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) else { continue }
            if let o = obj as? JSON { messages.append(o) }
            else if let arr = obj as? [Any] { messages += arr.compactMap { $0 as? JSON } }
        }
        return RawReply(messages: messages, snippet: String(text.prefix(160)).replacingOccurrences(of: "\n", with: " "))
    }

    /// 解析 SSE 文本：按空行分隔事件，同一事件内多行 data 用换行拼接
    static func parseSse(_ text: String) -> [String] {
        var events: [String] = []
        var data = ""
        var hasData = false
        for raw in text.components(separatedBy: "\n") {
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            if line.isEmpty {
                if hasData { events.append(data); data = ""; hasData = false }
            } else if line.hasPrefix("data:") {
                var v = String(line.dropFirst(5))
                if v.hasPrefix(" ") { v.removeFirst() }
                if hasData { data += "\n" }
                data += v
                hasData = true
            }
        }
        if hasData { events.append(data) }
        return events
    }
}
