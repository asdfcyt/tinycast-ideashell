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
        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            if raw.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if inCode { out.append(.code(code.joined(separator: "\n"))); code = [] }
                inCode.toggle()
                continue
            }
            if inCode { code.append(raw); continue }
            if raw.trimmed.isEmpty || Self.reImageLine.contains(in: raw) { continue }
            if let m = Self.reHeading.first(in: raw) { out.append(.heading(m.group(1).count, m.group(2))) }
            else if Self.reRule.contains(in: raw) { out.append(.rule) }
            else if let m = Self.reCheck.first(in: raw) { out.append(.check(m.group(1) != " ", m.group(2))) }
            else if let m = Self.reBullet.first(in: raw) { out.append(.bullet(m.group(1).count / 2, m.group(2))) }
            else if let m = Self.reOrdered.first(in: raw) { out.append(.ordered(m.group(1).count / 2, m.group(2), m.group(3))) }
            else if let m = Self.reQuote.first(in: raw) { out.append(.quote(m.group(1))) }
            else { out.append(.para(raw)) }
        }
        if inCode, !code.isEmpty { out.append(.code(code.joined(separator: "\n"))) }
        return out
    }

    private func inline(_ s: String) -> Text {
        let opts = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        if let a = try? AttributedString(markdown: s, options: opts) { return Text(a) }
        return Text(s)
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
                        RoundedRectangle(cornerRadius: 1.5).fill(Color.accentColor.opacity(0.5)).frame(width: 3)
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
                }
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
