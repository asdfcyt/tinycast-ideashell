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
    func submitCapture(_ a: CaptureAnalysis, kind: CaptureKind, priority: Int = 0, defaultDate: String? = nil, defaultTime: String? = nil, images: [ComposerImage] = [], newNote: String? = nil) async throws -> String {
        switch kind {
        case .todo:
            let title = a.todo.content.trimmed
            guard !title.isEmpty else { throw McpError.tool("待办内容为空") }
            let date = a.todo.date ?? defaultDate
            // 自己写了日期就按自己写的；没写日期、用的是日历带进来的日子，就用点出来的时间
            let time = date == nil ? nil : (a.todo.time ?? (a.todo.date == nil ? defaultTime : nil))
            if hasDida {
                if let t = try await dida.createTask(title: title, date: date, time: time, priority: priority) { lastCreated = .todo(t) }
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
            let fitted = try await fitNoteImages(images)
            var text = ComposerImage.stripMarker(a.text).trimmed
            guard !text.isEmpty || !fitted.isEmpty else { throw McpError.tool("内容为空") }
            // 只贴了图没写字：条目里留一个占位，图片作为附件挂在今天的 Daily Note 上
            if text.isEmpty { text = "[图片 \(fitted.count) 张]" }
            let now = Date()
            try await daily.append(text, at: now, images: fitted)
            let c = Day.cal.dateComponents([.hour, .minute], from: now)
            let flat = text.components(separatedBy: .newlines).map(\.trimmed).filter { !$0.isEmpty }.joined(separator: " ")
            lastCreated = .daily(date: Day.string(now), entry: DailyEntry(time: String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0), text: flat))
            invalidateHistory()
            Task { await loadDailyToday(ifStale: false) }
            Task { if section == .review { await loadRiver(silent: true) } }
            return "已记入今天的 Daily Note" + (fitted.isEmpty ? "" : " · \(fitted.count) 张图片")

        case .clue, .idea, .evidence, .regulation:
            // 结审：不经过闪念贝壳 / 滴答，直接存进钉住的审计项目；文字和图片按顺序混排
            guard hasSjz else { throw McpError.tool("先到「设置」开启并连接结审") }
            guard !a.text.trimmed.isEmpty || !images.isEmpty else { throw McpError.tool("内容为空") }
            return try await submitSjzCompose(text: a.text, tags: a.tags, images: images, kind: kind, newNote: newNote)

        case .note:
            guard hasIdeashell else { throw McpError.noCredential }
            let fitted = try await fitNoteImages(images)
            let body = ComposerImage.stripMarker(a.body).trimmed
            guard !body.isEmpty || !fitted.isEmpty else { throw McpError.tool("内容为空") }
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
            let title = first.isEmpty ? "图片笔记 " + Self.clockLabel(Date()) : String(first.prefix(30))
            try await ideashell.createNote(title: title, body: body, tags: a.tags, folderId: folder?.id, images: fitted)
            invalidateHistory()
            Task {
                await loadTimeline(silent: true)
                if section == .review { await loadRiver(silent: true) }
            }
            return "已保存笔记" + (fitted.isEmpty ? "" : " · \(fitted.count) 张图片") + (folder.map { " 📁" + $0.name } ?? "") + folderNote
        }
    }

    private static func clockLabel(_ d: Date) -> String {
        let c = Day.cal.dateComponents([.month, .day, .hour, .minute], from: d)
        return String(format: "%02d-%02d %02d:%02d", c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0)
    }

    /// 笔记 / Daily Note 的图片附件：压到服务端的上限内（单张 ≤ 5MB、最多 9 张）
    private func fitNoteImages(_ images: [ComposerImage]) async throws -> [(name: String, data: Data)] {
        guard !images.isEmpty else { return [] }
        guard images.count <= DropImages.maxImages else { throw McpError.tool("一次最多带 \(DropImages.maxImages) 张图片") }
        let fitted = await Task.detached(priority: .userInitiated) {
            images.enumerated().compactMap { i, im -> (name: String, data: Data)? in
                let name = im.name.trimmed.isEmpty ? "图片-\(i + 1)" : im.name
                guard let r = DropImages.fit(im.data, name: name) else { return nil }
                return (name: r.name, data: r.data)
            }
        }.value
        guard !fitted.isEmpty else { throw McpError.tool("图片读取失败，请换一张试试") }
        return fitted
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
