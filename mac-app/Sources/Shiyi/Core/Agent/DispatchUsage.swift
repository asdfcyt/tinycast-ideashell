import Foundation

/// 一轮的用量。没上报的（nil）如实显示「未上报」，不当成 0
struct LedgerUsage: Codable, Hashable {
    var input = 0
    var output = 0
    var cacheRead = 0
    /// 费用（美元）；拿不到 = nil（比如走的是订阅 / 免费额度，opencode 记的 0 也按拿不到算）
    var cost: Double?

    /// 输入 + 输出（缓存命中的不算，不然数字没有意义）
    var tokens: Int { input + output }
}

/// 从 Agent 的输出 / 本机数据里取结果文本、会话和用量
enum DispatchResult {
    struct Parsed {
        var text: String
        var sessionId: String?
        var usage: LedgerUsage?
        var isError = false
    }

    /// `claude -p --output-format json` 的输出：日志里最后一个 JSON 对象
    static func claude(_ log: String) -> Parsed? {
        for line in log.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("{"), t.hasSuffix("}"), let d = t.data(using: .utf8),
                  let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { continue }
            guard (j["type"] as? String) == "result" || j["result"] != nil else { continue }
            var p = Parsed(text: (j["result"] as? String) ?? "")
            p.sessionId = j["session_id"] as? String
            p.isError = (j["is_error"] as? Bool) ?? false
            if let u = j["usage"] as? [String: Any] {
                var x = LedgerUsage()
                x.input = (u["input_tokens"] as? Int) ?? 0
                x.output = (u["output_tokens"] as? Int) ?? 0
                x.cacheRead = (u["cache_read_input_tokens"] as? Int) ?? 0
                if let c = (j["total_cost_usd"] as? Double) ?? (j["cost_usd"] as? Double), c > 0 { x.cost = c }
                p.usage = x
            }
            return p
        }
        return nil
    }

    /// 普通命令行：整个输出（去掉拾忆自己写的分隔行和终端颜色码）
    static func plain(_ log: String) -> String {
        let lines = log.split(separator: "\n", omittingEmptySubsequences: false).filter { !$0.hasPrefix("=== ") }
        let s = lines.joined(separator: "\n").replacingOccurrences(of: "\u{1B}\\[[0-9;]*[A-Za-z]", with: "", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// opencode：读它自己的数据库（只读），把这个目录下、这段时间里 assistant 消息的 Token 加起来。查不到 = nil
    nonisolated static func opencodeUsage(cwd: String, from: Date, to: Date) -> LedgerUsage? {
        let db = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/opencode/opencode.db").path
        guard FileManager.default.fileExists(atPath: db) else { return nil }
        let dir = cwd.replacingOccurrences(of: "'", with: "''")
        let a = Int(from.timeIntervalSince1970 * 1000) - 1000
        let b = Int(to.timeIntervalSince1970 * 1000) + 5000
        let sql = """
        select coalesce(sum(json_extract(m.data,'$.tokens.input')),0) as i,
               coalesce(sum(json_extract(m.data,'$.tokens.output')),0) + coalesce(sum(json_extract(m.data,'$.tokens.reasoning')),0) as o,
               coalesce(sum(json_extract(m.data,'$.tokens.cache.read')),0) as c,
               coalesce(sum(json_extract(m.data,'$.cost')),0) as cost,
               count(*) as n
        from message m join session s on s.id = m.session_id
        where s.directory = '\(dir)' and json_extract(m.data,'$.role') = 'assistant' and m.time_created >= \(a) and m.time_created <= \(b)
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        p.arguments = ["-readonly", "-cmd", ".timeout 800", "-json", db, sql]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]], let r = rows.first,
              (r["n"] as? Int ?? 0) > 0 else { return nil }
        var u = LedgerUsage()
        u.input = (r["i"] as? Int) ?? Int((r["i"] as? Double) ?? 0)
        u.output = (r["o"] as? Int) ?? Int((r["o"] as? Double) ?? 0)
        u.cacheRead = (r["c"] as? Int) ?? Int((r["c"] as? Double) ?? 0)
        if let c = r["cost"] as? Double, c > 0 { u.cost = c }
        return u.tokens == 0 && u.cost == nil ? nil : u
    }

    /// opencode 最后一条回复的正文：同样读它自己的数据库（不另外调用任何模型）。查不到 = nil
    nonisolated static func opencodeResult(cwd: String, from: Date, to: Date) -> String? {
        let db = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/opencode/opencode.db").path
        guard FileManager.default.fileExists(atPath: db) else { return nil }
        let dir = cwd.replacingOccurrences(of: "'", with: "''")
        let a = Int(from.timeIntervalSince1970 * 1000) - 1000
        let b = Int(to.timeIntervalSince1970 * 1000) + 5000
        let sql = """
        select json_extract(p.data,'$.text') as t
        from part p join message m on m.id = p.message_id join session s on s.id = m.session_id
        where s.directory = '\(dir)' and json_extract(m.data,'$.role') = 'assistant' and json_extract(p.data,'$.type') = 'text'
          and m.time_created >= \(a) and m.time_created <= \(b)
        order by p.time_created desc limit 1
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        p.arguments = ["-readonly", "-cmd", ".timeout 800", "-json", db, sql]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]], let t = rows.first?["t"] as? String else { return nil }
        let s = t.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    /// 1234 → 1.2k；1_500_000 → 1.5M
    static func compact(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1000 { return String(format: "%.1fk", Double(n) / 1000) }
        return "\(n)"
    }
}
