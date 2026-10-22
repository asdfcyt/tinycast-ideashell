import Foundation

/// 闪念贝壳 MCP 的只读封装（搜索 / 时间区间 / 笔记全文）
struct IdeashellApi {
    let mcp: McpClient

    /// 语义搜索；接口单次最多 20 条
    func searchNotes(_ query: String, limit: Int = 15) async throws -> [NoteInfo] {
        let text = try await mcp.callText("note_search", ["query": query, "limit": min(max(limit, 1), 20)])
        return text.trimmed.isEmpty ? [] : NoteParser.parseNotes(text)
    }

    /// 新建笔记。标签以 `#标签` 写进正文末尾（闪念贝壳 App 只识别正文里的行内标签）
    @discardableResult
    func createNote(title: String, body: String, tags: [String], folderId: String? = nil, inlineTags: Bool = true) async throws -> String {
        let content = inlineTags ? Self.withInlineTags(body, tags) : body
        var args: JSON = ["title": title]
        if !content.isEmpty { args["content"] = content }
        if !tags.isEmpty { args["tags"] = tags }
        if let folderId, !folderId.isEmpty { args["folder_id"] = folderId }
        return try await mcp.callText("note_create", args)
    }

    /// 整篇覆盖笔记正文
    @discardableResult
    func updateNoteBody(_ noteId: String, body: String) async throws -> String {
        try await mcp.callText("note_update", ["note_id": noteId, "content": body])
    }

    /// 闪念贝壳自带的待办（没连滴答时的退路）
    func createTodo(_ content: String, date: String?, time: String?) async throws {
        var item: JSON = ["content": content]
        if let date { item["date"] = date }
        if let time { item["time"] = time }
        _ = try await mcp.callText("todo_create", ["items": [item]])
    }

    func createFolder(_ name: String) async throws -> String {
        try await mcp.callText("folder_create", ["name": name])
    }

    /// 标签名里不能有空白，否则 App 会把它拆成多个
    static func cleanTag(_ tag: String) -> String {
        RX(#"[\s#]+"#, multiline: false).replace(in: tag, with: "")
    }

    /// 在正文末尾追加一行 `#标签1 #标签2`（已在正文里出现的标签不重复追加）
    static func withInlineTags(_ body: String, _ tags: [String]) -> String {
        var seen = Set<String>()
        let clean = tags.map(cleanTag).filter { !$0.isEmpty && seen.insert($0).inserted }
        let missing = clean.filter { tag in
            !RX("(^|\\s)#" + NSRegularExpression.escapedPattern(for: tag) + "(?=\\s|$)", multiline: false).contains(in: body)
        }
        if missing.isEmpty { return body }
        let line = missing.map { "#" + $0 }.joined(separator: " ")
        return body.trimmed.isEmpty ? line : body.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n" + line
    }

    struct Folder { let id: String; let name: String }

    /// 文件夹列表。文本格式："- 📁 FolderName [folder_id: xxx]"
    func listFolders() async throws -> [Folder] {
        let text = try await mcp.callText("folder_list", [:])
        let re = RX(#"^\s*-\s*(.+?)\s*\[folder_id:\s*([a-f0-9]+)\]"#, ignoreCase: true)
        let lead = RX(#"^[^\p{L}\p{N}]+"#, multiline: false)
        return re.all(in: text).map { m in
            Folder(id: m.group(2), name: lead.replace(in: m.group(1), with: "").trimmed)
        }
    }

    /// 文件夹里的笔记，返回格式 "- 标题 [note_id: xxx]"
    func notesInFolder(_ folderId: String) async throws -> [(id: String, title: String)] {
        let text = try await mcp.callText("folder_notes", ["folder_id": folderId])
        let re = RX(#"^-\s+(.+?)\s*\[note_id:\s*([a-f0-9]+)\]\s*$"#, ignoreCase: true)
        return re.all(in: text).map { (id: $0.group(2), title: $0.group(1).trimmed) }
    }

    func noteFull(_ noteId: String) async throws -> NoteDetail {
        let text = try await mcp.callText("note_detail", ["note_id": noteId, "scope": "full"])
        return NoteParser.parseDetail(noteId: noteId, text: text)
    }

    /// 取出 [start, end) 内创建的全部笔记。
    /// recent_notes 单次最多 20 条，但会返回区间总数；超过 20 条时把区间对半拆分并行拉取，
    /// 直到每段都取全（最小粒度 1 小时，再多就标记为 truncated）。
    func notesInRange(_ start: Date, _ end: Date) async throws -> NotesInRange {
        let flag = TruncFlag()
        let all = try await walkRange(start.timeIntervalSince1970, end.timeIntervalSince1970, flag)
        var seen = Set<String>()
        var unique: [NoteInfo] = []
        for n in all where seen.insert(n.id).inserted { unique.append(n) }
        unique.sort { ($0.createdAt ?? "") > ($1.createdAt ?? "") }
        return NotesInRange(notes: unique, truncated: await flag.value)
    }

    private actor TruncFlag {
        var value = false
        func set() { value = true }
    }

    private func walkRange(_ s: Double, _ e: Double, _ flag: TruncFlag) async throws -> [NoteInfo] {
        let text = try await mcp.callText("recent_notes", [
            "start_time": NoteTime.utcString(Date(timeIntervalSince1970: s)),
            "end_time": NoteTime.utcString(Date(timeIntervalSince1970: e)),
            "limit": 20,
        ])
        let notes = text.trimmed.isEmpty ? [] : NoteParser.parseNotes(text)
        let total = NoteParser.totalOf(text) ?? notes.count
        if total <= notes.count { return notes }
        if e - s <= 3600 {
            await flag.set()
            return notes
        }
        let mid = s + (e - s) / 2
        async let left = walkRange(s, mid, flag)
        async let right = walkRange(mid, e, flag)
        return try await left + right
    }
}
