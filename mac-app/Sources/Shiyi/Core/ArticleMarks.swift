import Foundation

/// 财新 / 三联 / AIHOT 的文章「已读」标记（按文章链接记在本机；财新以前的已读记录沿用同一个键）
@MainActor
final class ArticleMarks: ObservableObject {
    static let shared = ArticleMarks()

    @Published private(set) var read: Set<String>
    private static let key = "reader.readArticles"

    private init() {
        read = Set(UserDefaults.standard.stringArray(forKey: Self.key) ?? [])
    }

    func isRead(_ link: String) -> Bool { read.contains(link) }
    func isRead(_ url: URL?) -> Bool { url.map { read.contains($0.absoluteString) } ?? false }

    func setRead(_ link: String, _ v: Bool) {
        if v { guard read.insert(link).inserted else { return } } else { guard read.remove(link) != nil else { return } }
        // 只留最近 3000 条，免得越记越大
        let list = Array(read)
        if list.count > 3000 { read = Set(list.suffix(3000)) }
        UserDefaults.standard.set(Array(read), forKey: Self.key)
    }

    func markRead(_ link: String) { setRead(link, true) }
}

/// 阅读器的本机缓存：每篇文章的译文（按段落内容对应，翻过的下次直接带出）和 AI 摘要
@MainActor
final class ReaderCache {
    static let shared = ReaderCache()

    struct Summary: Codable, Equatable {
        var lead: String
        var points: [String]
    }

    private struct Entry: Codable {
        var tr: [String: String] = [:]
        var summary: Summary?
        var touched = Date()
    }

    private var map: [String: Entry] = [:]
    private var saveTask: Task<Void, Never>?
    private static let file = "reader-cache.json"
    private static let limit = 300

    private init() {
        if let text = LocalStore.read(Self.file), let d = text.data(using: .utf8),
           let m = try? JSONDecoder().decode([String: Entry].self, from: d) { map = m }
    }

    /// 去掉 # 之后的部分当作文章的键
    static func key(_ url: URL?) -> String? {
        guard let s = url?.absoluteString else { return nil }
        return s.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init)
    }

    /// FNV-1a 64 位：同一段文字永远得到同一个键
    static func hash(_ s: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return String(h, radix: 16)
    }

    // MARK: 译文

    func translation(_ url: URL?, _ text: String) -> String? {
        guard let k = Self.key(url) else { return nil }
        return map[k]?.tr[Self.hash(text)]
    }

    func hasTranslation(_ url: URL?) -> Bool {
        guard let k = Self.key(url) else { return false }
        return !(map[k]?.tr.isEmpty ?? true)
    }

    func setTranslations(_ url: URL?, _ pairs: [(String, String)]) {
        guard let k = Self.key(url), !pairs.isEmpty else { return }
        var e = map[k] ?? Entry()
        for (src, tr) in pairs where !tr.isEmpty { e.tr[Self.hash(src)] = tr }
        e.touched = Date()
        map[k] = e
        scheduleSave()
    }

    func clearTranslations(_ url: URL?) {
        guard let k = Self.key(url), var e = map[k] else { return }
        e.tr = [:]
        map[k] = e
        scheduleSave()
    }

    // MARK: AI 摘要

    func summary(_ url: URL?) -> Summary? {
        guard let k = Self.key(url) else { return nil }
        return map[k]?.summary
    }

    func setSummary(_ url: URL?, _ s: Summary?) {
        guard let k = Self.key(url) else { return }
        var e = map[k] ?? Entry()
        e.summary = s
        e.touched = Date()
        map[k] = e
        scheduleSave()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled, let self else { return }
            if self.map.count > Self.limit {
                let keep = self.map.sorted { $0.value.touched > $1.value.touched }.prefix(Self.limit)
                self.map = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
            }
            if let d = try? JSONEncoder().encode(self.map), let text = String(data: d, encoding: .utf8) {
                LocalStore.write(Self.file, text)
            }
        }
    }
}
