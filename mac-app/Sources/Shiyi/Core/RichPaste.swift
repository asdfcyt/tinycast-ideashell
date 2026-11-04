import AppKit

/// 粘贴 / 拖入时保留格式：从网页、文档、表格软件里复制的内容，转成 Markdown 再放进输入框，
/// 表格不再变成一堆 Tab，列表 / 标题 / 代码块 / 引用 也留得住。
/// - 剪贴板里有 HTML：转成 Markdown（表格、列表、标题、代码块、引用、分割线；加粗 / 斜体 / 删除线 / 行内代码 / 链接）
/// - 只有纯文字，但是 Excel / Numbers 那样的多行 Tab 分隔：转成 Markdown 表格
/// - 其他情况返回 nil，调用方继续按纯文字处理（所以从代码编辑器复制的带颜色代码不会被动）
enum RichPaste {
    struct Result {
        var text: String
        /// 多行的块级内容（表格 / 列表 / 代码块…）：插进正文时要独占几行
        var isBlock: Bool
    }

    /// keepInline：只有加粗 / 链接这类行内格式时要不要也转。便签（Markdown 输入框）要，万能输入（待办标题等）不要，免得标题里冒出一串链接符号
    static func result(from pb: NSPasteboard, keepInline: Bool) -> Result? {
        let types = pb.types ?? []
        if types.contains(.html), let data = pb.data(forType: .html), let c = HTMLMarkdown.convert(data) {
            if c.block { return Result(text: c.text, isBlock: true) }
            if keepInline, c.inline { return Result(text: c.text, isBlock: false) }
        }
        if let s = pb.string(forType: .string), let t = tabTable(s) { return Result(text: t, isBlock: true) }
        return nil
    }

    /// 多行、每行列数一样的 Tab 分隔文字 → Markdown 表格
    static func tabTable(_ raw: String) -> String? {
        guard raw.contains("\t") else { return nil }
        let norm = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var lines = norm.components(separatedBy: "\n")
        while let last = lines.last, last.isEmpty { lines.removeLast() }
        guard lines.count >= 2, lines.count <= 2000 else { return nil }
        var rows: [[String]] = []
        for l in lines {
            rows.append(l.components(separatedBy: "\t").map(unquote))
        }
        let n = rows[0].count
        guard n >= 2, n <= 60, rows.allSatisfy({ $0.count == n }) else { return nil }
        // 表头每格都要有字：缩进的代码（每行开头一个 Tab）不会被当成表格
        guard rows[0].allSatisfy({ !$0.trimmed.isEmpty }) else { return nil }
        return MarkdownTable.render(rows: rows)
    }

    /// Excel 把含引号 / 换行的格子用双引号包起来
    private static func unquote(_ s: String) -> String {
        guard s.count >= 2, s.hasPrefix("\""), s.hasSuffix("\"") else { return s }
        return String(s.dropFirst().dropLast()).replacingOccurrences(of: "\"\"", with: "\"")
    }
}

// MARK: - HTML → Markdown

enum HTMLMarkdown {
    struct Output {
        var text: String
        /// 有表格 / 列表 / 标题 / 代码块 / 引用 / 分割线，并且不止一行
        var block: Bool
        /// 只有行内格式（加粗 / 链接…），或者块级内容只有一行
        var inline: Bool
    }

    private static let metaCharset = RX("<meta[^>]*charset[^>]*>", multiline: false, ignoreCase: true)
    private static let bodyRE = RX("<body[^>]*>([\\s\\S]*?)(?:</body>|\\z)", multiline: false, ignoreCase: true)

