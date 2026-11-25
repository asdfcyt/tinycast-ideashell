import Foundation

/*
 * 今日信息：把财新周刊、三联周刊的最新一期、AIHOT 今天的精选、以及 RSS 订阅里今天的新内容聚在一页里。
 * 这里只做目录汇总；点开后各自用原来的方式阅读（财新 / 三联 / AIHOT 用专用排版，RSS 用订阅里的全文或通用重排）。
 */

struct TodayEntry: Identifiable, Hashable {
    enum Kind: Hashable { case web, rss }
    let id: String          // 组名|链接 或 组名|订阅文章 ID
    let raw: String         // 链接 或 订阅文章 ID
    let title: String
    let sub: String
    let kind: Kind
}

struct TodayGroup: Identifiable, Hashable {
    let id: String
    let name: String
    let icon: String
    let note: String
    let entries: [TodayEntry]
}

@MainActor
final class TodayStore: ObservableObject {
    static let shared = TodayStore()

    @Published private(set) var groups: [TodayGroup] = []
    @Published private(set) var loading = false
    /// 展开的分组（周刊文章多，默认收起）
    @Published var expanded: Set<String> = ["aihot", "rss"]
    private var loadedOnce = false

    private init() {}

    func isRead(_ e: TodayEntry) -> Bool {
        e.kind == .rss ? (FeedStore.shared.item(e.raw)?.read ?? false) : ArticleMarks.shared.isRead(e.raw)
    }

    func markRead(_ e: TodayEntry) {
        if e.kind == .rss {
            FeedStore.shared.setRead(e.raw, true)
            objectWillChange.send()
        } else {
            ArticleMarks.shared.markRead(e.raw)
            objectWillChange.send()
        }
    }

    func unread(_ g: TodayGroup) -> Int { g.entries.filter { !isRead($0) }.count }
    var totalUnread: Int { groups.reduce(0) { $0 + unread($1) } }

    func toggle(_ id: String) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    func loadIfNeeded() async {
        if !loadedOnce { await reload(force: false) }
    }

    /// `force`：连 RSS 和 AIHOT 也重新拉一遍
    func reload(force: Bool) async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        loadedOnce = true

        if force {
            await FeedStore.shared.refreshAll()
            await AIHotStore.shared.reload()
        } else {
            await AIHotStore.shared.loadIfNeeded()
        }
        var out: [TodayGroup] = []
        func publish() { groups = out }

        // AIHOT：今天发布的精选；今天还没有就拿最近几条
        let picks = AIHotStore.shared.picks
        let cal = Calendar.current
        var ai = picks.filter { $0.published.map(cal.isDateInToday) ?? false }
        var note = "今天 \(ai.count) 条精选"
        if ai.isEmpty { ai = Array(picks.prefix(8)); note = ai.isEmpty ? "" : "今天还没有，先看最近的精选" }
        let aiEntries: [TodayEntry] = ai.compactMap { it in
            guard let u = (it.aihot ?? it.original)?.absoluteString else { return nil }
            let sub = [it.source, it.category].filter { !$0.isEmpty }.joined(separator: " · ")
            return TodayEntry(id: "aihot|" + u, raw: u, title: it.title, sub: sub.isEmpty ? it.summary : sub, kind: .web)
        }
        if !aiEntries.isEmpty { out.append(TodayGroup(id: "aihot", name: "AI 日报", icon: "sparkles", note: note, entries: aiEntries)) }

        // RSS 订阅：今天的新文章
        let rss: [TodayEntry] = FeedStore.shared.todayItems().map {
            TodayEntry(id: "rss|" + $0.id, raw: $0.id, title: $0.title,
                       sub: FeedStore.shared.source($0.feed)?.title ?? "", kind: .rss)
        }
        if !rss.isEmpty { out.append(TodayGroup(id: "rss", name: "订阅", icon: "antenna.radiowaves.left.and.right", note: "今天 \(rss.count) 篇", entries: rss)) }
        publish()

        // 周刊：最新一期（慢一些，取到再补上）
        if let r = await WeeklyStore.shared.latestArticles() {
            out.append(Self.weekly(id: "caixin", name: "财新周刊", icon: "newspaper", r))
            publish()
        }
        if let r = await LifeweekStore.shared.latestArticles() {
            out.append(Self.weekly(id: "lifeweek", name: "三联", icon: "book.closed", r))
            publish()
        }
    }

    private static func weekly(id: String, name: String, icon: String,
                               _ r: (label: String, items: [(title: String, link: String, summary: String)])) -> TodayGroup {
        var entries: [TodayEntry] = []
        for it in r.items {
            entries.append(TodayEntry(id: id + "|" + it.link, raw: it.link, title: it.title, sub: it.summary, kind: .web))
        }
        return TodayGroup(id: id, name: name, icon: icon, note: r.label + " · 共 \(entries.count) 篇", entries: entries)
    }
}
