import Foundation

struct LlmError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// OpenAI 兼容的 Chat Completions 客户端（通义千问 / DeepSeek / OpenAI / 智谱等都能用，改设置里的地址和模型名即可）。
/// 对应安卓端 `LlmClient`；这里给排期这种较长的请求放宽了超时。
struct LlmClient: Sendable {
    let baseURL: String
    let model: String
    let key: String

    static let presets: [(name: String, url: String, model: String)] = [
        ("通义千问", "https://dashscope.aliyuncs.com/compatible-mode/v1", "qwen-plus"),
        ("DeepSeek", "https://api.deepseek.com", "deepseek-chat"),
        ("OpenAI", "https://api.openai.com/v1", "gpt-4o-mini"),
        ("智谱 GLM", "https://open.bigmodel.cn/api/paas/v4", "glm-4-flash"),
        ("Moonshot", "https://api.moonshot.cn/v1", "moonshot-v1-8k"),
    ]

    /// 发一轮「系统提示 + 用户内容」，要求回复是 JSON 对象；返回模型回复的文字
    func chatJSON(system: String, user: String, timeout: TimeInterval = 90) async throws -> String {
        guard !key.trimmed.isEmpty else { throw LlmError(message: "还没有填写 AI 模型的 API Key") }
        let base = baseURL.trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: base + "/chat/completions"), url.scheme?.hasPrefix("http") == true else {
            throw LlmError(message: "AI 模型的接口地址不正确，请检查设置")
        }
        // 先带 response_format=json_object；个别服务不认这个参数（返回 400）就去掉再试一次
        let first = try await send(url, system: system, user: user, json: true, timeout: timeout)
        let reply = first.code == 400 ? try await send(url, system: system, user: user, json: false, timeout: timeout) : first
        guard (200 ... 299).contains(reply.code) else { throw LlmError(message: Self.describe(reply.code, reply.body)) }
        guard let root = try? JSONSerialization.jsonObject(with: reply.body) as? [String: Any],
              let choice = (root["choices"] as? [[String: Any]])?.first,
              let msg = choice["message"] as? [String: Any],
              let content = (msg["content"] as? String)?.trimmed, !content.isEmpty
        else { throw LlmError(message: "AI 没有返回内容") }
        return content
    }

    /// 普通对话：返回模型回复的文字（不要求 JSON）
    func chatText(system: String, user: String, timeout: TimeInterval = 90) async throws -> String {
        guard !key.trimmed.isEmpty else { throw LlmError(message: "还没有填写 AI 模型的 API Key") }
        let base = baseURL.trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: base + "/chat/completions"), url.scheme?.hasPrefix("http") == true else {
            throw LlmError(message: "AI 模型的接口地址不正确，请检查设置")
        }
        let reply = try await send(url, system: system, user: user, json: false, timeout: timeout)
        guard (200 ... 299).contains(reply.code) else { throw LlmError(message: Self.describe(reply.code, reply.body)) }
        guard let root = try? JSONSerialization.jsonObject(with: reply.body) as? [String: Any],
              let choice = (root["choices"] as? [[String: Any]])?.first,
              let msg = choice["message"] as? [String: Any],
              let content = (msg["content"] as? String)?.trimmed, !content.isEmpty
        else { throw LlmError(message: "AI 没有返回内容") }
        return content
    }

    /// 流式对话：模型一边生成，一边把新生成的文字片段交出来（SSE）
    func streamText(system: String, user: String, timeout: TimeInterval = 120) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { cont in
            let task = Task {
                do {
                    guard !key.trimmed.isEmpty else { throw LlmError(message: "还没有填写 AI 模型的 API Key") }
                    let base = baseURL.trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    guard let url = URL(string: base + "/chat/completions"), url.scheme?.hasPrefix("http") == true else {
                        throw LlmError(message: "AI 模型的接口地址不正确，请检查设置")
                    }
                    let body: [String: Any] = [
                        "model": model.trimmed, "temperature": 0.2, "stream": true,
                        "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
                    ]
                    var req = URLRequest(url: url, timeoutInterval: timeout)
                    req.httpMethod = "POST"
                    req.setValue("Bearer " + key.trimmed, forHTTPHeaderField: "Authorization")
                    req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
                    req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    req.httpBody = try JSONSerialization.data(withJSONObject: body)
                    let (bytes, resp) = try await URLSession.shared.bytes(for: req)
                    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                    guard (200 ... 299).contains(code) else {
                        var data = Data()
                        for try await b in bytes { data.append(b); if data.count > 600 { break } }
                        throw LlmError(message: Self.describe(code, data))
                    }
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let d = payload.data(using: .utf8),
                              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                              let choice = (obj["choices"] as? [[String: Any]])?.first,
                              let delta = choice["delta"] as? [String: Any],
                              let s = delta["content"] as? String, !s.isEmpty else { continue }
                        cont.yield(s)
                    }
                    cont.finish()
                } catch let e as URLError where e.code == .timedOut {
                    cont.finish(throwing: LlmError(message: "AI 响应超时，请稍后再试"))
                } catch is URLError {
                    cont.finish(throwing: LlmError(message: "网络不可用，连不上 AI 服务"))
                } catch {
                    cont.finish(throwing: error)
                }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    private func send(_ url: URL, system: String, user: String, json: Bool, timeout: TimeInterval) async throws -> (code: Int, body: Data) {
        var body: [String: Any] = [
            "model": model.trimmed,
            "temperature": 0.2,
            "stream": false,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ]
        if json { body["response_format"] = ["type": "json_object"] }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("Bearer " + key.trimmed, forHTTPHeaderField: "Authorization")
        req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            return ((resp as? HTTPURLResponse)?.statusCode ?? 0, data)
        } catch let e as URLError where e.code == .timedOut {
            throw LlmError(message: "AI 响应超时，请稍后再试")
        } catch is URLError {
            throw LlmError(message: "网络不可用，连不上 AI 服务")
        }
    }

    private static func describe(_ code: Int, _ body: Data) -> String {
        switch code {
        case 401, 403: return "AI 的 API Key 不正确或没有权限"
        case 404: return "AI 接口地址或模型名不对（\(code)）"
        case 429: return "AI 请求太频繁或额度用完"
        default:
            let t = String(data: body, encoding: .utf8)?.trimmed.prefix(80) ?? ""
            return "AI 请求失败（\(code)）" + (t.isEmpty ? "" : "：\(t)")
        }
    }

    /// 从回复里取出 JSON 对象（兼容 ```json 代码块 / 前后多余文字）
    static func extractJSON(_ text: String) -> [String: Any]? {
        var t = text.trimmed
        if let a = t.firstIndex(of: "{"), let b = t.lastIndex(of: "}"), a < b { t = String(t[a ... b]) }
        return (try? JSONSerialization.jsonObject(with: Data(t.utf8))) as? [String: Any]
    }
}
