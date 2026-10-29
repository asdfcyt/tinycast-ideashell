import AppKit

/*
 * 便签的「边写边预览」：不换视图，直接在输入框里给 Markdown 上样式。
 * 标题放大加粗、**粗体** / *斜体* / ~~删除线~~ / `代码` / [链接](…) 当场生效，列表 / 引用悬挂缩进，
 * 已勾选的清单划掉变灰；符号本身保留但变淡，光标在哪都能直接改。
 * - 点 `[ ]` / `[x]` 方框直接勾选（改回原文）
 * - 在列表 / 清单 / 有序列表末尾回车会自动续上下一项，空项回车就退出列表
 * - 光标所在的行显示 Markdown 符号（淡色，方便改）；其它行 / 输入框没有焦点时符号隐藏，看到的就是渲染后的样子
 * 只改字的属性、不改内容；输入法候选（marked text）期间不动，避免打断拼音 / 五笔。
 */

private func re(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p, options: []) }

private enum MD {
    static let heading = re("^(#{1,6})([ \\t]+)")
    static let quote = re("^([ \\t]*>+[ \\t]?)")
    static let task = re("^([ \\t]*)([-*+])([ \\t]+)(\\[([ xX])\\])([ \\t]+|$)")
    static let bullet = re("^([ \\t]*)([-*+])([ \\t]+)")
    static let ordered = re("^([ \\t]*)(\\d{1,3})([.、])([ \\t]+)")
    static let rule = re("^[ \\t]*([-*_])(?:[ \\t]*\\1){2,}[ \\t]*$")
    static let bold = re("(\\*\\*|__)(?=\\S)(.+?)(?<=\\S)\\1")
    static let italic = re("(?<![\\*\\w])\\*(?=[^\\s*])(.+?)(?<=[^\\s*])\\*(?![\\*\\w])")
    static let strike = re("(~~)(?=\\S)(.+?)(?<=\\S)~~")
    static let code = re("(`+)([^`\\n]+?)\\1")
    static let link = re("(\\[)([^\\]\\n]+)(\\]\\()([^)\\n\\s]+)(\\))")

    static let accent = NSColor(srgbRed: 0.76, green: 0.40, blue: 0.06, alpha: 1)
    static let dim = NSColor.tertiaryLabelColor
}

extension ComposerNSTextView {
    // MARK: 上样式

