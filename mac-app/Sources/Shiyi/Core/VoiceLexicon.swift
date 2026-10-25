import Foundation

/// 语音词库（对应安卓端 `Lexicon`）：热词（专有名词，识别时优先、也告诉大模型）+ 替换规则（总是被听错的词 → 正确写法）
struct LexiconData: Codable, Equatable {
    struct Rule: Codable, Equatable { var from: String; var to: String }
    var hotwords: [String] = []
    var replacements: [Rule] = []
}

@MainActor
final class VoiceLexicon: ObservableObject {
    static let shared = VoiceLexicon()

    @Published private(set) var data: LexiconData
    private static let file = "voice-lexicon.json"
    static let maxHotwords = 100
    private static let maxHotwordLen = 10

    private init() {
        data = LocalStore.read(Self.file)
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONDecoder().decode(LexiconData.self, from: $0) } ?? LexiconData()
    }

    func save(hotwords: [String], replacements: [(String, String)]) {
        var seen = Set<String>()
        let rules = replacements
            .map { ($0.0.trimmed, $0.1.trimmed) }
            .filter { !$0.0.isEmpty && $0.0 != $0.1 && seen.insert($0.0).inserted }
            .map { LexiconData.Rule(from: $0.0, to: $0.1) }
        var seenHot = Set<String>()
        let hot = hotwords.map(\.trimmed).filter { !$0.isEmpty && seenHot.insert($0).inserted }
        data = LexiconData(hotwords: hot, replacements: rules)
        if let d = try? JSONEncoder().encode(data), let s = String(data: d, encoding: .utf8) { LocalStore.write(Self.file, s) }
    }

    /// 纠错学习：同一个错字再记一次就覆盖旧的；正确写法是个像样的词，也顺手加进热词
    func addReplacement(from: String, to: String) {
        let f = from.trimmed, t = to.trimmed
        guard !f.isEmpty, !t.isEmpty, f != t else { return }
        let hot = (t.count >= 2 && t.count <= Self.maxHotwordLen && !data.hotwords.contains(t)) ? data.hotwords + [t] : data.hotwords
        let rules = data.replacements.filter { $0.from != f }.map { ($0.from, $0.to) } + [(f, t)]
        save(hotwords: hot, replacements: rules)
    }

    /// 从「预览里手改过的文字」学习：只有改动的那一小段是同音 / 近音错字才记（「京济学」→「经济学」），改了意思的不学。返回学到的（错, 对）
    @discardableResult
    func learnFromEdit(original: String, edited: String) -> (String, String)? {
        guard let pair = Correction.diff(original, edited) else { return nil }
        addReplacement(from: pair.0, to: pair.1)
        return pair
    }

    /// 按替换规则改一遍（长的先换，避免短词把长词拆坏）
    func apply(_ text: String) -> String {
        var out = text
        for r in data.replacements.sorted(by: { $0.from.count > $1.from.count }) where !r.from.isEmpty {
            out = out.replacingOccurrences(of: r.from, with: r.to)
        }
        return out
    }

    /// 热词 + 额外词，去重、过滤掉不适合当热词的，最多 maxHotwords 个
    func hotwords(extra: [String] = []) -> [String] {
        var seen = Set<String>()
        return (data.hotwords + extra).map(\.trimmed).filter(Self.isValidHotword).filter { seen.insert($0).inserted }.prefix(Self.maxHotwords).map { $0 }
    }

    /// 腾讯云热词只收文字和数字，2–10 个字
    static func isValidHotword(_ w: String) -> Bool {
        (2 ... maxHotwordLen).contains(w.count) && w.allSatisfy { $0.isLetter || $0.isNumber }
    }

    // MARK: 设置里的文本框 ↔ 数据

    static func parseHotwords(_ text: String) -> [String] {
        text.components(separatedBy: CharacterSet(charactersIn: "\n,，、;；")).map(\.trimmed).filter { !$0.isEmpty }
    }

    /// 每行一条：「错字=正确」，也认 → 和 ->
    static func parseReplacements(_ text: String) -> [(String, String)] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let s = String(line)
            for sep in ["->", "→", "=", "＝"] {
                if let r = s.range(of: sep) {
                    let a = String(s[..<r.lowerBound]).trimmed, b = String(s[r.upperBound...]).trimmed
                    return a.isEmpty || b.isEmpty ? nil : (a, b)
                }
            }
            return nil
        }
    }

    var hotwordsText: String { data.hotwords.joined(separator: "、") }
    var replacementsText: String { data.replacements.map { "\($0.from)=\($0.to)" }.joined(separator: "\n") }
}

