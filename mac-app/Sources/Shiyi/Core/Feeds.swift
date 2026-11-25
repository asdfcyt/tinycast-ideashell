import Foundation

/*
 * RSS 订阅：自己解析 RSS 2.0 / RSS 1.0 / Atom / JSON Feed（Foundation 的 XMLParser，不引入第三方库）。
 * 订阅源、文章、已读 / 星标都存在本机（Application Support/Shiyi/feeds.json）；刷新用 ETag / Last-Modified 省流量。
 * 交互参考 NetNewsWire（MIT）。
 */

struct FeedSource: Codable, Identifiable, Hashable {
    var id: String
    var url: String
    var title: String
    var site: String = ""
    var etag: String?
    var modified: String?
    var fetched: Date?
    var error: String?
}

struct FeedItem: Codable, Identifiable, Hashable {
    var id: String          // 订阅源 ID + "|" + 文章标识
    var feed: String
    var title: String
    var link: String
    var summary: String
    var date: Date
    var read = false
    var starred = false
    /// 订阅源里带了全文（在拾忆里直接读）
    var full: Bool? = nil
}

enum FeedSel: Hashable {
    case unread
    case starred
    case feed(String)
}

struct FeedPreset: Identifiable {
    var id: String { url }
    let title: String
    let url: String
}

// MARK: - 解析

struct ParsedFeedItem {
    var id = ""
    var title = ""
    var link = ""
    var summary = ""
    var content = ""
    var date: Date?
}

struct ParsedFeed {
    var title = ""
    var site = ""
    var items: [ParsedFeedItem] = []
}

enum FeedParser {
    static func parse(_ data: Data) -> ParsedFeed? {
        let first = data.first(where: { !($0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 || $0 == 0xEF || $0 == 0xBB || $0 == 0xBF) })
        if first == UInt8(ascii: "{") { return parseJSON(data) }
        let h = FeedXML()
        let p = XMLParser(data: data)
        p.delegate = h
        p.shouldProcessNamespaces = false
        p.parse()
        guard !h.feed.items.isEmpty || !h.feed.title.isEmpty else { return nil }
        return h.feed
    }

    private static func parseJSON(_ data: Data) -> ParsedFeed? {
        guard let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        var f = ParsedFeed()
        f.title = (j["title"] as? String) ?? ""
        f.site = (j["home_page_url"] as? String) ?? ""
        for it in (j["items"] as? [[String: Any]]) ?? [] {
            var i = ParsedFeedItem()
            i.id = (it["id"] as? String) ?? ((it["id"] as? NSNumber)?.stringValue ?? "")
            i.link = (it["url"] as? String) ?? (it["external_url"] as? String) ?? ""
            i.title = (it["title"] as? String) ?? ""
            i.summary = (it["summary"] as? String) ?? (it["content_text"] as? String) ?? ""
            i.content = (it["content_html"] as? String) ?? ""
            i.date = ((it["date_published"] as? String) ?? (it["date_modified"] as? String)).flatMap(parseDate)
            f.items.append(i)
        }
        return f
    }

    // MARK: 日期

    private static let formats = [
        "EEE, dd MMM yyyy HH:mm:ss Z", "EEE, dd MMM yyyy HH:mm:ss zzz", "EEE, d MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm:ss zzz",
        "dd MMM yyyy HH:mm:ss Z", "EEE, dd MMM yyyy HH:mm Z", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd",
    ]