    func restyle() {
        guard markdownStyle else { return }
        let font0 = baseFont
        let baseSize = font0.pointSize
        let para = NSMutableParagraphStyle()
        para.lineSpacing = 2.5
        let base: [NSAttributedString.Key: Any] = [.font: font0, .foregroundColor: NSColor.labelColor, .paragraphStyle: para]
        defer { typingAttributes = base }
        guard let ts = textStorage, ts.length > 0, !hasMarkedText() else { return }

        let ns = ts.string as NSString
        let full = NSRange(location: 0, length: ns.length)
        let mono = NSFont.monospacedSystemFont(ofSize: baseSize - 1, weight: .regular)
        let fm = NSFontManager.shared
        let sel = selectedRange()
        let focused = window?.firstResponder === self

        ts.beginEditing()
        ts.addAttributes(base, range: full)
        for k in [NSAttributedString.Key.strikethroughStyle, .backgroundColor, .underlineStyle, .obliqueness] {
            ts.removeAttribute(k, range: full)
        }

        func color(_ r: NSRange, _ c: NSColor) { if r.length > 0 { ts.addAttribute(.foregroundColor, value: c, range: r) } }
        func at(_ r: NSRange, in line: NSRange) -> NSRange { NSRange(location: line.location + r.location, length: r.length) }
        func hide(_ r: NSRange) {
            if r.length > 0 { ts.addAttributes([.font: NSFont.systemFont(ofSize: 0.1), .foregroundColor: NSColor.clear], range: r) }
        }
        func bold(_ r: NSRange) {
            ts.enumerateAttribute(.font, in: r) { v, sub, _ in
                if let f = v as? NSFont { ts.addAttribute(.font, value: fm.convert(f, toHaveTrait: .boldFontMask), range: sub) }
            }
        }

        var inFence = false
        ns.enumerateSubstrings(in: full, options: [.byLines, .substringNotRequired]) { _, line, _, _ in
            let text = ns.substring(with: line)
            let l = NSRange(location: 0, length: line.length)
            // 光标 / 选区碰到这一行：显示符号；否则隐藏
            let active = focused && (sel.location >= line.location && sel.location <= line.location + line.length
                || (sel.length > 0 && NSIntersectionRange(line, sel).length > 0))
            func syntax(_ r: NSRange) { if active { color(r, MD.dim) } else { hide(r) } }

            // 代码块
            if text.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                inFence.toggle()
                ts.addAttributes([.font: mono, .foregroundColor: MD.dim], range: line)
                return
            }
            if inFence {
                ts.addAttributes([.font: mono, .backgroundColor: NSColor.black.withAlphaComponent(0.07)], range: line)
                return
            }
            if MD.rule.firstMatch(in: text, range: l) != nil {
                color(line, MD.dim)
                return
            }

            // 块级
            var inlineStart = 0
            var hang: CGFloat?       // 悬挂缩进的宽度（换行后和正文对齐）
            if let m = MD.heading.firstMatch(in: text, range: l) {
                let level = m.range(at: 1).length
                let size: CGFloat = [baseSize + 6, baseSize + 3.5, baseSize + 1.5, baseSize + 0.5, baseSize, baseSize][level - 1]
                ts.addAttribute(.font, value: NSFont.systemFont(ofSize: size, weight: .bold), range: line)
                syntax(at(NSRange(location: 0, length: m.range.length), in: line))
                inlineStart = m.range.length
            } else if let m = MD.quote.firstMatch(in: text, range: l) {
                color(at(m.range, in: line), MD.dim)
                color(NSRange(location: line.location + m.range.length, length: line.length - m.range.length), .secondaryLabelColor)
                hang = (text as NSString).substring(to: m.range.length).size(withAttributes: [.font: font0]).width
                inlineStart = m.range.length
            } else if let m = MD.task.firstMatch(in: text, range: l) {
                let box = at(m.range(at: 4), in: line)
                let done = (text as NSString).substring(with: m.range(at: 5)).lowercased() == "x"
                color(at(m.range(at: 2), in: line), MD.dim)
                color(box, done ? NSColor.secondaryLabelColor : MD.accent)
                ts.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: baseSize, weight: .semibold), range: box)
                let rest = NSRange(location: line.location + m.range.length, length: max(line.length - m.range.length, 0))
                if done, rest.length > 0 {
                    ts.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: rest)
                    color(rest, .secondaryLabelColor)
                }
                hang = (text as NSString).substring(to: m.range.length).size(withAttributes: [.font: font0]).width
                inlineStart = m.range.length
            } else if let m = MD.bullet.firstMatch(in: text, range: l) {
                color(at(m.range(at: 2), in: line), MD.accent)
                hang = (text as NSString).substring(to: m.range.length).size(withAttributes: [.font: font0]).width
                inlineStart = m.range.length
            } else if let m = MD.ordered.firstMatch(in: text, range: l) {
                let num = NSRange(location: m.range(at: 2).location, length: m.range(at: 2).length + m.range(at: 3).length)
                color(at(num, in: line), MD.accent)
                hang = (text as NSString).substring(to: m.range.length).size(withAttributes: [.font: font0]).width
                inlineStart = m.range.length
            }
            if let hang {
                let p = para.mutableCopy() as! NSMutableParagraphStyle
                p.headIndent = hang
                ts.addAttribute(.paragraphStyle, value: p, range: line)
            }

            // 行内（从正文开始算，不碰前面的列表符号）
            let body = NSRange(location: inlineStart, length: max(line.length - inlineStart, 0))
            guard body.length > 0 else { return }

            for m in MD.bold.matches(in: text, range: body) {
                let r = at(m.range, in: line)
                bold(r)
                syntax(at(m.range(at: 1), in: line))
                syntax(NSRange(location: r.location + r.length - m.range(at: 1).length, length: m.range(at: 1).length))
            }
            for m in MD.italic.matches(in: text, range: body) {
                let r = at(m.range, in: line)
                ts.addAttribute(.obliqueness, value: 0.2, range: r)
                syntax(NSRange(location: r.location, length: 1))
                syntax(NSRange(location: r.location + r.length - 1, length: 1))
            }
            for m in MD.strike.matches(in: text, range: body) {
                let r = at(m.range, in: line)
                ts.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: r)
                color(at(m.range(at: 2), in: line), .secondaryLabelColor)
                syntax(NSRange(location: r.location, length: 2))
                syntax(NSRange(location: r.location + r.length - 2, length: 2))
            }
            for m in MD.link.matches(in: text, range: body) {
                color(at(m.range(at: 2), in: line), .linkColor)
                ts.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: at(m.range(at: 2), in: line))
                for g in [1, 3, 4, 5] { syntax(at(m.range(at: g), in: line)) }
            }
            for m in MD.code.matches(in: text, range: body) {
                let r = at(m.range, in: line)
                ts.addAttributes([.font: mono, .backgroundColor: NSColor.black.withAlphaComponent(0.07)], range: r)
                let tick = m.range(at: 1).length
                syntax(NSRange(location: r.location, length: tick))
                syntax(NSRange(location: r.location + r.length - tick, length: tick))
            }
        }
        ts.endEditing()
    }

    // MARK: 点方框勾选

    /// 点在 `[ ]` / `[x]` 上：勾选 / 取消勾选。返回是否处理了这次点击
    func toggleTaskIfClicked(_ event: NSEvent) -> Bool {
        guard markdownStyle, !hasMarkedText() else { return false }
        let p = convert(event.locationInWindow, from: nil)
        let idx = characterIndexForInsertion(at: p)
        let ns = string as NSString
        guard idx != NSNotFound, idx <= ns.length else { return false }
        let line = ns.lineRange(for: NSRange(location: min(idx, max(ns.length - 1, 0)), length: 0))
        let text = ns.substring(with: line)
        guard let m = MD.task.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) else { return false }
        let box = NSRange(location: line.location + m.range(at: 4).location, length: m.range(at: 4).length)
        guard idx >= box.location, idx <= box.location + box.length else { return false }
        let done = ns.substring(with: m.range(at: 5).shifted(by: line.location)).lowercased() == "x"
        let mark = NSRange(location: box.location + 1, length: 1)
        if shouldChangeText(in: mark, replacementString: done ? " " : "x") {
            textStorage?.replaceCharacters(in: mark, with: done ? " " : "x")
            didChangeText()
        }
        return true
    }

    // MARK: 回车续列表

    /// 光标在列表项末尾按回车：续上下一项；空项回车就把符号去掉退出列表。返回是否处理了
    func continueList() -> Bool {
        guard markdownStyle, !hasMarkedText() else { return false }
        let sel = selectedRange()
        guard sel.length == 0 else { return false }
        let ns = string as NSString
        let lr = ns.lineRange(for: NSRange(location: sel.location, length: 0))
        let text = ns.substring(with: lr).trimmingCharacters(in: .newlines)
        let ln = text as NSString
        guard sel.location == lr.location + ln.length else { return false }
        let all = NSRange(location: 0, length: ln.length)

        var prefix = "", next = ""
        if let m = MD.task.firstMatch(in: text, range: all) {
            prefix = ln.substring(with: m.range)
            next = ln.substring(with: m.range(at: 1)) + ln.substring(with: m.range(at: 2)) + " [ ] "
        } else if let m = MD.bullet.firstMatch(in: text, range: all) {
            prefix = ln.substring(with: m.range)
            next = prefix
        } else if let m = MD.ordered.firstMatch(in: text, range: all) {
            prefix = ln.substring(with: m.range)
            let n = (Int(ln.substring(with: m.range(at: 2))) ?? 0) + 1
            next = ln.substring(with: m.range(at: 1)) + "\(n)" + ln.substring(with: m.range(at: 3)) + " "
        } else {
            return false
        }
        if ln.length <= (prefix as NSString).length || ln.substring(from: (prefix as NSString).length).trimmingCharacters(in: .whitespaces).isEmpty {
            // 空项：去掉符号，退出列表
            insertText("", replacementRange: NSRange(location: lr.location, length: ln.length))
        } else {
            insertText("\n" + next, replacementRange: sel)
        }
        return true
    }
}

private extension NSRange {
    func shifted(by n: Int) -> NSRange { NSRange(location: location + n, length: length) }
}
