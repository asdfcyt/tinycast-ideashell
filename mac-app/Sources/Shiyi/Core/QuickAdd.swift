import Foundation

extension AppModel {
    func openQuickAdd(text: String = "", kind: CaptureKind? = nil, date: String? = nil, time: String? = nil) {
        quickAddText = text
        quickAddKind = kind
        quickAddDate = date
        quickAddTime = time
        showQuickAdd = true
    }

    /// 标题栏的加号 / ⌘N：在日历里按「添加待办」处理（带上选中的日子），其他页面是普通的万能输入
    func openQuickAddHere() {
        if section == .calendar {
            openQuickAdd(kind: .todo, date: calendarDay >= Day.today() ? calendarDay : nil)
        } else {
            openQuickAdd()
        }
    }

    /// 万能输入的提交：按类型分流（待办 → 滴答；Daily Note → 追加到今天；笔记 → 新建，可带标签 / 文件夹）。返回给用户看的结果文案。
    /// `priority`：只对待办有效；`defaultDate`：待办没写日期时用（日历里点「添加待办」带进来）。
    func submitCapture(_ a: CaptureAnalysis, kind: CaptureKind, priority: Int = 0, defaultDate: String? = nil, defaultTime: String? = nil) async throws -> String {
        switch kind {
        case .todo:
            let title = a.todo.content.trimmed
            guard !title.isEmpty else { throw McpError.tool("待办内容为空") }
            let date = a.todo.date ?? defaultDate
            // 自己写了日期就按自己写的；没写日期、用的是日历带进来的日子，就用点出来的时间
            let time = date == nil ? nil : (a.todo.time ?? (a.todo.date == nil ? defaultTime : nil))
            if hasDida {
                try await dida.createTask(title: title, date: date, time: time, priority: priority)
                invalidateHistory()
                Task {
                    await loadOverview(silent: true)
                    if section == .calendar { await loadCalendar() }
                    if section == .review { await loadRiver(silent: true) }
                }
            } else if hasIdeashell {
                try await ideashell.createTodo(title, date: date, time: time)
            } else {
                throw McpError.noCredential
            }
            return "已添加待办" + (date.map { " · " + Day.label($0) + (time.map { " " + $0 } ?? "") } ?? "")

        case .daily:
            guard hasIdeashell else { throw McpError.noCredential }
            let text = a.text.trimmed
            guard !text.isEmpty else { throw McpError.tool("内容为空") }
            try await daily.append(text, at: Date())
            invalidateHistory()
            Task { await loadDailyToday(ifStale: false) }
            Task { if section == .review { await loadRiver(silent: true) } }
            return "已记入今天的 Daily Note"

        case .clue, .evidence, .regulation:
            // 结审：不经过闪念贝壳 / 滴答，直接存进钉住的审计项目
            guard hasSjz else { throw McpError.tool("先到「设置」开启并连接结审") }
            let text = a.text.trimmed
            guard !text.isEmpty else { throw McpError.tool("内容为空") }
            if kind == .clue {
                await refreshSjzTarget()
                let place = sjzTargetTitle.isEmpty ? "" : "（\(sjzTargetTitle)）"
                _ = try await sjz.addClue(project: nil, text: text, tags: a.tags)
                return "已记入线索" + place
            }
            var raw = RawDrop()
            raw.text = text
            return try await submitSjz(raw, to: kind == .evidence ? .evidence : .regulation)

        case .note:
            guard hasIdeashell else { throw McpError.noCredential }
            let body = a.body.trimmed
            guard !body.isEmpty else { throw McpError.tool("内容为空") }
            var folder: IdeashellApi.Folder?
            var folderNote = ""
            let folders = (try? await ideashell.listFolders()) ?? []
            if let name = a.folderName {
                folder = CaptureParser.matchFolder(name, folders: folders)
                if folder == nil { folderNote = "（文件夹「\(name)」不存在，已放在未归档）" }
            } else {
                folder = CaptureParser.inferFolder(body, folders: folders)
            }
            let first = body.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmed ?? body
            try await ideashell.createNote(title: String(first.prefix(30)), body: body, tags: a.tags, folderId: folder?.id)
            invalidateHistory()
            Task {
                await loadTimeline(silent: true)
                if section == .review { await loadRiver(silent: true) }
            }
            return "已保存笔记" + (folder.map { " 📁" + $0.name } ?? "") + folderNote
        }
    }

    /// 主窗口里的短暂提示
    func showNotice(_ text: String) {
        notice = text
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if notice == text { notice = nil }
        }
    }
}
