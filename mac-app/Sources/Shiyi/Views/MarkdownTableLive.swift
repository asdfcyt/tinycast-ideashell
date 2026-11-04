import AppKit

/*
 * 便签里的表格：写在文字里的是 Markdown（| a | b | + | --- | --- |），光标不在表格里时，
 * 把这几行文字折叠成一条细线，在第一行的位置直接画出真正的表格（列宽自适应、单元格自动换行、表头底色、对齐方式）；
 * 光标进入表格（或点一下表格）就展开成原文，方便改，离开又变回表格。
 * 文字本身一个字都没改，复制 / 保存拿到的还是 Markdown。
 */

/// 一个渲染好的表格：lines 是原文每一行的范围（不含换行）：[0] 表头，[1] 分隔行，其余是数据行
struct LiveTable {
    var lines: [NSRange]
    var layout: LiveTableLayout
}

/// 表格的排版结果（缓存用）：每列宽度、每行高度和每个单元格的文字
final class LiveTableLayout {
    static let padX: CGFloat = 8
    static let padY: CGFloat = 4
    /// 表格下面留一点空隙
    static let gap: CGFloat = 8

    /// 行 × 列，第 0 行是表头（不含分隔行）
    let cells: [[NSAttributedString]]
    let colWidths: [CGFloat]
    let rowHeights: [CGFloat]
    var width: CGFloat { colWidths.reduce(0, +) }
    var height: CGFloat { rowHeights.reduce(0, +) }

    private static let inlinePatterns = ["\\*\\*(.+?)\\*\\*", "__(.+?)__", "~~(.+?)~~", "`([^`]+)`", "\\[([^\\]]+)\\]\\([^)]*\\)"]

    /// 去掉单元格里的行内 Markdown 符号（加粗 / 删除线 / 代码 / 链接），只留文字
    static func plain(_ s: String) -> String {
        var t = s
        for p in inlinePatterns { t = t.replacingOccurrences(of: p, with: "$1", options: .regularExpression) }
        return t.trimmingCharacters(in: .whitespaces)
    }

    init(rows: [[String]], aligns: [MarkdownTable.Align], fontSize: CGFloat, maxWidth: CGFloat) {
        let n = max(rows.map { $0.count }.max() ?? 1, 1)
        var all: [[NSAttributedString]] = []
        for (ri, r) in rows.enumerated() {
            var line: [NSAttributedString] = []
            for c in 0 ..< n {
                let al = c < aligns.count ? aligns[c] : .left
                let ps = NSMutableParagraphStyle()
                ps.alignment = al == .right ? .right : (al == .center ? .center : .left)
                ps.lineBreakMode = .byWordWrapping
                ps.lineSpacing = 1
                let font = NSFont.systemFont(ofSize: fontSize, weight: ri == 0 ? .semibold : .regular)
                line.append(NSAttributedString(
                    string: Self.plain(c < r.count ? r[c] : ""),
                    attributes: [.font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: ps]
                ))
            }
            all.append(line)
        }
        cells = all

        // 每列：自然宽度（一行写完）和最小宽度（再窄就太难看）
        var nat = [CGFloat](repeating: 0, count: n)
        var mins = [CGFloat](repeating: 0, count: n)
        for row in all {
            for (c, a) in row.enumerated() {
                let w = ceil(a.size().width) + 2
                nat[c] = max(nat[c], w)
                var token: CGFloat = 0
                for word in a.string.split(separator: " ") {
                    let ww = ceil(NSAttributedString(string: String(word), attributes: [.font: a.attribute(.font, at: 0, effectiveRange: nil) ?? NSFont.systemFont(ofSize: fontSize)]).size().width) + 2
                    token = max(token, ww)
                }
                mins[c] = max(mins[c], min(w, min(token == 0 ? w : token, fontSize * 5)))
            }
        }
        let avail = max(maxWidth - CGFloat(n) * 2 * Self.padX, CGFloat(n) * 14)
        let natSum = nat.reduce(0, +), minSum = mins.reduce(0, +)
        var content: [CGFloat]
        if natSum <= avail {
            content = nat
        } else if avail <= minSum || natSum <= minSum {
            content = mins
        } else {
            let k = (avail - minSum) / (natSum - minSum)
            content = (0 ..< n).map { mins[$0] + (nat[$0] - mins[$0]) * k }
        }
        colWidths = content.map { floor($0) + 2 * Self.padX }

        var heights: [CGFloat] = []
        for row in all {
            var h: CGFloat = 0
            for (c, a) in row.enumerated() {
                let box = a.boundingRect(
                    with: NSSize(width: colWidths[c] - 2 * Self.padX, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading]
                )
                h = max(h, ceil(box.height))
            }
            heights.append(max(h, ceil(fontSize * 1.2)) + 2 * Self.padY)
        }
        rowHeights = heights
    }

