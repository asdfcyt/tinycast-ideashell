import Foundation

/// 解析 note_search / recent_notes / note_detail 返回的纯文本（移植自安卓端 `NoteParser`）
enum NoteParser {
    private static let reHeader = RX(#"^# (.+)\nnote_id:\s*([a-f0-9]+)"#)
    private static let reTitleTime = RX(#"^(.*?)\s@\s(\d{4}-\d{2}-\d{2}T\S+)$"#, multiline: false)
    private static let reTime = RX(#"^time:\s*(\S+)"#)
    private static let reTags = RX(#"^tags:\s*(.+)$"#)
    private static let reSummary = RX(#"^summary:\s*(.+)$"#)
    private static let reMetaLine = RX(#"^(time|tags|summary):"#, multiline: false, ignoreCase: true)
    private static let reNoText = RX(#"^\[No text content\]"#, multiline: false, ignoreCase: true)
    private static let reTotal = RX(#"Total notes[^:]*:\s*(\d+)"#, multiline: false, ignoreCase: true)

    private static let reDetailTitle = RX(#"^#\s+(.+)"#)
    private static let reDetailId = RX(#"^note_id:\s*([a-f0-9]+)"#, ignoreCase: true)
    private static let reMemoHead = RX(#"^\*\*Memo \d+:[^*]*\*\*[ \t]*$"#)
    private static let reLeadingSummary = RX(#"^[ \t]*summary:[ \t]*"#, multiline: false, ignoreCase: true)
    private static let reBlanks = RX(#"\n{3,}"#, multiline: false)

    static func totalOf(_ text: String) -> Int? {
        reTotal.first(in: text).flatMap { Int($0.group(1)) }
    }

    private static func splitTags(_ s: String?) -> [String] {
        (s ?? "").split(separator: ",").map { String($0).trimmed }.filter { !$0.isEmpty }
    }

    /// - note_search : "# Title\nnote_id: xxx\ntime: ...\nsummary: ..."
    /// - recent_notes: "# Title @ 2026-10-08T03:37:43.156Z\nnote_id: xxx\n<摘要或预览>"
    static func parseNotes(_ text: String) -> [NoteInfo] {
        let source = text.replacingOccurrences(of: "\r\n", with: "\n")
        let ns = source as NSString
        let heads = reHeader.all(in: source)
        var out: [NoteInfo] = []
        for (i, m) in heads.enumerated() {
            let start = m.range.location
            let end = i + 1 < heads.count ? heads[i + 1].range.location : ns.length
            let block = ns.substring(with: NSRange(location: start, length: end - start))

            var title = m.group(1).trimmed
            var time: String?
            if let tt = reTitleTime.fullMatch(in: title) {
                title = tt.group(1).trimmed
                time = tt.group(2)
            }
            if time == nil { time = reTime.first(in: block).map { $0.group(1) } }

            let tags = splitTags(reTags.first(in: block).map { $0.group(1) })

            var summary: String
            if let s = reSummary.first(in: block) {
                summary = s.group(1)
            } else {
                // recent_notes：note_id 之后直接跟摘要文本（没有 "summary:" 前缀）
                let blockNs = block as NSString
                let idPos = blockNs.range(of: "note_id:")
                var after = ""
                if idPos.location != NSNotFound {
                    let nl = blockNs.range(of: "\n", range: NSRange(location: idPos.location, length: blockNs.length - idPos.location))
                    if nl.location != NSNotFound { after = blockNs.substring(from: nl.location + 1) }
                }
                summary = after.components(separatedBy: "\n").map { $0.trimmed }
                    .filter { !$0.isEmpty && !reMetaLine.contains(in: $0) && !$0.hasPrefix("#") }
                    .joined(separator: " ")
            }
            // 纯语音笔记没有文字摘要，接口返回占位文案，不当作摘要
            let clean: String? = (summary.trimmed.isEmpty || reNoText.contains(in: summary)) ? nil : summary

            out.append(NoteInfo(
                id: m.group(2),
                title: title.isEmpty ? "无标题" : title,
                summary: clean,
                tags: tags,
                createdAt: time,
                text: block
            ))
        }
        return out
    }

    /// 解析 note_detail（scope=full）：头部是元信息，`## Memos` 之后是正文
    static func parseDetail(noteId: String, text: String) -> NoteDetail {
        let source = text.replacingOccurrences(of: "\r\n", with: "\n")
        let ns = source as NSString
        let memos = ns.range(of: "## Memos")
        let head = memos.location != NSNotFound ? ns.substring(to: memos.location) : source
        let body = memos.location != NSNotFound ? ns.substring(from: memos.location + memos.length) : ""
        let content = memoContent(body)
        let summary = reSummary.first(in: head).map { $0.group(1) }.flatMap { $0.trimmed.isEmpty ? nil : $0 }
        return NoteDetail(
            id: reDetailId.first(in: head).map { $0.group(1) } ?? noteId,
            title: reDetailTitle.first(in: head).map { $0.group(1).trimmed } ?? "",
            createdAt: reTime.first(in: head).map { $0.group(1) },
            tags: splitTags(reTags.first(in: head).map { $0.group(1) }),
            summary: summary,
            content: content,
            raw: source
        )
    }

    /// `## Memos` 之后的正文 → 干净的笔记内容：按 memo 切开、去重、去掉重复的 summary 前缀
    static func memoContent(_ body: String) -> String {
        let heads = reMemoHead.all(in: body)
        let ns = body as NSString
        var raw: [String] = []
        if heads.isEmpty {
            raw = [body]
        } else {
            for (i, m) in heads.enumerated() {
                let from = m.range.location + m.range.length
                let to = i + 1 < heads.count ? heads[i + 1].range.location : ns.length
                raw.append(ns.substring(with: NSRange(location: from, length: max(0, to - from))))
            }
        }
        let cleaned = raw.map(stripLeadingSummary).filter { !$0.trimmed.isEmpty }
        let keys = cleaned.map { $0.noSpace }
        var kept: [String] = []
        for i in cleaned.indices {
            var drop = false
            for j in keys.indices where j != i {
                if (keys[j].count > keys[i].count && keys[j].contains(keys[i])) || (keys[j] == keys[i] && j < i) {
                    drop = true
                    break
                }
            }
            if !drop { kept.append(cleaned[i]) }
        }
        return reBlanks.replace(in: kept.joined(separator: "\n\n"), with: "\n\n").trimmed
    }

    private static func stripLeadingSummary(_ memo: String) -> String {
        let text = memo.trimmingCharacters(in: CharacterSet(charactersIn: "\n\r"))
        guard let first = text.components(separatedBy: "\n").first(where: { !$0.trimmed.isEmpty }) else { return "" }
        if !reLeadingSummary.contains(in: first) { return collapseRepeatedPrefix(text) }
        let ns = text as NSString
        let pos = ns.range(of: first)
        let rest = ns.substring(from: pos.location + pos.length)
        let summary = reLeadingSummary.replace(in: first, with: "").trimmed
        if summary.isEmpty { return rest.trimmed }
        // 先按「开头一整段在后面又原样出现」折叠（长文：summary 回显 + 正文 + 正文再来一遍）
        let joined = (summary + rest).trimmed
        let collapsed = collapseRepeatedPrefix(joined)
        if collapsed != joined { return collapsed }
        let duplicated = rest.noSpace.contains(summary.noSpace)
        return (duplicated ? rest : joined).trimmed
    }

    /// 文本开头那一段被后面的内容完整重复时，只保留后面那份；可连续折叠多层
    private static func collapseRepeatedPrefix(_ text: String) -> String {
        var cur = text.trimmed
        for _ in 0 ..< 4 {
            let lines = cur.components(separatedBy: "\n")
            guard let firstLine = lines.first(where: { !$0.trimmed.isEmpty })?.trimmed else { return cur }
            var offset = 0
            var cut = -1
            for line in lines {
                if offset > 0 && line.trimmed == firstLine { cut = offset; break }
                offset += (line as NSString).length + 1
            }
            if cut <= 0 { return cur }
            let ns = cur as NSString
            let head = ns.substring(to: cut).noSpace
            let tail = ns.substring(from: cut)
            // 太短的重复多半是正常内容，只处理整段长文重复
            if head.count < 80 || !tail.noSpace.hasPrefix(head) { return cur }
            cur = tail.trimmed
        }
        return cur
    }
}

/// 笔记里的图片地址
enum NoteImages {
    private static let reMd = RX(#"!\[[^\]]*\]\(\s*<?([^)\s>]+)>?[^)]*\)"#, multiline: false)
    private static let reUrl = RX(#"(?:https?://|data:image/)[^\s)\]">'<]+"#, multiline: false, ignoreCase: true)
    private static let reImageExt = RX(#"\.(png|jpe?g|gif|webp|bmp|heic|heif|avif)(\?|#|$)"#, multiline: false, ignoreCase: true)
    private static let reNotImageExt = RX(#"\.(mp3|m4a|aac|wav|amr|mp4|mov|pdf|docx?|xlsx?|pptx?|txt|zip)(\?|#|$)"#, multiline: false, ignoreCase: true)
    private static let reHint = RX(#"image|img|photo|picture|图片|照片|附件|attachment"#, multiline: false, ignoreCase: true)

    private static func clean(_ url: String) -> String {
        url.trimmingCharacters(in: CharacterSet(charactersIn: ".,;，。、"))
    }

    static func extract(_ raw: String) -> [String] {
        var out: [String] = []
        func add(_ u: String) { if !out.contains(u) { out.append(u) } }
        for m in reMd.all(in: raw) { add(clean(m.group(1))) }
        for line in raw.components(separatedBy: "\n") {
            for m in reUrl.all(in: line) {
                let url = clean(m.group(0))
                let isImage = url.lowercased().hasPrefix("data:image/")
                    || reImageExt.contains(in: url)
                    || (reHint.contains(in: line) && !reNotImageExt.contains(in: url))
                if isImage { add(url) }
            }
        }
        return Array(out.prefix(30))
    }
}
