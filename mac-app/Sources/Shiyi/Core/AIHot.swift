import Foundation

/*
 * AIHOT（aihot.news）：中文 AI 资讯站。用它公开的匿名只读 JSON 接口（/api/v1，无需 Key），
 * 个人非商业使用免费；每条内容都带「数据来源：AIHOT」的跳转链接。不做全文抓取，原文在内嵌浏览器里打开。
 */

struct AIHotItem: Identifiable, Hashable {
    let id: String
    let title: String
    let summary: String
    let reason: String
    let source: String
    let category: String
    let aihot: URL?
    let original: URL?
    let published: Date?
}

struct AIHotSection: Identifiable, Hashable {
    var id: String { label }
    let label: String
    let items: [AIHotItem]
}

struct AIHotEntry: Identifiable, Hashable {
    var id: String { date }
    let date: String
    let leadTitle: String
    let leadParagraph: String
}

struct AIHotDaily {
    let date: String
    let leadTitle: String
    let leadParagraph: String
    let link: URL?
    let highlights: [AIHotItem]
    let sections: [AIHotSection]
    let flashes: [AIHotItem]
}

@MainActor
final class AIHotStore: ObservableObject {
    static let shared = AIHotStore()

    @Published var entries: [AIHotEntry] = []
    @Published var daily: AIHotDaily?
    @Published var date: String?
    @Published var picks: [AIHotItem] = []
    @Published var loading = false
    @Published var error: String?

    private var loaded = false
    private static let base = "https://aihot.news/api/v1"

    func loadIfNeeded() async {
        guard !loaded else { return }
        await reload()
    }

    func reload() async {
        loading = true
        error = nil
        defer { loading = false }
        do {
            async let list = Self.getJSON("/dailies?limit=30")
            async let sel = Self.getJSON("/items?mode=selected&window=7d&limit=30")
            let (l, s) = try await (list, sel)
            entries = ((l["items"] as? [[String: Any]]) ?? []).compactMap(Self.entry)
            picks = ((s["items"] as? [[String: Any]]) ?? []).compactMap(Self.item)
            loaded = true
            if let first = entries.first, date == nil || !entries.contains(where: { $0.date == date }) {
                await select(first.date)
            } else if let d = date {
                await select(d)
            }
        } catch {
            self.error = "暂时连不上 AIHOT：\(error.localizedDescription)"
        }
    }

    func select(_ d: String) async {
        date = d
        daily = nil
        do {
            let j = try await Self.getJSON("/dailies/\(d)")
            guard date == d, let r = j["report"] as? [String: Any] else { return }
            let lead = r["lead"] as? [String: Any] ?? [:]
            let links = r["links"] as? [String: Any] ?? [:]
            let sections: [AIHotSection] = ((r["sections"] as? [[String: Any]]) ?? []).map {
                AIHotSection(label: ($0["label"] as? String) ?? "", items: (($0["items"] as? [[String: Any]]) ?? []).compactMap(Self.item))
            }.filter { !$0.items.isEmpty }
            daily = AIHotDaily(
                date: (r["date"] as? String) ?? d,
                leadTitle: (lead["title"] as? String) ?? "",
                leadParagraph: (lead["leadParagraph"] as? String) ?? "",
                link: (links["aihot"] as? String).flatMap(URL.init(string:)),
                highlights: ((r["highlights"] as? [[String: Any]]) ?? []).compactMap(Self.item),
                sections: sections,
                flashes: ((r["flashes"] as? [[String: Any]]) ?? []).compactMap(Self.item)
            )
        } catch {
            self.error = "日报加载失败：\(error.localizedDescription)"
        }
    }

    // MARK: 解析

    private static func entry(_ d: [String: Any]) -> AIHotEntry? {
        guard let date = d["date"] as? String else { return nil }
        return AIHotEntry(date: date, leadTitle: (d["leadTitle"] as? String) ?? "", leadParagraph: (d["leadParagraph"] as? String) ?? "")
    }

    private static func item(_ d: [String: Any]) -> AIHotItem? {
        guard let id = d["id"] as? String, let title = d["title"] as? String else { return nil }
        let links = d["links"] as? [String: Any] ?? [:]
        let src = d["source"] as? [String: Any] ?? [:]
        var name = (src["name"] as? String) ?? ""
        for tail in ["（网页）", "（RSS）"] where name.hasSuffix(tail) { name = String(name.dropLast(tail.count)) }
        return AIHotItem(
            id: id,
            title: title,
            summary: (d["summary"] as? String) ?? "",
            reason: (d["reason"] as? String) ?? "",
            source: name,
            category: categoryName((d["category"] as? String) ?? ""),
            aihot: (links["aihot"] as? String).flatMap(URL.init(string:)),
            original: (links["original"] as? String).flatMap(URL.init(string:)),
            published: (d["publishedAt"] as? String).flatMap(parseDate)
        )
    }

    private static func categoryName(_ k: String) -> String {
        ["ai-models": "模型", "ai-products": "产品", "industry": "行业", "paper": "论文", "tip": "教程", "opinion": "观点"][k] ?? ""
    }

    private static func parseDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    private static func getJSON(_ path: String) async throws -> [String: Any] {
        guard let url = URL(string: base + path) else { throw URLError(.badURL) }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue("aihot-api/2.0.0", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let h = resp as? HTTPURLResponse, h.statusCode != 200 {
            throw NSError(domain: "AIHOT", code: h.statusCode, userInfo: [NSLocalizedDescriptionKey: h.statusCode == 429 ? "请求太频繁，稍后再试" : "服务返回 \(h.statusCode)"])
        }
        guard let j = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw URLError(.cannotParseResponse) }
        return j
    }
}
