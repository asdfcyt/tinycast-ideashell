import Foundation
import JavaScriptCore

/*
 * 三联生活周刊（lifeweek.com.cn）：官网是服务端渲染，期号 / 目录写在页面的 window.__NUXT__ 里（公开的列表页）。
 * 这里只读这些公开的目录数据；文章正文属数字刊会员，在内嵌浏览器里用你自己的账号登录后由页面自己加载，不抓取、不保存正文。
 */

struct LWIssue: Identifiable, Hashable, Codable {
    let id: Int          // 期的 ID（/magazine/<id>）
    let no: Int          // 第几期（年内）
    let total: Int       // 总第几期
    let name: String     // 封面故事名
    let title: String
    let cover: URL?
    let date: String     // 11 月 23 日
    var label: String { "第\(no)期" }
}

struct LWArticle: Identifiable, Hashable, Codable {
    let id: Int
    let title: String
    let views: Int
    let url: URL
}

struct LWSection: Identifiable, Hashable, Codable {
    var id: String { name }
    let name: String
    let articles: [LWArticle]
}

@MainActor
final class LifeweekStore: ObservableObject {
    static let shared = LifeweekStore()

    @Published var issues: [LWIssue] = []
    @Published var current: LWIssue?
    @Published var sections: [LWSection] = []
    @Published var loading = false
    @Published var error: String?

    /// 已看过的目录落在本机：切换来源、重启应用都先用它，不再每次重拉；过了 18 小时才在后台悄悄更新
    private var restored = false
    private var fetched: Date?
    private var cache: [Int: [LWSection]] = [:]
    private static let file = "lifeweek.json"
    private static let staleAfter: TimeInterval = 18 * 3600

    private struct Disk: Codable {
        var issues: [LWIssue]
        var sections: [Int: [LWSection]]
        var current: Int?
        var fetched: Date?
    }
    private static let base = "https://www.lifeweek.com.cn"
    private static let ua = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15"

    func loadIfNeeded() async {
        if !restored {
            restored = true
            if let text = LocalStore.read(Self.file), let d = try? JSONDecoder().decode(Disk.self, from: Data(text.utf8)) {
                cache = d.sections
                fetched = d.fetched
                issues = d.issues
                if let id = d.current, let c = d.issues.first(where: { $0.id == id }) ?? d.issues.first {
                    current = c
                    sections = cache[c.id] ?? []
                }
            }
        }
        let stale = (fetched ?? .distantPast) < Date().addingTimeInterval(-Self.staleAfter)
        if issues.isEmpty || sections.isEmpty || stale { await reload() }
    }

    private func save() {
        let d = Disk(issues: issues, sections: cache, current: current?.id, fetched: fetched)
        if let data = try? JSONEncoder().encode(d), let text = String(data: data, encoding: .utf8) {
            LocalStore.write(Self.file, text)
        }
    }

    func reload() async {
        guard !loading else { return }
        loading = true
        error = nil
        defer { loading = false }
        do {
            // 期号档案：每期都有一篇「好东西」，它带着所属期的信息；/magazine 给最新一期
            async let archive = Self.nuxt("/articleList/28697")
            async let latest = Self.nuxt("/magazine")
            var list: [LWIssue] = []
            if let a = try? await archive, let arr = a["articleList"] as? [[String: Any]] {
                list = arr.compactMap { Self.issue(course: $0["course"] as? [String: Any]) }
            }
            if let l = try? await latest, let tabs = l["tabs"] as? [[String: Any]],
               let t = tabs.first(where: { ($0["name"] as? String) == "三联生活周刊" }) ?? tabs.first,
               let i = Self.issue(tab: t) {
                list.append(i)
            }
            var seen = Set<Int>()
            list = list.filter { seen.insert($0.id).inserted }.sorted { $0.total > $1.total }
            guard !list.isEmpty else { throw URLError(.cannotParseResponse) }
            issues = list
            fetched = Date()
            if let c = current, let same = list.first(where: { $0.id == c.id }) {
                await select(same, force: true)
            } else if let first = list.first {
                await select(first, force: true)
            }
            save()
        } catch {
            // 本机已有目录就不打扰，只在什么都没有时才报错
            if sections.isEmpty { self.error = "暂时连不上三联官网：\(error.localizedDescription)" }
        }
    }

    func select(_ issue: LWIssue, force: Bool = false) async {
        current = issue
        if !force, let c = cache[issue.id], !c.isEmpty {
            sections = c
            save()
            return
        }
        sections = cache[issue.id] ?? []
        do {
            let d = try await Self.nuxt("/magazine/\(issue.id)")
            guard current?.id == issue.id else { return }
            sections = Self.parseSections(d)
            if !sections.isEmpty { cache[issue.id] = sections }
            save()
        } catch {
            self.error = "目录加载失败：\(error.localizedDescription)"
        }
    }

    // MARK: 解析

