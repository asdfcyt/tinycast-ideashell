import Foundation

/// 万能输入框里的计算器结果
struct CalcResult: Equatable {
    /// 规整后的算式（全角换半角、× ÷ 换成 * /）
    let expression: String
    let value: Double
    /// 带千分位的显示文字
    let display: String
    /// 复制用的纯数字（不带千分位）
    let plain: String
}

/// 自己写的递归下降算式解析：不用 NSExpression（输入不合法时它会抛 ObjC 异常直接崩）。
/// 支持 + - * / ^ ( )、百分号（`200*15%`、`100+10%` = 110）、常量 pi / e、常用函数（sqrt abs round floor ceil sin cos tan asin acos atan ln log exp）。
enum Calculator {
    /// 能算出来就返回结果；只是一个数字、含有别的文字、算不出来（除以 0 等）都返回 nil。
    /// 开头写 `=` 表示强制当算式（否则像 `1-2`、`3/4` 这种日期样子的不算）。
    static func evaluate(_ raw: String) -> CalcResult? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, s.count <= 120, !s.contains("\n") else { return nil }
        var forced = false
        if s.hasPrefix("=") || s.hasPrefix("＝") { forced = true; s.removeFirst() }
        if s.hasSuffix("=") || s.hasSuffix("＝") { forced = true; s.removeLast() }
        s = normalize(s)
        guard !s.isEmpty else { return nil }
        // 日期 / 版本号样子（2024-05-01、5/12、1.2.3）不当算式
        if !forced, s.range(of: #"^\d{1,4}[-/.]\d{1,2}([-/.]\d{1,4})?$"#, options: .regularExpression) != nil { return nil }

        var p = Parser(Array(s))
        guard let v = p.parseAll(), p.usedOperator, v.isFinite, abs(v) < 1e300 else { return nil }
        let (display, plain) = format(v)
        return CalcResult(expression: s, value: v, display: display, plain: plain)
    }

    private static func normalize(_ s: String) -> String {
        var t = s.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? s
        t = t.replacingOccurrences(of: "×", with: "*").replacingOccurrences(of: "÷", with: "/")
            .replacingOccurrences(of: "−", with: "-").replacingOccurrences(of: "π", with: "pi")
            .replacingOccurrences(of: "。", with: ".")
        // 千分位逗号：1,234,567 → 1234567
        t = t.replacingOccurrences(of: #"(?<=\d),(?=\d{3}(\D|$))"#, with: "", options: .regularExpression)
        return t.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "\t", with: "")
    }

    private static func format(_ v: Double) -> (display: String, plain: String) {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.numberStyle = .decimal
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = 10
        if abs(v) >= 1e15 || (abs(v) < 1e-9 && v != 0) {
            let e = String(format: "%.8g", v)
            return (e, e)
        }
        f.usesGroupingSeparator = true
        f.groupingSeparator = ","
        let display = f.string(from: NSNumber(value: v)) ?? String(v)
        f.usesGroupingSeparator = false
        let plain = f.string(from: NSNumber(value: v)) ?? String(v)
        return (display == "-0" ? "0" : display, plain == "-0" ? "0" : plain)
    }

    // MARK: - 解析

    private struct Parser {
        let c: [Character]
        var i = 0
        /// 用到过运算符 / 函数 / 百分号（光是一个数字不算算式）
        var usedOperator = false
        init(_ chars: [Character]) { c = chars }

        mutating func parseAll() -> Double? {
            guard let v = expr()?.value, i == c.count else { return nil }
            return v
        }

        private func peek() -> Character? { i < c.count ? c[i] : nil }

        /// value + 是不是一个「百分数」（`10%`）：加减时按左边的数取百分比
        private typealias Val = (value: Double, percent: Bool)

        private mutating func expr() -> Val? {
            guard var left = term() else { return nil }
            while let ch = peek(), ch == "+" || ch == "-" {
                i += 1
                usedOperator = true
                guard let right = term() else { return nil }
                let r = right.percent ? left.value * right.value : right.value
                left = (ch == "+" ? left.value + r : left.value - r, false)
            }
            return left
        }

        private mutating func term() -> Val? {
            guard var left = power() else { return nil }
            while let ch = peek() {
                if ch == "*" || ch == "/" {
                    i += 1
                    usedOperator = true
                    guard let right = power() else { return nil }
                    if ch == "/" {
                        guard right.value != 0 else { return nil }
                        left = (left.value / right.value, false)
                    } else {
                        left = (left.value * right.value, false)
                    }
                } else if ch == "(" {
                    // 隐式乘法：2(3+4)
                    guard let right = power() else { return nil }
                    usedOperator = true
                    left = (left.value * right.value, false)
                } else { break }
            }
            return left
        }

        private mutating func power() -> Val? {
            guard let base = unary() else { return nil }
            if peek() == "^" {
                i += 1
                usedOperator = true
                guard let exp = power() else { return nil }   // 右结合
                let r = pow(base.value, exp.value)
                return r.isFinite ? (r, false) : nil
            }
            return base
        }

        private mutating func unary() -> Val? {
            if let ch = peek(), ch == "-" || ch == "+" {
                i += 1
                guard let v = unary() else { return nil }
                return (ch == "-" ? -v.value : v.value, v.percent)
            }
            return postfix()
        }

        private mutating func postfix() -> Val? {
            guard var v = primary() else { return nil }
            while peek() == "%" {
                i += 1
                usedOperator = true
                v = (v.value / 100, true)
            }
            return v
        }

        private mutating func primary() -> Val? {
            guard let ch = peek() else { return nil }
            if ch == "(" {
                i += 1
                guard let v = expr(), peek() == ")" else { return nil }
                i += 1
                return (v.value, false)
            }
            if ch.isNumber || ch == "." { return number().map { ($0, false) } }
            if ch.isLetter {
                var name = ""
                while let l = peek(), l.isLetter { name.append(l); i += 1 }
                name = name.lowercased()
                if name == "pi" { return (Double.pi, false) }
                if name == "e" { return (M_E, false) }
                guard peek() == "(" else { return nil }
                i += 1
                guard let arg = expr(), peek() == ")" else { return nil }
                i += 1
                usedOperator = true
                guard let r = apply(name, arg.value), r.isFinite else { return nil }
                return (r, false)
            }
            return nil
        }

        private mutating func number() -> Double? {
            var s = ""
            var dot = false
            while let ch = peek(), ch.isASCII, ch.isNumber || ch == "." {
                if ch == "." { if dot { return nil }; dot = true }
                s.append(ch)
                i += 1
            }
            return Double(s)
        }

        private func apply(_ f: String, _ x: Double) -> Double? {
            switch f {
            case "sqrt": return x >= 0 ? sqrt(x) : nil
            case "abs": return abs(x)
            case "round": return x.rounded()
            case "floor": return floor(x)
            case "ceil": return ceil(x)
            case "sin": return sin(x)
            case "cos": return cos(x)
            case "tan": return tan(x)
            case "asin": return asin(x)
            case "acos": return acos(x)
            case "atan": return atan(x)
            case "ln": return x > 0 ? log(x) : nil
            case "log": return x > 0 ? log10(x) : nil
            case "exp": return exp(x)
            default: return nil
            }
        }
    }
}
