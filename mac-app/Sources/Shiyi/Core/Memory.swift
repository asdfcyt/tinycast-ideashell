import Foundation

/// 往日回顾里的一条：「1 年前的今天」写下的一条笔记
struct MemoryItem: Identifiable, Hashable {
    let label: String
    let date: String
    let note: NoteInfo
    var id: String { note.id }
}

extension AppModel {
    /// 读 1 周 / 1 个月 / 3 个月 / 1 年前的今天写的笔记（每天只读一次）。Daily Note 本身和备份笔记不算。
    func loadMemory(ifStale: Bool = true) async {
        guard hasIdeashell else { return }
        let key = Day.today()
        if ifStale, isFresh("memory", key: key, within: 3 * 3600) { return }
        guard beginLoad("memory", ifStale: ifStale) else { return }
        defer { endLoad("memory") }

        let cal = Day.cal
        let now = Date()
        let offsets: [(String, Date?)] = [
            ("1 周前", cal.date(byAdding: .day, value: -7, to: now)),
            ("1 个月前", cal.date(byAdding: .month, value: -1, to: now)),
            ("3 个月前", cal.date(byAdding: .month, value: -3, to: now)),
            ("1 年前", cal.date(byAdding: .year, value: -1, to: now)),
        ]
        let api = ideashell
        var items: [MemoryItem] = []
        var failed = false
        await withTaskGroup(of: (Int, [MemoryItem]?).self) { group in
            for (i, o) in offsets.enumerated() {
                guard let d = o.1 else { continue }
                let start = Day.startOfDay(d)
                let end = cal.date(byAdding: .day, value: 1, to: start) ?? start
                let label = o.0, day = Day.string(d)
                group.addTask {
                    guard let r = try? await api.notesInRange(start, end) else { return (i, nil) }
                    let notes = r.notes.filter { n in
                        !BackupService.isBackupNote(n)
                            && !n.tags.contains { $0.contains("daily-note") }
                            && RX(#"^\d{4}-\d{2}-\d{2}$"#, multiline: false).first(in: n.title.trimmed) == nil
                    }
                    return (i, notes.prefix(3).map { MemoryItem(label: label, date: day, note: $0) })
                }
            }
            var byIndex: [Int: [MemoryItem]] = [:]
            for await (i, list) in group {
                if let list { byIndex[i] = list } else { failed = true }
            }
            items = byIndex.keys.sorted().flatMap { byIndex[$0] ?? [] }
        }
        memory = Array(items.prefix(8))
        if !failed { stamp("memory", key: key) }
    }
}