    static func parseDate(_ raw: String) -> Date? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return d }
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: s) { return d }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        for fmt in formats {
            f.dateFormat = fmt
            if let d = f.date(from: s) { return d }
        }
        return nil
    }

    // MARK: 全文

    /// 去掉脚本 / 样式 / 内嵌框架 / 事件属性，只留排版用的 HTML
    static func sanitize(_ html: String, limit: Int = 150_000) -> String {
        var s = html
        s = s.replacingOccurrences(of: "<(script|style|iframe|object|embed|form|noscript)\\b[^>]*>[\\s\\S]*?</\\1>", with: "", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "<(script|style|iframe|object|embed|link|meta)\\b[^>]*/?>", with: "", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "\\son[a-z]+\\s*=\\s*(\"[^\"]*\"|'[^']*'|[^\\s>]+)", with: "", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "javascript:", with: "", options: .caseInsensitive)
        return s.count > limit ? String(s.prefix(limit)) : s
    }

    /// 这段 HTML 像不像全文（有标签、有一定长度），摘要型的 description 不算
    static func looksFull(_ html: String) -> Bool {
        html.count > 900 && html.range(of: "<p[\\s>]|<br|<h[1-6][\\s>]", options: [.regularExpression, .caseInsensitive]) != nil
    }

    // MARK: 文本

    /// 去标签、解码常见实体，压成一段干净的摘要
    static func plain(_ html: String, limit: Int = 600) -> String {
        var s = html
        s = s.replacingOccurrences(of: "<(script|style)[^>]*>[\\s\\S]*?</\\1>", with: "", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "<br\\s*/?>|</p>|</div>|</li>|</h[1-6]>", with: "\n", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (k, v) in ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&hellip;": "…", "&mdash;": "—", "&ldquo;": "“", "&rdquo;": "”"] {
            s = s.replacingOccurrences(of: k, with: v)
        }
        // 数字实体 &#123; / &#x1F;
        if let re = try? NSRegularExpression(pattern: "&#(x?[0-9a-fA-F]+);") {
            let ns = s as NSString
            var out = ""
            var last = 0
            for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
                out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
                let code = ns.substring(with: m.range(at: 1))
                let n = code.hasPrefix("x") ? UInt32(code.dropFirst(), radix: 16) : UInt32(code)
                if let n, let u = Unicode.Scalar(n) { out.unicodeScalars.append(u) }
                last = m.range.location + m.range.length
            }
            out += ns.substring(from: last)
            s = out
        }
        s = s.replacingOccurrences(of: "[ \\t\\u{3000}]+", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\s*\\n\\s*", with: "\n", options: .regularExpression)
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.count > limit { s = String(s.prefix(limit)) + "…" }
        return s
    }
}

private final class FeedXML: NSObject, XMLParserDelegate {
    var feed = ParsedFeed()
    private var stack: [String] = []
    private var text = ""
    private var cur: ParsedFeedItem?

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName qName: String?, attributes a: [String: String] = [:]) {
        let n = name.lowercased()
        stack.append(n)
        text = ""
        if n == "item" || n == "entry" { cur = ParsedFeedItem() }
        // Atom：<link href="…" rel="alternate"/>
        if n == "link", let href = a["href"], !href.isEmpty {
            let rel = (a["rel"] ?? "alternate").lowercased()
            if rel == "alternate" {
                if cur != nil { if (cur?.link ?? "").isEmpty { cur?.link = href } }
                else if feed.site.isEmpty { feed.site = href }
            }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters s: String) { text += s }
    func parser(_ parser: XMLParser, foundCDATA b: Data) { text += String(decoding: b, as: UTF8.self) }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName qName: String?) {
        let n = name.lowercased()
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parent = stack.count >= 2 ? stack[stack.count - 2] : ""
        stack.removeLast()
        text = ""
        if n == "item" || n == "entry" {
            if let c = cur { feed.items.append(c) }
            cur = nil
            return
        }
        if cur != nil {
            switch n {
            case "title": cur?.title = t
            case "link": if !t.isEmpty, (cur?.link ?? "").isEmpty { cur?.link = t }
            case "description", "summary": if !t.isEmpty { cur?.summary = t }
            case "content:encoded", "content": if !t.isEmpty { cur?.content = t }
            case "guid", "id", "rdf:about": if !t.isEmpty { cur?.id = t }
            case "pubdate", "published", "dc:date": if let d = FeedParser.parseDate(t) { cur?.date = d }
            case "updated", "lastbuilddate": if cur?.date == nil, let d = FeedParser.parseDate(t) { cur?.date = d }
            default: break
            }
        } else if parent == "channel" || parent == "feed" {
            switch n {
            case "title": if feed.title.isEmpty { feed.title = t }
            case "link": if feed.site.isEmpty, !t.isEmpty { feed.site = t }
            default: break
            }
        }
    }
}

