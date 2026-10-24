import Foundation

extension AppModel {
    // MARK: - 节假日

    func loadHolidays() async {
        let h = await HolidayStore.load()
        if !h.isEmpty { holidays = h }
    }

    // MARK: - 时间河

    private static func capture<T>(_ body: () async throws -> T) async -> Result<T, Error> {
        do { return .success(try await body()) } catch { return .failure(error) }
    }

    /// 默认只展开今天、昨天；点日期头翻转
    func isRiverDayOpen(_ day: String) -> Bool {
        let byDefault = day >= Day.add(Day.today(), days: -1)
        return riverFlipped.contains(day) ? !byDefault : byDefault
    }

    func toggleRiverDay(_ day: String) {
        if riverFlipped.contains(day) { riverFlipped.remove(day) } else { riverFlipped.insert(day) }
    }

    func selectRiverPreset(_ p: RangePreset) {
        riverPreset = p
        riverFlipped.removeAll()
        Task { await loadRiver() }
    }

    func loadRiver(silent: Bool = false, ifStale: Bool = false) async {
        guard hasIdeashell || hasDida else { return }
        let stampKey = "\(riverPreset.rawValue)|\(Day.today())"
        if ifStale, river != nil, isFresh("river", key: stampKey) { return }
        guard beginLoad("river", ifStale: ifStale) else { return }
        defer { endLoad("river") }
        // 页面带着旧数据进来（ifStale）时悄悄更新，不转圈；换了时间范围才转
        if !silent && !(ifStale && river != nil) { riverLoading = true }
        defer { riverLoading = false }
        let (from, to) = riverPreset.range()
        let start = Day.startOfDay(Day.parse(from) ?? Date())
        let end = min(Date().addingTimeInterval(120), Day.startOfDay(Day.parse(Day.add(to, days: 1)) ?? Date()))
        let ideashell = self.ideashell, dida = self.dida, svc = self.daily
        let useNotes = hasIdeashell, useTodos = hasDida

        let notesR = Task { await Self.capture { () async throws -> NotesInRange in
            useNotes ? try await ideashell.notesInRange(start, end) : NotesInRange(notes: [], truncated: false)
        } }
        let tasksR = Task { await Self.capture { () async throws -> [DidaTask] in
            useTodos ? try await dida.tasksInRange(from, to) : []
        } }
        let dailyR = Task { await Self.capture { () async throws -> [String: DailyDay] in
            useNotes ? try await svc.days(from: from, to: to) : [:]
        } }
        let nr = await notesR.value, tr = await tasksR.value, dr = await dailyR.value

        var notes: [NoteInfo] = [], truncated = false, tasks: [DidaTask] = [], daily: [String: DailyDay] = [:]
        var errors: [String] = []
        switch nr {
        case let .success(r): notes = r.notes.filter { !BackupService.isBackupNote($0) }; truncated = r.truncated
        case let .failure(e): errors.append("笔记读取失败：" + e.localizedDescription)
        }
        var todoNote: String?
        switch tr {
        case let .success(t): tasks = t
        case let .failure(e): todoNote = "待办读取失败：" + e.localizedDescription
        }
        if !useTodos { todoNote = "还没有填写滴答清单 API 口令，这里不含待办" }
        switch dr {
        case let .success(d): daily = d
        case let .failure(e): errors.append("Daily Note 读取失败：" + e.localizedDescription)
        }
        riverError = errors.isEmpty ? nil : errors.joined(separator: "；")
        river = TimelineData.build(from: from, to: to, notes: notes, tasks: tasks, truncated: truncated, todoNote: todoNote, daily: daily)
        if errors.isEmpty && (todoNote == nil || !useTodos) { stamp("river", key: stampKey) }
        saveRiverCache()
    }

    /// 河里勾选 / 取消勾选待办
    func toggleTask(_ t: DidaTask) async {
        if t.done { await undoComplete(t) } else { await complete(t) }
        try? await Task.sleep(nanoseconds: 900_000_000)
        await loadRiver(silent: true)
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
        do {
            try await dida.reschedule(task, date: day, time: task.time)
            loadStamps.removeValue(forKey: "river")
            loadStamps.removeValue(forKey: "review")
            showNotice("已改到 \(Day.label(day))")
            await loadOverview(silent: true)
        } catch {
            if let old { calendarTasks[taskId] = old } else { calendarTasks.removeValue(forKey: taskId) }
            calendarError = "改期失败：" + error.localizedDescription
        }
    }
}
