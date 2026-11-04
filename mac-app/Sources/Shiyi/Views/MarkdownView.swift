import SwiftUI

/// 轻量 Markdown 渲染：标题 / 列表 / 待办勾选 / 引用 / 代码块 / 分割线 + 行内格式（加粗、斜体、代码、链接）
struct MarkdownView: View {
    let text: String

    private enum Block {
        case heading(Int, String)
        case bullet(Int, String)
        case ordered(Int, String, String)
        case check(Bool, String)
        case quote(String)
        case code(String)
        case rule
        case para(String)
        case table([String], [[String]], [MarkdownTable.Align])
    }

    private static let reHeading = RX(#"^(#{1,6})\s+(.*)$"#, multiline: false)
    private static let reRule = RX(#"^\s*(-{3,}|\*{3,}|_{3,})\s*$"#, multiline: false)
    private static let reCheck = RX(#"^\s*[-*+]\s+\[( |x|X)\]\s+(.*)$"#, multiline: false)
    private static let reBullet = RX(#"^(\s*)[-*+]\s+(.*)$"#, multiline: false)
    private static let reOrdered = RX(#"^(\s*)(\d+)[.)]\s+(.*)$"#, multiline: false)
    private static let reQuote = RX(#"^>\s?(.*)$"#, multiline: false)
    private static let reImageLine = RX(#"^\s*!\[[^\]]*\]\([^)]*\)\s*$"#, multiline: false)

    private var blocks: [Block] {
        var out: [Block] = []
        var inCode = false
        var code: [String] = []
        var tableLines: [String] = []
        /// 连续的 | 开头的行：第二行是 | --- | 分隔行才算表格，否则按普通文字
        func flushTable() {
            guard !tableLines.isEmpty else { return }
            defer { tableLines = [] }
            let rows = tableLines.map { MarkdownTable.cells($0) }
            if rows.count >= 2, let aligns = MarkdownTable.aligns(ofSeparator: rows[1]) {
                out.append(.table(rows[0], Array(rows.dropFirst(2)), aligns))
            } else {
                for l in tableLines { out.append(.para(l)) }
            }
        }
        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            if raw.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                flushTable()
                if inCode { out.append(.code(code.joined(separator: "\n"))); code = [] }
                inCode.toggle()
                continue
            }
            if inCode { code.append(raw); continue }
            if MarkdownTable.isRow(raw) { tableLines.append(raw); continue }
            flushTable()
            if raw.trimmed.isEmpty || Self.reImageLine.contains(in: raw) { continue }
            if let m = Self.reHeading.first(in: raw) { out.append(.heading(m.group(1).count, m.group(2))) }
            else if Self.reRule.contains(in: raw) { out.append(.rule) }
            else if let m = Self.reCheck.first(in: raw) { out.append(.check(m.group(1) != " ", m.group(2))) }
            else if let m = Self.reBullet.first(in: raw) { out.append(.bullet(m.group(1).count / 2, m.group(2))) }
            else if let m = Self.reOrdered.first(in: raw) { out.append(.ordered(m.group(1).count / 2, m.group(2), m.group(3))) }
            else if let m = Self.reQuote.first(in: raw) { out.append(.quote(m.group(1))) }
            else { out.append(.para(raw)) }
        }
        flushTable()
        if inCode, !code.isEmpty { out.append(.code(code.joined(separator: "\n"))) }
        return out
    }

    private func inline(_ s: String) -> Text {
        let opts = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        if let a = try? AttributedString(markdown: s, options: opts) { return Text(a) }
        return Text(s)
    }

    private func cellAlignment(_ aligns: [MarkdownTable.Align], _ i: Int) -> Alignment {
        guard i < aligns.count else { return .leading }
        switch aligns[i] {
        case .left: return .leading
        case .center: return .center
        case .right: return .trailing
        }
    }

    private func tableView(_ head: [String], _ body: [[String]], _ aligns: [MarkdownTable.Align]) -> some View {
        let cols = max(head.count, body.map { $0.count }.max() ?? 0, 1)
        return ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(0 ..< cols, id: \.self) { i in
                        inline(i < head.count ? head[i] : "").font(.system(size: 12.5, weight: .semibold))
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .frame(maxWidth: .infinity, alignment: cellAlignment(aligns, i))
                            .background(Color.primary.opacity(0.07))
                    }
                }
                ForEach(Array(body.enumerated()), id: \.offset) { _, r in
                    Divider().gridCellColumns(cols).opacity(0.5)
                    GridRow {
                        ForEach(0 ..< cols, id: \.self) { i in
                            inline(i < r.count ? r[i] : "").font(.system(size: 12.5))
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .frame(maxWidth: .infinity, alignment: cellAlignment(aligns, i))
                        }
                    }
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Color.primary.opacity(0.14), lineWidth: 0.5))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case let .heading(level, s):
                    inline(s)
                        .font(level == 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline)
                        .padding(.top, level <= 2 ? 6 : 2)
                case let .bullet(indent, s):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(.secondary)
                        inline(s)
                    }
                    .padding(.leading, CGFloat(indent) * 16)
                case let .ordered(indent, n, s):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(n).").foregroundStyle(.secondary).monospacedDigit()
                        inline(s)
                    }
                    .padding(.leading, CGFloat(indent) * 16)
                case let .check(done, s):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: done ? "checkmark.square.fill" : "square").foregroundStyle(done ? Color.green : .secondary)
                        inline(s).strikethrough(done).foregroundStyle(done ? .secondary : .primary)
                    }
                case let .quote(s):
                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 1.5).fill(Brand.orange.opacity(0.5)).frame(width: 3)
                        inline(s).foregroundStyle(.secondary)
                    }
                case let .code(s):
                    Text(s)
                        .font(.system(.callout, design: .monospaced))
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                case .rule:
                    Divider().padding(.vertical, 4)
                case let .para(s):
                    inline(s)
                case let .table(head, body, aligns):
                    tableView(head, body, aligns)
                }
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