    private static func parseSections(_ d: [String: Any]) -> [LWSection] {
        guard let chapter = d["chapterList"] as? [String: Any], let list = chapter["list"] as? [[String: Any]] else { return [] }
        return list.compactMap { sec in
            let name = (sec["lanmu"] as? String) ?? ""
            let arts: [LWArticle] = ((sec["list"] as? [[String: Any]]) ?? []).compactMap { a in
                guard let id = (a["id"] as? NSNumber)?.intValue, let title = a["title"] as? String,
                      let url = URL(string: "\(base)/article/\(id)?origin=6") else { return nil }
                return LWArticle(id: id, title: title, views: (a["viewNum"] as? NSNumber)?.intValue ?? 0, url: url)
            }
            return arts.isEmpty ? nil : LWSection(name: name, articles: arts)
        }
    }

    /// 最新一期的全部文章（给「订阅」时间线用；不改动目录页当前选中的期）
    func latestArticles() async -> (label: String, items: [(title: String, link: String, summary: String)])? {
        await loadIfNeeded()
        guard let top = issues.first else { return nil }
        var secs = cache[top.id] ?? []
        if secs.isEmpty, let d = try? await Self.nuxt("/magazine/\(top.id)") {
            secs = Self.parseSections(d)
            if !secs.isEmpty { cache[top.id] = secs; save() }
        }
        var items: [(title: String, link: String, summary: String)] = []
        for sec in secs {
            for a in sec.articles { items.append((title: a.title, link: a.url.absoluteString, summary: sec.name)) }
        }
        if items.isEmpty { return nil }
        let label: String = "第\(top.no)期　\(top.name)"
        return (label: label, items: items)
    }

    /// 封面图是 http 地址，系统默认不让加载；站点的图床同样支持 https，改成 https
    private static func secure(_ s: String) -> URL? {
        URL(string: s.hasPrefix("http://") ? "https://" + s.dropFirst(7) : s)
    }

    private static func issue(course c: [String: Any]?) -> LWIssue? {
        guard let c, let id = (c["id"] as? NSNumber)?.intValue,
              (c["magazineName"] as? String) == "三联生活周刊" || c["magazineName"] == nil else { return nil }
        let no = Int((c["qikan"] as? String) ?? "") ?? (c["qikan"] as? NSNumber)?.intValue ?? 0
        var date = ""
        if let ms = (c["pubTime"] as? NSNumber)?.doubleValue {
            let f = DateFormatter()
            f.locale = Locale(identifier: "zh_CN")
            f.dateFormat = "M 月 d 日"
            date = f.string(from: Date(timeIntervalSince1970: ms / 1000))
        }
        return LWIssue(id: id, no: no, total: (c["totalQikan"] as? NSNumber)?.intValue ?? 0,
                       name: (c["name"] as? String) ?? "", title: (c["title"] as? String) ?? "",
                       cover: (c["coverPic"] as? String).flatMap(Self.secure), date: date)
    }

    private static func issue(tab t: [String: Any]) -> LWIssue? {
        guard let id = (t["periodicalId"] as? NSNumber)?.intValue else { return nil }
        return LWIssue(id: id, no: (t["qikan"] as? NSNumber)?.intValue ?? 0, total: (t["totalQikan"] as? NSNumber)?.intValue ?? 0,
                       name: (t["periodicalName"] as? String) ?? "", title: (t["title"] as? String) ?? "",
                       cover: (t["coverPic"] as? String).flatMap(Self.secure),
                       date: ((t["pubTime"] as? String) ?? "").replacingOccurrences(of: "年", with: " 年 ").replacingOccurrences(of: "月", with: " 月 "))
    }

    /// 取页面并解出 window.__NUXT__ 的 data[0]（它是一段压缩过的函数调用，交给 JavaScriptCore 执行）
    private static func nuxt(_ path: String) async throws -> [String: Any] {
        guard let url = URL(string: base + path) else { throw URLError(.badURL) }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let h = resp as? HTTPURLResponse, h.statusCode != 200 { throw URLError(.badServerResponse) }
        let html = String(decoding: data, as: UTF8.self)
        return try await Task.detached(priority: .userInitiated) { () throws -> [String: Any] in
            guard let a = html.range(of: "window.__NUXT__="),
                  let b = html.range(of: "</script>", range: a.upperBound ..< html.endIndex) else { throw URLError(.cannotParseResponse) }
            var expr = String(html[a.upperBound ..< b.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            if expr.hasSuffix(";") { expr.removeLast() }
            guard let ctx = JSContext() else { throw URLError(.cannotParseResponse) }
            ctx.evaluateScript("var window = {}; var __j = JSON.stringify((" + expr + ").data[0]);")
            guard let json = ctx.objectForKeyedSubscript("__j")?.toString(), json != "undefined",
                  let obj = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { throw URLError(.cannotParseResponse) }
            return obj
        }.value
    }
}
