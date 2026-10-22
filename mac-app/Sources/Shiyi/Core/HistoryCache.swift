import Foundation

/// 回顾 / 洞察 / 日历的数据存本机：重启后切到这些页面立刻有内容（后台再悄悄更新），不用对着空白等网络。
/// 读写都在后台线程做，不占主线程。

private struct RiverStore: Codable { var preset: String; var data: TimelineData }
private struct ReviewStore: Codable { var days: Int; var data: ReviewData }
private struct CalendarStore: Codable { var tasks: [String: DidaTask]; var notes: [String: [NoteInfo]] }

private enum HistoryDisk {
    static func read<T: Decodable>(_ name: String) -> T? {
        guard let text = LocalStore.read(name), let d = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(T.self, from: d)
    }

    static func write<T: Encodable>(_ name: String, _ value: T) {
        guard let d = try? JSONEncoder().encode(value), let text = String(data: d, encoding: .utf8) else { return }
        LocalStore.write(name, text)
    }
}

extension AppModel {
    /// 启动后在后台读回上次的数据；网络先回来了的就不覆盖
    func restoreHistoryCaches() {
        Task.detached(priority: .utility) { [weak self] in
            let river: RiverStore? = HistoryDisk.read("river.json")
            let review: ReviewStore? = HistoryDisk.read("review.json")
            let calendar: CalendarStore? = HistoryDisk.read("calendar.json")
            await MainActor.run {
                guard let self else { return }
                if self.river == nil, let r = river, r.preset == self.riverPreset.rawValue { self.river = r.data }
                if self.review == nil, let v = review, v.days == self.reviewDays { self.review = v.data }
                if self.calendarTasks.isEmpty, let c = calendar {
                    self.calendarTasks = c.tasks
                    self.calendarNotes = c.notes
                }
            }
        }
    }

    func saveRiverCache() {
        guard let data = river else { return }
        let s = RiverStore(preset: riverPreset.rawValue, data: data)
        Task.detached(priority: .utility) { HistoryDisk.write("river.json", s) }
    }

    func saveReviewCache() {
        guard let data = review else { return }
        let s = ReviewStore(days: reviewDays, data: data)
        Task.detached(priority: .utility) { HistoryDisk.write("review.json", s) }
    }

    func saveCalendarCache() {
        let s = CalendarStore(tasks: calendarTasks, notes: calendarNotes)
        Task.detached(priority: .utility) { HistoryDisk.write("calendar.json", s) }
    }

    // MARK: - 有变化才重读

    /// 待办 / 笔记的「指纹」：定时刷新读回来后和上次比，没变就说明回顾 / 洞察 / 日历的缓存还有效，不用重读
    static func fingerprint(_ ov: DidaOverview) -> Int {
        var h = Hasher()
        for t in ov.overdue + ov.upcoming + ov.undated + ov.done {
            h.combine(t.id); h.combine(t.title); h.combine(t.date); h.combine(t.time)
            h.combine(t.done); h.combine(t.priority); h.combine(t.projectId)
        }
        return h.finalize()
    }

    static func fingerprint(_ notes: [NoteInfo]) -> Int {
        var h = Hasher()
        for n in notes { h.combine(n.id); h.combine(n.title); h.combine(n.createdAt); h.combine(n.summary) }
        return h.finalize()
    }

    /// 定时刷新 / 回到前台之后调用：数据有变化才让缓存作废，并且悄悄重读当前正在看的那一页
    func applyHistoryChanges() {
        guard historyDirty else { return }
        invalidateHistory()
        switch section {
        case .calendar: Task { await loadCalendar(ifStale: true) }
        case .review: Task { await loadRiver(silent: true, ifStale: true) }
        case .insights: Task { await loadReview(ifStale: true) }
        default: break
        }
    }
}
