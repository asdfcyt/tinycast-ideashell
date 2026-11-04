import Foundation

/// 从 Agent 的对话记录里取「最后一条回复」，以及完成卡片用到的一点文字判断
enum AgentTranscript {
    /// Cursor 的 transcript_path 是 jsonl：每行一条消息，最后一条 assistant 就是结论
    static func lastAssistantText(path: String?) -> String {
        guard let path, !path.isEmpty, let h = FileHandle(forReadingAtPath: path) else { return "" }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        let chunk: UInt64 = 600_000
        try? h.seek(toOffset: size > chunk ? size - chunk : 0)
        guard let data = try? h.readToEnd(), let text = String(data: data, encoding: .utf8) else { return "" }
        for line in text.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            guard let d = line.data(using: .utf8),
                  let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { continue }
            let role = (j["role"] as? String) ?? (j["type"] as? String) ?? ""
            guard role == "assistant" else { continue }
            let msg = j["message"] as? [String: Any] ?? j
            var out = ""
            if let s = msg["content"] as? String {
                out = s
            } else if let arr = msg["content"] as? [[String: Any]] {
                out = arr.compactMap { ($0["type"] as? String) == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
            }
            out = out.trimmingCharacters(in: .whitespacesAndNewlines)
            if !out.isEmpty { return out }
        }
        return ""
    }

    /// 卡片上展示用：压掉多余空行，太长截断
    static func tidy(_ s: String, limit: Int = 2400) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        while t.contains("\n\n\n") { t = t.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
        if t.count > limit { t = String(t.prefix(limit)) + "…" }
        return t
    }

    /// 最后几句里是不是在向你提问 / 等你确认
    static func asksQuestion(_ s: String) -> Bool {
        let tail = String(s.suffix(160))
        if tail.contains("？") || tail.contains("?") { return true }
        return ["请确认", "是否需要", "你希望", "需要我", "要不要", "你看", "请选择", "请告诉我"].contains(where: tail.contains)
    }

    /// 默认的几个后续指令（没开 AI 建议时用）
    static func defaultOptions(failed: Bool, asks: Bool) -> [AgentCompletion.Option] {
        if failed {
            return [
                .init(label: "分析原因并修复", instruction: "刚才出错了，请分析失败原因并修复，然后重新验证。"),
                .init(label: "换个思路", instruction: "刚才的做法走不通，请换一种思路再试。"),
            ]
        }
        var o: [AgentCompletion.Option] = []
        if asks { o.append(.init(label: "按你的建议来", instruction: "按你的建议来，直接做吧。")) }
        o += [
            .init(label: "自查一遍", instruction: "请自查刚才的改动：有没有遗漏、边界问题或回归风险，发现问题直接修复。"),
            .init(label: "总结改动", instruction: "请用要点总结这次改了哪些文件、做了什么、有哪些风险和后续建议。"),
        ]
        return o
    }
}

/// 项目名：取目录名；WorkBuddy 的临时会话目录是时间戳（2026-11-02-09-18-33），换成人话
enum AgentProject {
    static func name(_ path: String) -> String {
        guard !path.isEmpty else { return "—" }
        let last = URL(fileURLWithPath: path).lastPathComponent
        let parts = last.split(separator: "-")
        if parts.count >= 5, parts.count <= 7, parts.allSatisfy({ $0.allSatisfy(\.isNumber) }), parts[0].count == 4 {
            return "临时会话 \(parts[3]):\(parts[4])"
        }
        return last
    }
}