/// 手改前后的差异 → 一对近音词（对应安卓端 `Correction`）
enum Correction {
    private static let maxSpan = 8
    private static let functionChars: Set<Character> = Set("的了是在和与吗吧呢啊就都也还把被给")

    static func diff(_ original: String, _ edited: String) -> (String, String)? {
        let o = Array(original), e = Array(edited)
        if original == edited || original.trimmed.isEmpty || edited.trimmed.isEmpty { return nil }
        var start = 0
        let minLen = min(o.count, e.count)
        while start < minLen && o[start] == e[start] { start += 1 }
        var endO = o.count, endE = e.count
        while endO > start && endE > start && o[endO - 1] == e[endE - 1] { endO -= 1; endE -= 1 }
        var from = Array(o[start ..< endO]), to = Array(e[start ..< endE])
        if from.isEmpty || to.isEmpty { return nil }   // 纯增删不是错字

        // 只改了一个字：向右（不行再向左）借邻字，凑成一个词
        var left = start, right = endO, rightE = endE, tries = 0
        while (from.count < 2 || to.count < 2) && tries < 3 {
            let canLeft = left > 0
            let canRight = right < o.count && rightE < e.count
            let leftGood = canLeft && !functionChars.contains(o[left - 1])
            let rightGood = canRight && !functionChars.contains(o[right])
            let goLeft: Bool
            if rightGood { goLeft = false } else if leftGood { goLeft = true } else if canRight { goLeft = false } else { goLeft = canLeft }
            if goLeft {
                left -= 1
                from.insert(o[left], at: 0)
                to.insert(e[left], at: 0)
            } else if canRight {
                from.append(o[right]); to.append(e[rightE])
                right += 1; rightE += 1
            } else { break }
            tries += 1
        }
        guard (2 ... maxSpan).contains(from.count), (2 ... maxSpan).contains(to.count) else { return nil }
        guard from.allSatisfy(isWordChar), to.allSatisfy(isWordChar), from.contains(where: isHan) else { return nil }
        let f = String(from), t = String(to)
        return soundsAlike(f, t) ? (f, t) : nil
    }

    private static func isHan(_ c: Character) -> Bool { c.unicodeScalars.first.map { (0x4E00 ... 0x9FFF).contains($0.value) } ?? false }
    private static func isWordChar(_ c: Character) -> Bool { isHan(c) || c.isLetter || c.isNumber }

    private static func pinyin(_ s: String) -> String {
        let latin = s.applyingTransform(.toLatin, reverse: false) ?? s
        let plain = latin.applyingTransform(.stripDiacritics, reverse: false) ?? latin
        return String(plain.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    /// 拼音（不带声调）相差不超过 30%（编辑距离）就算近音
    static func soundsAlike(_ a: String, _ b: String) -> Bool {
        let pa = Array(pinyin(a)), pb = Array(pinyin(b))
        if pa.isEmpty || pb.isEmpty { return false }
        return editDistance(pa, pb) <= max(pa.count, pb.count) * 3 / 10
    }

    private static func editDistance(_ a: [Character], _ b: [Character]) -> Int {
        var prev = Array(0 ... b.count)
        for i in 1 ... a.count {
            var cur = [Int](repeating: 0, count: b.count + 1)
            cur[0] = i
            for j in 1 ... b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return prev[b.count]
    }
}