// MARK: - OPML

private final class OPMLParser: NSObject, XMLParserDelegate {
    var found: [(title: String, url: String)] = []
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName qName: String?, attributes a: [String: String] = [:]) {
        guard name.lowercased() == "outline", let url = a["xmlUrl"] ?? a["xmlurl"], !url.isEmpty else { return }
        found.append((a["title"] ?? a["text"] ?? url, url))
    }
}

// MARK: - 存储与刷新

@MainActor
final class FeedStore: ObservableObject {
    static let shared = FeedStore()

    @Published private(set) var sources: [FeedSource] = []
    @Published private(set) var items: [FeedItem] = []
    @Published var selection: FeedSel = .unread
    @Published var refreshing = false

    static let presets: [FeedPreset] = [
        FeedPreset(title: "阮一峰的网络日志", url: "https://www.ruanyifeng.com/blog/atom.xml"),
        FeedPreset(title: "少数派", url: "https://sspai.com/feed"),
        FeedPreset(title: "IT之家", url: "https://www.ithome.com/rss/"),
        FeedPreset(title: "Hacker News", url: "https://hnrss.org/frontpage"),
    ]

    nonisolated private static let ua = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15"
    private static let file = "feeds.json"
    private static let perFeedLimit = 200

    private struct Disk: Codable {
        var sources: [FeedSource]
        var items: [FeedItem]
    }

    private var saveTask: Task<Void, Never>?
    private var timer: Timer?
    private var started = false
    /// 订阅源自带的全文（HTML），单独存一个文件，免得每次标已读都重写一大坨
    private var contents: [String: String] = [:]
    private var contentsDirty = false
    private static let contentFile = "feeds-content.json"

    init() {
        if let text = LocalStore.read(Self.file), let d = text.data(using: .utf8),
           let disk = try? JSONDecoder().decode(Disk.self, from: d) {
            sources = disk.sources
            items = disk.items
        }
        // 早先版本把财新 / 三联 / AIHOT 当订阅源放进来过，现在它们归「今日信息」，这里清掉
        if sources.contains(where: { $0.url.hasPrefix("builtin:") }) {
            let gone = Set(sources.filter { $0.url.hasPrefix("builtin:") }.map(\.id))
            sources.removeAll { gone.contains($0.id) }
            items.removeAll { gone.contains($0.feed) }
        }
        if let text = LocalStore.read(Self.contentFile), let d = text.data(using: .utf8),
           let c = try? JSONDecoder().decode([String: String].self, from: d) {
            contents = c
        }
    }

    /// 打开「订阅」时调用：过期了就刷新，之后每 20 分钟在后台刷新一次
    func start() {
        guard !started else { return }
        started = true
        timer = Timer.scheduledTimer(withTimeInterval: 20 * 60, repeats: true) { _ in
            Task { @MainActor in await FeedStore.shared.refreshAll() }
        }
        let stale = sources.contains { ($0.fetched ?? .distantPast) < Date().addingTimeInterval(-15 * 60) }
        if stale { Task { await refreshAll() } }
    }

    // MARK: 查询

    /// 今天发布 / 新到的文章（「今日信息」聚合用）
    func todayItems() -> [FeedItem] {
        items.filter { Calendar.current.isDateInToday($0.date) }.sorted { $0.date > $1.date }
    }

    func source(_ id: String) -> FeedSource? { sources.first { $0.id == id } }

    func unread(_ sel: FeedSel) -> Int {
        switch sel {
        case .unread: return items.filter { !$0.read }.count
        case .starred: return items.filter { $0.starred }.count
        case .feed(let id): return items.filter { $0.feed == id && !$0.read }.count
        }
    }

    func visible(_ sel: FeedSel) -> [FeedItem] {
        let list: [FeedItem]
        switch sel {
        case .unread: list = items.filter { !$0.read }
        case .starred: list = items.filter { $0.starred }
        case .feed(let id): list = items.filter { $0.feed == id }
        }
        return list.sorted { $0.date > $1.date }
    }

