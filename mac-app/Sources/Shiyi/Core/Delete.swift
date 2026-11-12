import AppKit
import Foundation

/// 要删除的东西（参考安卓端：删除任务 / 长按日记 → 删除，都要先确认）
enum DeleteRequest {
    case task(DidaTask)
    /// Daily Note 里的单条日记（日期 yyyy-MM-dd + 条目）
    case daily(date: String, entry: DailyEntry, noteId: String?)
}

extension AppModel {
    /// 弹出系统确认框，确认后才真正删除。用系统弹窗而不是 SwiftUI 的 alert，这样在弹出页面（sheet）里也能正常显示
    func requestDelete(_ r: DeleteRequest) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        switch r {
        case let .task(t):
            alert.messageText = "删除这个待办？"
            alert.informativeText = SjzTasks.owns(t.id)
                ? "「\(t.cleanTitle.prefix(60))」会从结审里删除，不能恢复。"
                : "「\(t.cleanTitle.prefix(60))」会从滴答清单里删除。"
        case let .daily(date, e, _):
            alert.messageText = "删除这条日记？"
            alert.informativeText = "将从 \(date) 的 Daily Note 里删掉：\n\n\(e.text.prefix(120))"
        }
        let del = alert.addButton(withTitle: "删除")
        del.hasDestructiveAction = true
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            switch r {
            case let .task(t): await deleteTask(t)
            case let .daily(date, e, id): await deleteDaily(date: date, entry: e, noteId: id)
            }
        }
    }

    /// 删除待办：界面上先去掉，再删滴答里的，失败了回滚
    func deleteTask(_ task: DidaTask) async {
        guard hasDida || SjzTasks.owns(task.id) else { showNotice("先到「设置」填写滴答清单 API 口令"); return }
        let beforeOverview = overview
        let beforeCalendar = calendarTasks
        if var ov = overview {
            ov = ov.withoutTask(task.id)
            ov.done.removeAll { $0.id == task.id }
            overview = ov
        }
        calendarTasks.removeValue(forKey: task.id)
        if calPane.isTask(task.id) { calPane.clear() }
        let hasSheet: (SheetPage) -> Bool = { if case let .task(t) = $0 { return t.id == task.id }; return false }
        if sheetStack.contains(where: hasSheet) { sheetStack.removeAll(where: hasSheet) }

        invalidateHistory()
        showNotice("已删除「" + String(task.cleanTitle.prefix(24)) + "」")
        if SyncQueue.handles(task) {
            SyncQueue.shared.enqueue(task, .delete, model: self)
            return
        }
        do {
            try await dida.deleteTask(task)
            await loadOverview(silent: true)
            if section == .calendar { await loadCalendar() }
        } catch {
            overview = beforeOverview
            calendarTasks = beforeCalendar
            showNotice("删除失败：" + error.localizedDescription)
        }
    }

    /// 删除 Daily Note 里的一条日记：先在时间河里去掉，再改那天的 Daily Note，最后悄悄重读一遍对齐（失败时也靠它回滚）
    func deleteDaily(date: String, entry: DailyEntry, noteId: String?) async {
        guard hasIdeashell else { showNotice("先到「设置」填写闪念贝壳 API Key"); return }
        // 今天页的「今天的笔记」也先去掉这一条
        if date == Day.today(), var d = dailyToday, let j = d.entries.firstIndex(where: { $0.time == entry.time && $0.text == entry.text }) {
            d.entries.remove(at: j)
            dailyToday = d
        }
        if let noteId {
            noteCache.removeValue(forKey: noteId)
            if case let .note(n)? = calPane.page, n.id == noteId { calPane.clear() }
        }
        do {
            let ok = try await daily.deleteEntry(date: date, entry: entry)
            showNotice(ok ? "已删除这条日记" : "没找到这条日记，可能已经被改过")
        } catch {
            showNotice("删除失败：" + error.localizedDescription)
        }
        invalidateHistory()
        if date == Day.today() { Task { await loadDailyToday(ifStale: false) } }
        calendarLoadTick += 1
    }
}
