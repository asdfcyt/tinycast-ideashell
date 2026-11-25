import Foundation

/*
 * 阅读页的《财新周刊》目录：期号列表和每一期的文章目录来自 weekly.caixin.com 的公开页面（不用登录，只有标题和导语）。
 * 正文不在这里取：点开文章后在阅读页里的内嵌浏览器加载，用你自己登录的财新账号阅读，这里不抓、不存任何正文。
 */

struct WeeklyIssue: Identifiable, Hashable {
    /// 总期号，例如 1231
    let no: Int
    let year: Int
    var title: String
    /// 例如「2026年11月16日出版」
    var date: String
    /// 例如「2026年第44期」
    var label: String
    var cover: URL?
    var url: URL
    var id: Int { no }
}

struct WeeklyArticle: Identifiable, Hashable {
    let url: URL
    let title: String
    let summary: String
    var id: String { url.absoluteString }
}

struct WeeklySection: Identifiable {
    let name: String
    var articles: [WeeklyArticle]
    var id: String { name }
}

@MainActor
final class WeeklyStore: ObservableObject {
    static let shared = WeeklyStore()

    @Published var issues: [WeeklyIssue] = []
    @Published var current: WeeklyIssue?
    @Published var sections: [WeeklySection] = []
    @Published var loading = false
    @Published var error: String?
    /// 读过的文章（按网址记在本机）
    @Published private(set) var read: Set<String>

    private var cache: [Int: [WeeklySection]] = [:]
    private static let readKey = "reader.readArticles"
    private static let home = URL(string: "https://weekly.caixin.com/")!
    private static let ua = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15"

    private init() {
        read = Set(UserDefaults.standard.stringArray(forKey: Self.readKey) ?? [])
    }

    func isRead(_ a: WeeklyArticle) -> Bool { read.contains(a.id) }

    func markRead(_ a: WeeklyArticle) {
        guard read.insert(a.id).inserted else { return }
        // 只留最近 2000 条，免得越记越大
        let list = Array(read)
        if list.count > 2000 { read = Set(list.suffix(2000)) }
        UserDefaults.standard.set(Array(read), forKey: Self.readKey)
    }

    // MARK: 取目录

    func loadIfNeeded() async {
        if issues.isEmpty { await reload() }
    }

    func reload() async {
        guard !loading else { return }
        loading = true
        error = nil
        defer { loading = false }
        do {
            let html = try await Self.fetch(Self.home)
            var list = Self.parseIssues(html)
            guard !list.isEmpty else { throw WeeklyError.parse }
            cache.removeAll()
            // 首页的期号列表比最新一期晚一拍：试着取下一期（已经出了就放在最前面）
            if let top = list.first, let next = await Self.probeNext(after: top) {
                cache[next.issue.no] = next.sections
                list.insert(next.issue, at: 0)
            }
            issues = list
            let keep = current.flatMap { c in list.first { $0.no == c.no } } ?? list[0]
            await select(keep)
        } catch {
            self.error = "读不到周刊目录：" + error.localizedDescription
        }
    }

    func select(_ issue: WeeklyIssue) async {
        current = issue
        if let hit = cache[issue.no] { sections = hit; return }
        loading = true
        error = nil
        defer { loading = false }
        do {
            let html = try await Self.fetch(issue.url)
            let s = Self.parseSections(html)
            guard !s.isEmpty else { throw WeeklyError.parse }
            cache[issue.no] = s
            if current?.no == issue.no { sections = s }
        } catch {
            if current?.no == issue.no { sections = [] }
            self.error = "读不到这一期的目录：" + error.localizedDescription
        }
    }

    enum WeeklyError: LocalizedError {
        case http(Int), parse
        var errorDescription: String? {
            switch self {
            case let .http(c): return "HTTP \(c)"
            case .parse: return "页面结构变了，认不出目录"
            }
        }
    }

