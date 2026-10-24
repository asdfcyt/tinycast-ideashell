import Foundation

/// 专注中记录（移植自安卓端 `FocusRecordActivity` + `ProjectService.recordFocus`）：
/// 有关联待办：第一次记录时给这个任务建任务笔记，之后每条追加到笔记的「进展记录」，并同步成滴答任务评论；
/// 没关联待办（自由专注）：记进今天的 Daily Note，前面带「〔专注〕」。
/// 无论写没写成功，这条记录都已经留在本次专注里（页面上马上看得到，结束时进小结）。
extension AppModel {
    @discardableResult
    func recordFocus(_ text: String) async -> Bool {
        let line = text.trimmed
        guard !line.isEmpty, let run = focus.run, !run.kind.isBreak else { return false }
        focus.addRecord(line)
        recording = true
        defer { recording = false }

        // 结审任务：记录只写回结审（任务说明的「进展记录」+ 项目工作日志），不进闪念贝壳和滴答
        if let tid = run.taskId, let p = SjzTasks.parse(tid) {
            do {
                try await sjz.recordTaskActivity(project: p.project, id: p.task, text: line)
                await refreshSjzOverview(force: true)
                showNotice("已记到结审任务")
            } catch {
                showNotice("没能写进结审：" + error.localizedDescription + "（已记在本次专注里）")
            }
            return true
        }
        guard hasIdeashell else {
            showNotice("已记在本次专注里；填写闪念贝壳后才能写进笔记")
            return true
        }
        do {
            if let tid = run.taskId, !tid.isEmpty {
                guard let task = await findTask(tid) else {
                    throw NSError(domain: "Shiyi", code: 2, userInfo: [NSLocalizedDescriptionKey: "读不到滴答任务，无法创建任务笔记"])
                }
                var ref = taskNote(forTask: task)
                if ref == nil {
                    guard await createTaskNote(task, deliverable: task.cleanTitle, purpose: "", steps: "") else { return true }
                    ref = taskNote(for: task.id)
                }
                guard let ref else { return true }
                let detail = try await ideashell.noteFull(ref.noteId)
                let stamp = NoteSections.minuteStamp()
                let body = NoteSections.editSection(detail.content, title: "进展记录") { old in
                    old + (old.isEmpty ? "" : "\n") + "- \(stamp) \(line)"
                }
                try await ideashell.updateNoteBody(ref.noteId, body: body)
                var synced = false
                if hasDida {
                    synced = (try? await dida.addComment(projectId: task.projectId, taskId: task.id, text: "进展：" + line)) != nil
                }
                invalidateHistory()
                showNotice(synced ? "已记到任务笔记，并同步成滴答评论" : "已记到任务笔记")
            } else {
                let flat = RX(#"\s*\n\s*"#, multiline: false).replace(in: line, with: " ")
                try await daily.append("〔专注〕" + flat, at: Date())
                invalidateHistory()
                Task { await loadDailyToday(ifStale: false) }
                showNotice("已记到今天的 Daily Note")
            }
        } catch {
            showNotice("没能写进笔记：" + error.localizedDescription + "（已记在本次专注里）")
        }
        return true
    }
}