    func title(of sel: FeedSel) -> String {
        switch sel {
        case .unread: return "全部未读"
        case .starred: return "星标"
        case .feed(let id): return source(id)?.title ?? "订阅"
        }
    }

    func item(_ id: String?) -> FeedItem? {
        guard let id else { return nil }
        return items.first { $0.id == id }
    }

    /// 带全文的文章：拼成一页干净的 HTML，交给内置阅读器排版
    func document(for item: FeedItem) -> String? {
        guard let body = contents[item.id], !body.isEmpty else { return nil }
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        }
        let by = [source(item.feed)?.title ?? "", FeedFormat.full(item.date)].filter { !$0.isEmpty }.joined(separator: " · ")
        return "<!doctype html><html><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><title>\(esc(item.title))</title></head><body><article data-sy-feed=\"1\"><h1>\(esc(item.title))</h1><p class=\"sy-meta\">\(esc(by))</p>\(body)</article></body></html>"
    }

    // MARK: 收藏（财新 / 三联 / AIHOT 等非订阅文章的星标，放进「收藏」这个本地来源，在订阅里的「星标」中看）

    private static let localID = "local-starred"

    func isStarred(link: String) -> Bool {
        items.contains { $0.link == link && $0.starred }
    }

    func toggleExternalStar(title: String, link: String, summary: String = "") {
        if let i = items.firstIndex(where: { $0.link == link && $0.starred }) {
            if items[i].feed == Self.localID { items.remove(at: i) } else { items[i].starred = false }
            scheduleSave()
            return
        }
        if !sources.contains(where: { $0.id == Self.localID }) {
            sources.append(FeedSource(id: Self.localID, url: "local:starred", title: "收藏"))
        }
        var it = FeedItem(id: Self.localID + "|" + link, feed: Self.localID, title: title, link: link,
                          summary: FeedParser.plain(summary), date: Date())
        it.read = true
        it.starred = true
        items.removeAll { $0.id == it.id }
        items.append(it)
        scheduleSave()
    }

    // MARK: 修改

    func setRead(_ id: String, _ v: Bool) {
        guard let i = items.firstIndex(where: { $0.id == id }), items[i].read != v else { return }
        items[i].read = v
        scheduleSave()
    }

    func toggleStar(_ id: String) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].starred.toggle()
        scheduleSave()
    }

    func markAllRead(_ sel: FeedSel) {
        for i in items.indices {
            switch sel {
            case .unread: items[i].read = true
            case .starred: if items[i].starred { items[i].read = true }
            case .feed(let id): if items[i].feed == id { items[i].read = true }
            }
        }
        scheduleSave()
    }

    func remove(_ id: String) {
        sources.removeAll { $0.id == id }
        items.removeAll { $0.feed == id && !$0.starred }
        for k in contents.keys where k.hasPrefix(id + "|") && !(items.first { $0.id == k }?.starred ?? false) { contents[k] = nil; contentsDirty = true }
        if case .feed(let cur) = selection, cur == id { selection = .unread }
        scheduleSave()
    }

    // MARK: 添加（粘贴网址：自动发现页面里的 RSS）

    @discardableResult
    func add(_ input: String) async throws -> FeedSource {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { throw FeedError.message("请输入网址") }
        if s.hasPrefix("feed://") { s = "https://" + s.dropFirst(7) }
        if !s.contains("://") { s = "https://" + s }
        guard let url = URL(string: s) else { throw FeedError.message("网址格式不对") }
        let (feedURL, parsed, _) = try await Self.discover(url)
        if let exist = sources.first(where: { $0.url == feedURL.absoluteString }) {
            selection = .feed(exist.id)
            return exist
        }
        var src = FeedSource(id: UUID().uuidString, url: feedURL.absoluteString,
                             title: parsed.title.isEmpty ? (feedURL.host ?? "订阅") : parsed.title, site: parsed.site)
        src.fetched = Date()
        sources.append(src)
        merge(parsed, into: src.id)
        selection = .feed(src.id)
        scheduleSave()
        return src
    }

    // MARK: 刷新

    func refreshAll() async {
        guard !refreshing, !sources.isEmpty else { return }
        refreshing = true
        defer { refreshing = false }
        let list = sources.filter { !$0.url.hasPrefix("local:") }
        await withTaskGroup(of: (String, FetchResult).self) { group in
            for s in list {
                group.addTask { (s.id, await Self.fetch(s)) }
            }
            for await (id, r) in group { apply(r, to: id) }
        }
        scheduleSave()
    }

    func refresh(_ id: String) async {
        guard let s = source(id), !s.url.hasPrefix("local:") else { return }
        refreshing = true
        defer { refreshing = false }
        apply(await Self.fetch(s), to: id)
        scheduleSave()
    }

    private func apply(_ r: FetchResult, to id: String) {
        guard let i = sources.firstIndex(where: { $0.id == id }) else { return }
        sources[i].fetched = Date()
        switch r {
        case .notModified:
            sources[i].error = nil
        case .failed(let msg):
            sources[i].error = msg
        case .ok(let parsed, let etag, let modified):
            sources[i].error = nil
            sources[i].etag = etag
            sources[i].modified = modified
            if !parsed.title.isEmpty, sources[i].title.isEmpty || sources[i].title == (URL(string: sources[i].url)?.host ?? "") { sources[i].title = parsed.title }
            if sources[i].site.isEmpty { sources[i].site = parsed.site }
            merge(parsed, into: id)
        }
    }

    private func merge(_ parsed: ParsedFeed, into feed: String) {
        var existing = Dictionary(uniqueKeysWithValues: items.filter { $0.feed == feed }.map { ($0.id, $0) })
        let now = Date()
        for p in parsed.items {
            let key = !p.id.isEmpty ? p.id : (!p.link.isEmpty ? p.link : p.title)
            guard !key.isEmpty else { continue }
            let id = feed + "|" + key
            let body = !p.summary.isEmpty ? p.summary : p.content
            let summary = FeedParser.plain(body)
            let fullHTML = !p.content.isEmpty ? p.content : (FeedParser.looksFull(p.summary) ? p.summary : "")
            if var old = existing[id] {
                old.title = p.title.isEmpty ? old.title : p.title
                if !summary.isEmpty { old.summary = summary }
                if !fullHTML.isEmpty { contents[id] = FeedParser.sanitize(fullHTML); contentsDirty = true; old.full = true }
                existing[id] = old
            } else {
                var it = FeedItem(id: id, feed: feed, title: p.title.isEmpty ? "（无标题）" : FeedParser.plain(p.title, limit: 200),
                                  link: p.link, summary: summary, date: p.date ?? now)
                if !fullHTML.isEmpty { contents[id] = FeedParser.sanitize(fullHTML); contentsDirty = true; it.full = true }
                existing[id] = it
            }
        }
        // 每个订阅源最多留最近 N 条（星标的一直留着）
        let sorted = existing.values.sorted { $0.date > $1.date }
        var kept: [FeedItem] = []
        for it in sorted where kept.count < Self.perFeedLimit || it.starred { kept.append(it) }
        let keepIDs = Set(kept.map(\.id))
        for it in sorted where !keepIDs.contains(it.id) && contents[it.id] != nil { contents[it.id] = nil; contentsDirty = true }
        items = items.filter { $0.feed != feed } + kept
    }

    // MARK: OPML

    @discardableResult
    func importOPML(_ data: Data) async -> Int {
        let p = OPMLParser()
        let xp = XMLParser(data: data)
        xp.delegate = p
        xp.parse()
        var added = 0
        for f in p.found where !sources.contains(where: { $0.url == f.url }) {
            sources.append(FeedSource(id: UUID().uuidString, url: f.url, title: f.title))
            added += 1
        }
        scheduleSave()
        if added > 0 { await refreshAll() }
        return added
    }

    func exportOPML() -> String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
                .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        }
        let lines = sources.filter { !$0.url.hasPrefix("local:") }.map { "    <outline type=\"rss\" text=\"\(esc($0.title))\" title=\"\(esc($0.title))\" xmlUrl=\"\(esc($0.url))\" htmlUrl=\"\(esc($0.site))\"/>" }
        return "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<opml version=\"2.0\">\n  <head><title>拾忆订阅</title></head>\n  <body>\n" + lines.joined(separator: "\n") + "\n  </body>\n</opml>\n"
    }

    // MARK: 网络

    enum FeedError: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let m) = self { return m }; return nil }
    }

    enum FetchResult {
        case ok(ParsedFeed, etag: String?, modified: String?)
        case notModified
        case failed(String)
    }

    nonisolated private static func request(_ url: URL, etag: String? = nil, modified: String? = nil) async throws -> (Data, HTTPURLResponse) {
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        req.setValue("application/rss+xml, application/atom+xml, application/feed+json, application/xml, text/xml, */*", forHTTPHeaderField: "Accept")
        if let etag { req.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        if let modified { req.setValue(modified, forHTTPHeaderField: "If-Modified-Since") }
        let (d, r) = try await URLSession.shared.data(for: req)
        guard let h = r as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (d, h)
    }

    nonisolated private static func fetch(_ s: FeedSource) async -> FetchResult {
        guard let url = URL(string: s.url) else { return .failed("网址无效") }
        do {
            let (data, h) = try await request(url, etag: s.etag, modified: s.modified)
            if h.statusCode == 304 { return .notModified }
            guard h.statusCode == 200 else { return .failed("服务返回 \(h.statusCode)") }
            guard let parsed = await Task.detached(operation: { FeedParser.parse(data) }).value else { return .failed("不是有效的订阅源") }
            return .ok(parsed, etag: h.value(forHTTPHeaderField: "ETag"), modified: h.value(forHTTPHeaderField: "Last-Modified"))
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// 给一个网址：本身是订阅源就直接用；是网页就找 <link rel="alternate">，再试几个常见路径
    nonisolated private static func discover(_ url: URL) async throws -> (URL, ParsedFeed, Data) {
        let (data, h) = try await request(url)
        guard h.statusCode == 200 else { throw FeedError.message("打不开这个网址（\(h.statusCode)）") }
        if let p = await Task.detached(operation: { FeedParser.parse(data) }).value { return (url, p, data) }

        let html = String(decoding: data, as: UTF8.self)
        var candidates: [URL] = []
        if let re = try? NSRegularExpression(pattern: "<link\\b[^>]*>", options: .caseInsensitive) {
            let ns = html as NSString
            for m in re.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
                let tag = ns.substring(with: m.range)
                let lower = tag.lowercased()
                guard lower.contains("alternate"), lower.contains("rss") || lower.contains("atom") || lower.contains("feed+json") || lower.contains("text/xml") || lower.contains("application/xml"),
                      let href = attr("href", in: tag), let u = URL(string: href, relativeTo: url)?.absoluteURL else { continue }
                candidates.append(u)
            }
        }
        for path in ["/feed", "/rss", "/atom.xml", "/feed.xml", "/rss.xml", "/index.xml"] {
            if let u = URL(string: path, relativeTo: url)?.absoluteURL { candidates.append(u) }
        }
        for c in candidates {
            if let (d, hh) = try? await request(c), hh.statusCode == 200, let p = await Task.detached(operation: { FeedParser.parse(d) }).value {
                return (c, p, d)
            }
        }
        throw FeedError.message("没找到这个网站的订阅源（RSS）")
    }

    nonisolated private static func attr(_ name: String, in tag: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: name + "\\s*=\\s*[\"']([^\"']+)[\"']", options: .caseInsensitive),
              let m = re.firstMatch(in: tag, range: NSRange(location: 0, length: (tag as NSString).length)) else { return nil }
        return (tag as NSString).substring(with: m.range(at: 1))
    }

    // MARK: 持久化

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled, let self else { return }
            let disk = Disk(sources: self.sources, items: self.items)
            if let d = try? JSONEncoder().encode(disk), let text = String(data: d, encoding: .utf8) {
                LocalStore.write(Self.file, text)
            }
            if self.contentsDirty {
                self.contentsDirty = false
                if let d = try? JSONEncoder().encode(self.contents), let text = String(data: d, encoding: .utf8) {
                    LocalStore.write(Self.contentFile, text)
                }
            }
        }
    }
}