    private static func fetch(_ url: URL) async throws -> String {
        var r = URLRequest(url: url, timeoutInterval: 20)
        r.setValue(ua, forHTTPHeaderField: "User-Agent")
        let (d, resp) = try await URLSession.shared.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw WeeklyError.http(code) }
        return String(decoding: d, as: UTF8.self)
    }

    // MARK: 解析

    private static func rx(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p, options: []) }

    private static let issueRE = rx(#"<li><a href="https://weekly\.caixin\.com/(\d{4})/cw(\d+)/"><img[^>]*?data-src="([^"]+)"[^>]*>\s*([^<]*?)\s*</a><br>([^<]*)<br>([^<]*)</li>"#)
    private static let yearNoRE = rx(#"年度期号:(\d+)"#)
    private static let itemRE = rx(#"class="reportTit">([^<]*)<span|class="magIntrotit"><span>([^<]*)</span>|<dt><a[^>]*?href="(https?://[^"]+)"[^>]*>([^<]*)</a></dt>\s*(?:<dd class="date">[^<]*</dd>\s*)?(?:<dd>([^<]*)</dd>)?|<p>\s*<a[^>]*?href="(https?://[^"]+)"[^>]*>([^<]*)</a>\s*</p>"#)
    private static let sourceRE = rx(#"本文来源于《财新周刊》\s*(\d{4})年第(\d+)期\s*出版日期：(\d{4})-(\d{2})-(\d{2})"#)
    private static let coverRE = rx(#"<div class="cover">\s*<img[^>]*?src="([^"]+)""#)

    private static func group(_ m: NSTextCheckingResult, _ i: Int, in s: NSString) -> String? {
        let r = m.range(at: i)
        return r.location == NSNotFound ? nil : s.substring(with: r)
    }

    private static func clean(_ s: String) -> String {
        var t = s
        for (a, b) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&nbsp;", " ")] {
            t = t.replacingOccurrences(of: a, with: b)
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func parseIssues(_ html: String) -> [WeeklyIssue] {
        let ns = html as NSString
        var out: [WeeklyIssue] = []
        var seen = Set<Int>()
        for m in issueRE.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            guard let y = group(m, 1, in: ns).flatMap(Int.init), let no = group(m, 2, in: ns).flatMap(Int.init), seen.insert(no).inserted,
                  let url = URL(string: "https://weekly.caixin.com/\(y)/cw\(no)/") else { continue }
            let tail = group(m, 6, in: ns) ?? ""
            var label = "\(y)年"
            if let t = yearNoRE.firstMatch(in: tail, range: NSRange(location: 0, length: (tail as NSString).length)),
               let n = group(t, 1, in: tail as NSString) { label += "第\(n)期" } else { label += "第\(no)号" }
            out.append(WeeklyIssue(no: no, year: y, title: clean(group(m, 4, in: ns) ?? ""), date: clean(group(m, 5, in: ns) ?? ""),
                                   label: label, cover: group(m, 3, in: ns).flatMap { URL(string: $0.hasPrefix("//") ? "https:" + $0 : $0) }, url: url))
        }
        return out.sorted { $0.no > $1.no }
    }

    static func parseSections(_ html: String) -> [WeeklySection] {
        let ns = html as NSString
        var out: [WeeklySection] = []
        var name = "文章"
        var seen = Set<String>()
        func add(_ url: String, _ title: String, _ summary: String) {
            let t = clean(title)
            guard !t.isEmpty, !t.hasPrefix("{{"), !name.hasPrefix("["), let u = URL(string: url), seen.insert(url).inserted else { return }
            let a = WeeklyArticle(url: u, title: t, summary: clean(summary))
            if let i = out.firstIndex(where: { $0.name == name }) { out[i].articles.append(a) } else { out.append(WeeklySection(name: name, articles: [a])) }
        }
        for m in itemRE.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            if let n = group(m, 1, in: ns) ?? group(m, 2, in: ns) {
                name = clean(n)
            } else if let u = group(m, 3, in: ns) {
                add(u, group(m, 4, in: ns) ?? "", group(m, 5, in: ns) ?? "")
            } else if let u = group(m, 6, in: ns) {
                add(u, group(m, 7, in: ns) ?? "", "")
            }
        }
        return out
    }

    /// 首页列表里最新一期的下一期：已经出了就返回（带目录），没出就是 nil
    private static func probeNext(after top: WeeklyIssue) async -> (issue: WeeklyIssue, sections: [WeeklySection])? {
        for y in [top.year, top.year + 1] {
            let no = top.no + 1
            guard let url = URL(string: "https://weekly.caixin.com/\(y)/cw\(no)/"), let html = try? await fetch(url) else { continue }
            let sections = parseSections(html)
            guard let first = sections.first?.articles.first else { continue }
            let ns = html as NSString
            var label = "\(y)年第\(no)号"
            var date = ""
            if let m = sourceRE.firstMatch(in: html, range: NSRange(location: 0, length: ns.length)) {
                label = "\(group(m, 1, in: ns) ?? "")年第\(group(m, 2, in: ns) ?? "")期"
                date = "\(group(m, 3, in: ns) ?? "")年\(group(m, 4, in: ns) ?? "")月\(group(m, 5, in: ns) ?? "")日出版"
            }
            let cover = coverRE.firstMatch(in: html, range: NSRange(location: 0, length: ns.length))
                .flatMap { group($0, 1, in: ns) }.flatMap { URL(string: $0.hasPrefix("//") ? "https:" + $0 : $0) }
            return (WeeklyIssue(no: no, year: y, title: first.title, date: date, label: label, cover: cover, url: url), sections)
        }
        return nil
    }
}
