import Foundation

/// 日历时间轴上双击出来的「新建待办」草稿（和系统日历双击时间轴一样：先在轴上出现一块，右边填内容，再确认添加）
struct CalendarDraft: Equatable {
    var date: String
    /// HH:mm；nil = 全天
    var time: String?
    var title = ""
    var priority = 0
}

extension AppModel {
    /// 在某天某个时刻（分钟数，已按 15 分钟取整）开一个草稿；minutes 为 nil = 全天待办
    func startCalendarDraft(date: String, minutes: Int?) {
        if date < Day.today() { showNotice("不能把待办安排到过去"); return }
        calPane.clear()
        calendarDraft = CalendarDraft(date: date, time: minutes.map { String(format: "%02d:%02d", $0 / 60, $0 % 60) })
    }

    func cancelCalendarDraft() { calendarDraft = nil }

    /// 把草稿写成真正的待办。成功后右侧切到这条待办的详情
    @discardableResult
    func commitCalendarDraft() async -> Bool {
        guard let d = calendarDraft else { return false }
        let title = d.title.trimmed
        guard !title.isEmpty else { showNotice("先写一下待办的标题"); return false }
        guard hasDida || hasIdeashell else { showNotice("先到「设置」填写滴答清单 / 闪念贝壳的凭证"); return false }
        do {
            var created: DidaTask?
            if hasDida {
                created = try await dida.createTask(title: title, date: d.date, time: d.time, priority: d.priority)
            } else {
                try await ideashell.createTodo(title, date: d.date, time: d.time)
            }
            invalidateHistory()
            calendarDraft = nil
            showNotice("已添加待办 · " + Day.label(d.date) + (d.time.map { " " + $0 } ?? ""))
            await loadOverview(silent: true)
            await loadCalendar()
            if let created { calPane.select(.task(localTask(created.id) ?? created), entry: nil) }
            return true
        } catch {
            showNotice("添加失败：" + error.localizedDescription)
            return false
        }
    }
}
