import Foundation

/// 今天页用到的几份「过滤 + 排序」后的数据。
/// 以前写成页面里的计算属性，一次重绘要读几十遍（每次都重新排序、重新解析每条笔记的日期，页面还会为了自适应布局画两遍），
/// 现在按数据版本缓存：待办 / 笔记 / 今天的 Daily Note 变了才重算。
struct TodayData {
    var overdue: [DidaTask] = []
    var todayTasks: [DidaTask] = []
    var undated: [DidaTask] = []
    var todayDone: [DidaTask] = []
    /// 今天的笔记（Daily Note 单独按条显示，这里不重复列那一篇）
    var todayNotes: [NoteInfo] = []
    /// 今天 Daily Note 里最近的 5 条（新的在上）
    var dailyRecent: [DailyEntry] = []
}

extension AppModel {
    func todayData() -> TodayData {
        let today = Day.today()
        if let m = todayMemo, m.day == today { return m.data }

        var d = TodayData()
        if let ov = overview {
            d.overdue = ov.overdue.sorted { ($0.date ?? "") < ($1.date ?? "") }
            d.todayTasks = ov.todayTasks(today).sorted {
                let a = $0.time ?? "99:99", b = $1.time ?? "99:99"
                return a != b ? a < b : $0.priority > $1.priority
            }
            d.undated = ov.undated
            // 比对时间戳所在的日子，不必给每条已完成的待办格式化一次日期字符串
            d.todayDone = ov.done.filter { $0.completedDate.map { Day.cal.isDateInToday($0) } ?? false }
        }
        let dailyId = dailyToday?.noteId
        d.todayNotes = timeline.filter { $0.day == today && $0.id != dailyId && !$0.tags.contains("daily-note") }
        d.dailyRecent = Array((dailyToday?.entries ?? []).filter { !$0.struck }.suffix(5).reversed())
        todayMemo = (today, d)
        return d
    }
}