    /// 画在 origin（左上角，视图是翻转坐标）
    func draw(at origin: NSPoint) {
        let w = width, h = height
        let frame = NSRect(x: origin.x + 0.5, y: origin.y + 0.5, width: w - 1, height: h - 1)
        let outline = NSBezierPath(roundedRect: frame, xRadius: 6, yRadius: 6)
        NSGraphicsContext.saveGraphicsState()
        outline.addClip()
        NSColor.labelColor.withAlphaComponent(0.07).setFill()
        NSRect(x: origin.x, y: origin.y, width: w, height: rowHeights[0]).fill()
        NSColor.separatorColor.setFill()
        var y = origin.y
        for (i, rh) in rowHeights.enumerated() {
            y += rh
            if i < rowHeights.count - 1 { NSRect(x: origin.x, y: y - 0.25, width: w, height: 0.5).fill() }
        }
        var x = origin.x
        for (i, cw) in colWidths.enumerated() {
            x += cw
            if i < colWidths.count - 1 { NSRect(x: x - 0.25, y: origin.y, width: 0.5, height: h).fill() }
        }
        NSGraphicsContext.restoreGraphicsState()
        NSColor.separatorColor.setStroke()
        outline.lineWidth = 0.5
        outline.stroke()

        y = origin.y
        for (ri, row) in cells.enumerated() {
            x = origin.x
            for (ci, a) in row.enumerated() {
                let box = NSRect(x: x + Self.padX, y: y + Self.padY, width: colWidths[ci] - 2 * Self.padX, height: rowHeights[ri] - 2 * Self.padY)
                a.draw(with: box, options: [.usesLineFragmentOrigin, .usesFontLeading])
                x += colWidths[ci]
            }
            y += rowHeights[ri]
        }
    }
}

// MARK: - 找表格 / 画 / 点击

extension ComposerNSTextView {
    struct TableBlock {
        var lines: [NSRange]
        /// 每一行连换行符的范围
        var enclosing: [NSRange]
        var rows: [[String]]
        var aligns: [MarkdownTable.Align]
    }

    /// 文字里所有的 Markdown 表格（| 开头的连续几行，第二行是分隔行；代码块里的不算）
    func findTableBlocks(_ ns: NSString) -> [TableBlock] {
        var out: [TableBlock] = []
        var run: [(line: NSRange, enc: NSRange, text: String)] = []
        var inFence = false
        func flush() {
            defer { run = [] }
            guard run.count >= 2, let aligns = MarkdownTable.aligns(ofSeparator: MarkdownTable.cells(run[1].text)) else { return }
            var rows = [MarkdownTable.cells(run[0].text)]
            for r in run.dropFirst(2) { rows.append(MarkdownTable.cells(r.text)) }
            out.append(TableBlock(lines: run.map { $0.line }, enclosing: run.map { $0.enc }, rows: rows, aligns: aligns))
        }
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.byLines, .substringNotRequired]) { _, line, enc, _ in
            let text = ns.substring(with: line)
            if text.trimmingCharacters(in: .whitespaces).hasPrefix("```") { flush(); inFence.toggle(); return }
            if inFence { return }
            if MarkdownTable.isRow(text) { run.append((line, enc, text)) } else { flush() }
        }
        flush()
        return out
    }

    /// 排版（按内容 + 宽度缓存）
    func tableLayout(for block: TableBlock, ns: NSString) -> LiveTableLayout {
        let width = min(max((textContainer?.size.width ?? 300) - 2, 120), 1600)
        let key = "\(Int(width))|\(baseFont.pointSize)|" + block.lines.map { ns.substring(with: $0) }.joined(separator: "\n")
        if let hit = tableCache[key] { return hit }
        if tableCache.count > 40 { tableCache.removeAll() }
        let l = LiveTableLayout(rows: block.rows, aligns: block.aligns, fontSize: max(baseFont.pointSize - 0.5, 11), maxWidth: width)
        tableCache[key] = l
        return l
    }

    /// 表格左上角在视图里的位置（第一行折叠行的位置）
    private func tableOrigin(_ t: LiveTable) -> NSPoint? {
        guard let lm = layoutManager, let first = t.lines.first, first.location < (string as NSString).length else { return nil }
        let g = lm.glyphIndexForCharacter(at: first.location)
        let r = lm.lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
        let o = textContainerOrigin
        return NSPoint(x: o.x + r.minX, y: o.y + r.minY)
    }

    func drawLiveTables(_ dirty: NSRect) {
        guard markdownStyle, !liveTables.isEmpty else { return }
        for t in liveTables {
            guard let o = tableOrigin(t) else { continue }
            let rect = NSRect(x: o.x, y: o.y, width: t.layout.width, height: t.layout.height)
            if rect.intersects(dirty) { t.layout.draw(at: o) }
        }
    }

    /// 点在渲染好的表格上：把光标放到点中那一行的末尾（表格随即展开成原文）。返回是否处理了
    func expandTableIfClicked(_ event: NSEvent) -> Bool {
        guard markdownStyle, !liveTables.isEmpty, !hasMarkedText() else { return false }
        let p = convert(event.locationInWindow, from: nil)
        let ns = string as NSString
        for t in liveTables {
            guard let o = tableOrigin(t) else { continue }
            let rect = NSRect(x: o.x, y: o.y, width: t.layout.width, height: t.layout.height)
            guard rect.contains(p) else { continue }
            var y = o.y
            var row = 0
            for (i, h) in t.layout.rowHeights.enumerated() {
                if p.y < y + h { row = i; break }
                y += h
                row = i
            }
            let idx = row == 0 ? 0 : row + 1
            guard idx < t.lines.count, NSMaxRange(t.lines[idx]) <= ns.length else { return false }
            let r = t.lines[idx]
            var s = ns.substring(with: r)
            while s.hasSuffix(" ") { s.removeLast() }
            if s.hasSuffix("|") { s.removeLast() }
            while s.hasSuffix(" ") { s.removeLast() }
            window?.makeFirstResponder(self)
            setSelectedRange(NSRange(location: r.location + (s as NSString).length, length: 0))
            return true
        }
        return false
    }
}