    static func convert(_ data: Data) -> Output? {
        guard !data.isEmpty, data.count <= 3_000_000 else { return nil }
        var html: String
        let head = [UInt8](data.prefix(2))
        if head == [0xFF, 0xFE] || head == [0xFE, 0xFF] {
            html = String(data: data, encoding: .utf16) ?? ""
        } else {
            html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252) ?? ""
        }
        guard !html.isEmpty else { return nil }
        // 浏览器 / Office 会用注释标出真正复制的那一段
        if let s = html.range(of: "<!--StartFragment-->"), let e = html.range(of: "<!--EndFragment-->"), s.upperBound <= e.lowerBound {
            html = String(html[s.upperBound ..< e.lowerBound])
        } else if let m = bodyRE.first(in: html) {
            html = m.group(1)
        }
        // 原来的编码声明去掉：我们自己重新编码
        html = metaCharset.replace(in: html, with: "")
        // 系统的 HTML 解析器不认 <meta charset>，没有声明就按 Latin-1 读，中文会变成乱码：
        // 非 ASCII 字符一律改写成数字字符引用（&#x4E2D;），这样和编码无关
        var ascii = String.UnicodeScalarView()
        for u in html.unicodeScalars {
            if u.value < 128 { ascii.append(u) } else { ascii.append(contentsOf: "&#\(u.value);".unicodeScalars) }
        }
        let doc = "<html><head><meta http-equiv=\"Content-Type\" content=\"text/html; charset=utf-8\"></head><body>" + String(ascii) + "</body></html>"
        guard let xml = try? XMLDocument(data: Data(doc.utf8), options: [.documentTidyHTML, .nodePreserveWhitespace, .nodeLoadExternalEntitiesNever]),
              let root = xml.rootElement() else { return nil }
        let body = root.elements(forName: "body").first ?? root
        let c = Converter()
        var w = MDWriter()
        c.children(body, &w)
        let text = c.finish(w.out)
        guard !text.trimmed.isEmpty else { return nil }
        let multi = text.contains("\n")
        let block = c.block && multi
        return Output(text: text, block: block, inline: !block && (c.inline || c.block))
    }

    // MARK: 输出缓冲

    private struct MDWriter {
        var out = ""
        /// 表格单元格 / 加粗里面：不分行，换行都变空格
        var flat = false
        /// 刚写完列表符号：紧跟着的段落不要再换行
        var atMarker = false

        mutating func raw(_ s: String) {
            guard !s.isEmpty else { return }
            out += s
            atMarker = false
        }

        mutating func text(_ s: String) {
            var s = s
            if s.hasPrefix(" "), out.isEmpty || out.hasSuffix(" ") || out.hasSuffix("\n") { s.removeFirst() }
            guard !s.isEmpty else { return }
            out += s
            atMarker = false
        }

        /// 保证前面至少有 n 个换行（flat 模式只补一个空格）
        mutating func ensureBreak(_ n: Int) {
            if atMarker { return }
            if flat {
                if !out.isEmpty, !out.hasSuffix(" ") { out += " " }
                return
            }
            guard !out.isEmpty else { return }
            while out.hasSuffix(" ") { out.removeLast() }
            var have = 0
            for ch in out.reversed() { if ch == "\n" { have += 1 } else { break } }
            if have < n { out += String(repeating: "\n", count: n - have) }
        }
    }

    // MARK: 转换

    private final class Converter {
        var block = false
        var inline = false
        private var listDepth = 0
        private var inHeading = false

        private static let skipTags: Set<String> = [
            "script", "style", "head", "title", "meta", "link", "noscript", "svg", "canvas", "iframe",
            "template", "select", "option", "textarea", "button", "img", "picture", "video", "audio", "object", "embed",
        ]
        private static let blockTags: Set<String> = [
            "div", "section", "article", "header", "footer", "main", "aside", "nav", "figure", "figcaption",
            "form", "fieldset", "address", "details", "summary", "dl", "dt", "dd", "center", "tr", "caption",
        ]
        private static let spaces = RX("[ \\t\\r\\n\\u00A0\\u2028\\u2029]+", multiline: false)
        private static let emptyMarker = RX("^\\s*(#{1,6}|[-*]|\\d+\\.)\\s*$", multiline: false)
        private static let textAlign = RX("text-align:\\s*(right|center)", multiline: false, ignoreCase: true)

        static func collapse(_ s: String) -> String { spaces.replace(in: s, with: " ") }

        func children(_ n: XMLNode, _ w: inout MDWriter) {
            for c in n.children ?? [] { walk(c, &w) }
        }

        /// 子内容单独转成一段文字（表格单元格 / 加粗 / 链接 / 引用）
        private func sub(_ el: XMLElement, flat: Bool) -> String {
            var w = MDWriter()
            w.flat = flat
            children(el, &w)
            return flat ? Self.collapse(w.out) : finish(w.out)
        }

        private func compactStyle(_ el: XMLElement) -> String {
            (el.attribute(forName: "style")?.stringValue ?? "").lowercased()
                .replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "\n", with: "")
        }

        private func hidden(_ el: XMLElement) -> Bool {
            if el.attribute(forName: "hidden") != nil { return true }
            let style = compactStyle(el)
            // mso-list:Ignore 是 Word 放在段落开头的列表符号（·、1.），我们自己生成
            return style.contains("display:none") || style.contains("mso-list:ignore")
        }

        /// Word 列表段落：层级 + 是不是有序（看开头那个符号文字：1. / a) / 一、 是有序，· o § 是无序）
        private var officeCount: [Int: Int] = [:]
        private static let msoLevel = RX("level(\\d+)", multiline: false)
        private static let orderedMark = RX("^\\(?([0-9A-Za-z]{1,4}[.)]|[一二三四五六七八九十]+[、.])", multiline: false)

        private func officeList(_ el: XMLElement) -> (level: Int, ordered: Bool)? {
            let style = compactStyle(el)
            guard style.contains("mso-list:"), !style.contains("mso-list:none") else { return nil }
            let level = max(Int(Self.msoLevel.first(in: style)?.group(1) ?? "") ?? 1, 1)
            func ignoreSpan(_ n: XMLNode) -> XMLElement? {
                for c in n.children ?? [] {
                    guard c.kind == .element, let e = c as? XMLElement else { continue }
                    if compactStyle(e).contains("mso-list:ignore") { return e }
                    if let f = ignoreSpan(e) { return f }
                }
                return nil
            }
            let mark = ignoreSpan(el).map { rawText($0).trimmed } ?? ""
            return (min(level, 8), Self.orderedMark.contains(in: mark))
        }

        private func rawText(_ n: XMLNode) -> String {
            if n.kind == .text { return (n.stringValue ?? "").replacingOccurrences(of: "\u{00A0}", with: " ") }
            guard let el = n as? XMLElement else { return "" }
            if el.name?.lowercased() == "br" { return "\n" }
            return (el.children ?? []).map { rawText($0) }.joined()
        }

        func walk(_ node: XMLNode, _ w: inout MDWriter) {
            if node.kind == .text {
                w.text(Self.collapse(node.stringValue ?? ""))
                return
            }
            guard node.kind == .element, let el = node as? XMLElement else { return }
            let name = (el.name ?? "").lowercased()
            if Self.skipTags.contains(name) || hidden(el) { return }
            switch name {
            case "br":
                w.raw(w.flat ? " " : "\n")
            case "hr":
                guard !w.flat else { return }
                block = true
                w.ensureBreak(2)
                w.raw("---")
                w.ensureBreak(2)
            case "h1", "h2", "h3", "h4", "h5", "h6":
                block = true
                w.ensureBreak(2)
                if !w.flat { w.raw(String(repeating: "#", count: Int(name.dropFirst()) ?? 1) + " ") }
                let was = inHeading
                inHeading = true
                children(el, &w)
                inHeading = was
                w.ensureBreak(2)
            case "p":
                if let info = officeList(el), !w.flat {
                    // Word / WPS 的列表是带 mso-list 样式的普通段落，不是 <ul>
                    block = true
                    officeCount[info.level] = info.ordered ? (officeCount[info.level] ?? 0) + 1 : 0
                    for k in officeCount.keys where k > info.level { officeCount[k] = nil }
                    w.atMarker = false
                    w.ensureBreak(1)
                    w.raw(String(repeating: "  ", count: info.level - 1) + (info.ordered ? "\(officeCount[info.level] ?? 1). " : "- "))
                    w.atMarker = true
                    children(el, &w)
                    w.ensureBreak(1)
                    return
                }
                officeCount = [:]
                let n = listDepth > 0 ? 1 : 2
                w.ensureBreak(n)
                children(el, &w)
                w.ensureBreak(n)
            case "ul", "ol":
                list(el, ordered: name == "ol", &w)
            case "li":
                // 不在列表里的孤立 li
                w.ensureBreak(1)
                if !w.flat { w.raw("- "); w.atMarker = true }
                children(el, &w)
                w.ensureBreak(1)
            case "blockquote":
                let body = sub(el, flat: w.flat)
                guard !body.trimmed.isEmpty else { return }
                if w.flat { w.text(body); return }
                block = true
                w.ensureBreak(2)
                w.raw(body.components(separatedBy: "\n").map { $0.isEmpty ? ">" : "> " + $0 }.joined(separator: "\n"))
                w.ensureBreak(2)
            case "pre":
                let code = rawText(el).trimmingCharacters(in: .newlines)
                guard !code.trimmed.isEmpty else { return }
                if w.flat { w.text(Self.collapse(code)); return }
                block = true
                w.ensureBreak(2)
                w.raw("```\n" + code + "\n```")
                w.ensureBreak(2)
            case "table":
                table(el, &w)
            case "strong", "b":
                emphasis(el, "**", &w)
            case "em", "i", "cite":
                emphasis(el, "*", &w)
            case "del", "s", "strike":
                emphasis(el, "~~", &w)
            case "code", "kbd", "samp", "tt":
                let t = Self.collapse(rawText(el)).trimmed
                guard !t.isEmpty else { return }
                if inHeading || t.contains("`") { w.text(t); return }
                inline = true
                w.raw("`" + t + "`")
            case "a":
                link(el, &w)
            case "input":
                if (el.attribute(forName: "type")?.stringValue ?? "").lowercased() == "checkbox" {
                    inline = true
                    w.raw(el.attribute(forName: "checked") != nil ? "[x] " : "[ ] ")
                }
            default:
                if Self.blockTags.contains(name) {
                    w.ensureBreak(1)
                    children(el, &w)
                    w.ensureBreak(1)
                } else {
                    children(el, &w)
                }
            }
        }

        // MARK: 行内

        /// 前后的空白留在标记外面（`** 字 **` 不是合法的加粗）
        private func wrap(_ inner: String, _ open: String, _ close: String, _ w: inout MDWriter) {
            let core = inner.trimmed
            guard !core.isEmpty else { return }
            if inner.first?.isWhitespace == true { w.text(" ") }
            w.raw(open + core + close)
            if inner.last?.isWhitespace == true { w.raw(" ") }
        }

        private func emphasis(_ el: XMLElement, _ mark: String, _ w: inout MDWriter) {
            let style = (el.attribute(forName: "style")?.stringValue ?? "").lowercased().replacingOccurrences(of: " ", with: "")
            // Google 文档把整篇内容包在 <b style="font-weight:normal"> 里
            if mark == "**", style.contains("font-weight:normal") || style.contains("font-weight:400") { children(el, &w); return }
            if inHeading { children(el, &w); return }
            let inner = sub(el, flat: true)
            guard !inner.trimmed.isEmpty else { w.text(inner.isEmpty ? "" : " "); return }
            inline = true
            wrap(inner, mark, mark, &w)
        }

        private func link(_ el: XMLElement, _ w: inout MDWriter) {
            let href = (el.attribute(forName: "href")?.stringValue ?? "").trimmed
            let low = href.lowercased()
            guard !inHeading, low.hasPrefix("http://") || low.hasPrefix("https://") || low.hasPrefix("mailto:") else {
                children(el, &w)
                return
            }
            let inner = sub(el, flat: true)
            let core = inner.trimmed
            guard !core.isEmpty else { return }
            inline = true
            if core == href {
                w.raw(href)
                return
            }
            let url = href.replacingOccurrences(of: " ", with: "%20")
                .replacingOccurrences(of: "(", with: "%28").replacingOccurrences(of: ")", with: "%29")
            wrap(inner, "[", "](\(url))", &w)
        }

        // MARK: 列表

        private func list(_ el: XMLElement, ordered: Bool, _ w: inout MDWriter) {
            block = true
            var n = Int(el.attribute(forName: "start")?.stringValue ?? "") ?? 1
            let gap = listDepth > 0 ? 1 : 2
            w.ensureBreak(gap)
            for c in el.children ?? [] {
                guard c.kind == .element, let li = c as? XMLElement else { continue }
                guard (li.name ?? "").lowercased() == "li" else { walk(c, &w); continue }
                if hidden(li) { continue }
                w.atMarker = false
                w.ensureBreak(1)
                if !w.flat {
                    w.raw(String(repeating: "  ", count: listDepth) + (ordered ? "\(n). " : "- "))
                    w.atMarker = true
                }
                n += 1
                listDepth += 1
                children(li, &w)
                listDepth -= 1
            }
            w.ensureBreak(gap)
        }

        // MARK: 表格

        private func tableRows(_ el: XMLElement) -> [XMLElement] {
            var out: [XMLElement] = []
            for c in el.children ?? [] {
                guard c.kind == .element, let ce = c as? XMLElement else { continue }
                switch (ce.name ?? "").lowercased() {
                case "tr": out.append(ce)
                case "thead", "tbody", "tfoot": out += tableRows(ce)
                default: break
                }
            }
            return out
        }

        private func alignment(_ c: XMLElement) -> MarkdownTable.Align {
            var a = (c.attribute(forName: "align")?.stringValue ?? "").lowercased()
            if a.isEmpty, let m = Self.textAlign.first(in: c.attribute(forName: "style")?.stringValue ?? "") { a = m.group(1).lowercased() }
            return a == "right" ? .right : (a == "center" ? .center : .left)
        }

        private func table(_ el: XMLElement, _ w: inout MDWriter) {
            var rows: [[String]] = []
            var aligns: [[MarkdownTable.Align]] = []
            for tr in tableRows(el) where !hidden(tr) {
                var cells: [String] = []
                var al: [MarkdownTable.Align] = []
                for c in tr.children ?? [] {
                    guard c.kind == .element, let td = c as? XMLElement, !hidden(td) else { continue }
                    let tag = (td.name ?? "").lowercased()
                    guard tag == "td" || tag == "th" else { continue }
                    cells.append(sub(td, flat: true).trimmed)
                    al.append(alignment(td))
                    let span = min(max(Int(td.attribute(forName: "colspan")?.stringValue ?? "") ?? 1, 1), 40)
                    for _ in 1 ..< span { cells.append(""); al.append(.left) }
                }
                if cells.contains(where: { !$0.isEmpty }) { rows.append(cells); aligns.append(al) }
            }
            guard !rows.isEmpty else { return }
            let cols = rows.map { $0.count }.max() ?? 0
            // 一行或一列的「表格」（单个格子、一整行 / 一整列）不是表格：按原样摆平
            guard !w.flat, rows.count >= 2, cols >= 2 else {
                let flatText = rows.map { $0.filter { !$0.isEmpty }.joined(separator: w.flat ? " " : "\t") }
                if w.flat { w.text(flatText.joined(separator: " ")) } else {
                    w.ensureBreak(1)
                    w.raw(flatText.joined(separator: "\n"))
                    w.ensureBreak(1)
                }
                return
            }
            block = true
            let ref = aligns.count > 1 ? aligns[1] : aligns[0]
            let al = (0 ..< cols).map { $0 < ref.count ? ref[$0] : .left }
            w.ensureBreak(2)
            w.raw(MarkdownTable.render(rows: rows, aligns: al))
            w.ensureBreak(2)
        }

        // MARK: 收尾

        /// 去掉行尾空格、多余的空行、孤零零的列表 / 标题符号（代码块里不动）
        func finish(_ s: String) -> String {
            var lines: [String] = []
            var inFence = false
            var blank = 0
            for raw in s.components(separatedBy: "\n") {
                if raw.hasPrefix("```") {
                    inFence.toggle()
                    blank = 0
                    lines.append(raw)
                    continue
                }
                if inFence { lines.append(raw); continue }
                var l = raw
                while l.hasSuffix(" ") { l.removeLast() }
                if Self.emptyMarker.contains(in: l) { continue }
                if l.isEmpty {
                    blank += 1
                    if blank > 1 || lines.isEmpty { continue }
                } else {
                    blank = 0
                }
                lines.append(l)
            }
            while lines.last?.isEmpty == true { lines.removeLast() }
            return lines.joined(separator: "\n")
        }
    }
}
