import Foundation

extension AppModel {
    // MARK: - 节假日

    func loadHolidays() async {
        let h = await HolidayStore.load()
        if !h.isEmpty { holidays = h }
    }

    // MARK: - 时间河（日历右侧）

    /// 河里勾选 / 取消勾选待办
    func toggleTask(_ t: DidaTask) async {
        if t.done { await undoComplete(t) } else { await complete(t) }
        try? await Task.sleep(nanoseconds: 900_000_000)
        await loadCalendar()
    }

    // MARK: - 日历拖拽改期

    /// 把任务安排到 [day]：有时间的保留时间点，只改日期；无日期的任务变成当天全天
    func moveTask(_ taskId: String, to day: String) async {
        guard let task = localTask(taskId), !task.done else { return }
        if day < Day.today() { showNotice("不能把任务安排到过去"); return }
        if task.date == day { return }
        let old = calendarTasks[taskId]
        var moved = task
        moved.date = day
        calendarTasks[taskId] = moved
        if var ov = overview { ov = ov.placing(moved); overview = ov }
        loadStamps.removeValue(forKey: "review")
        showNotice("已改到 \(Day.label(day))")
        if SyncQueue.handles(task) {
            SyncQueue.shared.enqueue(task, .schedule(date: day, time: task.time), model: self)
        } else {
            do {
                try await dida.reschedule(task, date: day, time: task.time)
                await loadOverview(silent: true)
            } catch {
                if let old { calendarTasks[taskId] = old } else { calendarTasks.removeValue(forKey: taskId) }
                calendarError = "改期失败：" + error.localizedDescription
            }
        }
    }
}
