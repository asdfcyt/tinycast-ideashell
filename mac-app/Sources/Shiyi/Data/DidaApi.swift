import Foundation

/// 滴答清单 MCP 的封装：拉取概览 / 完成 / 恢复 / 区间任务
struct DidaApi {
    let mcp: McpClient

    private var tz: String { TimeZone.current.identifier }

    func complete(_ task: DidaTask) async throws {
        _ = try await mcp.callText("complete_task", ["project_id": task.projectId, "task_id": task.id])
    }

    /// 新建任务。没有日期 = 无日期任务（进滴答收集箱）；有具体时间：准点提醒；只有日期：当天 9:00 提醒。
    /// priority：0 无 / 1 低 / 3 中 / 5 高
    @discardableResult
    func createTask(title: String, date: String?, time: String?, priority: Int) async throws -> DidaTask? {
        var task: JSON = ["title": title]
        if priority > 0 { task["priority"] = priority }
        if let date {
            let due = Day.dueString(date, time: time)
            task["startDate"] = due
            task["dueDate"] = due
            task["isAllDay"] = (time == nil)
            task["timeZone"] = tz
            task["reminders"] = [time != nil ? "TRIGGER:PT0S" : "TRIGGER:P0DT9H0M0S"]
        }
        let text = try await mcp.callText("create_task", ["task": task, "client_timezone": tz])
        return DidaParser.extractTasks(text).first { $0.title == title }
    }

    /// 删除任务（滴答里会进「已删除」）
    func deleteTask(_ task: DidaTask) async throws {
        _ = try await mcp.callText("delete_task", ["project_id": task.projectId, "task_id": task.id])
    }

    /// 改期；time 为 nil 表示全天（当天 9:00 提醒），否则准点提醒
    func reschedule(_ task: DidaTask, date: String, time: String?) async throws {
        let due = Day.dueString(date, time: time)
        _ = try await mcp.callText("update_task", [
            "task_id": task.id,
            "task": [
                "id": task.id,
                "projectId": task.projectId,
                "startDate": due,
                "dueDate": due,
                "isAllDay": time == nil,
                "timeZone": tz,
                "reminders": [time != nil ? "TRIGGER:PT0S" : "TRIGGER:P0DT9H0M0S"],
            ] as JSON,
            "client_timezone": tz,
        ])
    }

    private func updateFields(_ task: DidaTask, _ fields: JSON) async throws {
        var t: JSON = ["id": task.id, "projectId": task.projectId]
        for (k, v) in fields { t[k] = v }
        _ = try await mcp.callText("update_task", ["task_id": task.id, "task": t, "client_timezone": tz])
    }

    /// 优先级：0 无 / 1 低 / 3 中 / 5 高
    func setPriority(_ task: DidaTask, _ priority: Int) async throws {
        try await updateFields(task, ["priority": priority])
    }

    /// 整体替换标签（不带 #）
    func setTags(_ task: DidaTask, _ tags: [String]) async throws {
        try await updateFields(task, ["tags": tags])
    }

    /// 清除日期（滴答约定：日期设成 1970-01-01 表示清除）
    func clearDate(_ task: DidaTask) async throws {
        let zero = "1970-01-01T00:00:00.000+0000"
        try await updateFields(task, ["startDate": zero, "dueDate": zero])
    }

    /// 移动到另一个清单（含收集箱）
    func move(_ task: DidaTask, toProject: String) async throws {
        _ = try await mcp.callText("move_task", ["moves": [["fromProjectId": task.projectId, "toProjectId": toProject, "taskId": task.id] as JSON]])
    }

    /// 给任务写一条评论（在滴答 / 手机上也能看到最新进展）；滴答评论最长 1024 个字符
    func addComment(projectId: String, taskId: String, text: String) async throws {
        let t = text.trimmed
        let title = t.count > 1000 ? String(t.prefix(1000)) + "…" : t
        _ = try await mcp.callText("add_comment", ["project_id": projectId, "task_id": taskId, "title": title])
    }

    /// 改任务备注（整段覆盖）
    func setContent(_ task: DidaTask, content: String) async throws {
        _ = try await mcp.callText("update_task", [
            "task_id": task.id,
            "task": ["id": task.id, "projectId": task.projectId, "content": content] as JSON,
            "client_timezone": tz,
        ])
    }

    /// 把已完成的任务恢复为未完成（撤销完成）
    func reopen(_ task: DidaTask) async throws {
        _ = try await mcp.callText("update_task", [
            "task_id": task.id,
            "task": ["id": task.id, "projectId": task.projectId, "status": 0],
            "client_timezone": tz,
        ])
    }

    func projectNames() async throws -> [String: String] {
        DidaParser.extractProjects(try await mcp.callText("list_projects", [:]))
    }

    private func rangeArgs(_ from: String, _ toInclusive: String) -> JSON {
        [
            "search": [
                "startDate": Day.dueString(from),
                "endDate": Day.dueString(Day.add(toInclusive, days: 1)),
            ],
            "client_timezone": tz,
        ]
    }

    private struct Call {
        let key: String
        let tool: String
        let args: JSON
    }

    /// 概览：逾期（近 13 天）/ 今天起 7 天 / 最近完成（近 3 天）/ 收集箱无日期任务。
    /// 接口单次最多 14 天；区间查询与「今天 / 未来 7 天」两种方式各拉一遍再合并，互相补漏。
    func fetchOverview() async throws -> DidaOverview {
        let today = Day.today()
        func q(_ command: String) -> JSON { ["query_command": command, "client_timezone": tz] }
        let calls: [Call] = [
            Call(key: "undone_overdue", tool: "list_undone_tasks_by_date", args: rangeArgs(Day.add(today, days: -13), today)),
            Call(key: "undone_upcoming", tool: "list_undone_tasks_by_date", args: rangeArgs(Day.add(today, days: -1), Day.add(today, days: 7))),
            Call(key: "undone_today", tool: "list_undone_tasks_by_time_query", args: q("today")),
            Call(key: "undone_next7", tool: "list_undone_tasks_by_time_query", args: q("next7day")),
            Call(key: "completed", tool: "list_completed_tasks_by_date", args: rangeArgs(Day.add(today, days: -3), today)),
            Call(key: "undone_inbox", tool: "get_project_with_undone_tasks", args: ["project_id": "inbox"]),
        ]

        async let projectsAsync: [String: String] = (try? await projectNames()) ?? [:]

        let results: [String: Result<String, Error>] = await withTaskGroup(of: (String, Result<String, Error>).self) { group in
            for c in calls {
                group.addTask {
                    do { return (c.key, .success(try await mcp.callText(c.tool, c.args))) }
                    catch { return (c.key, .failure(error)) }
                }
            }
            var dict: [String: Result<String, Error>] = [:]
            for await (k, r) in group { dict[k] = r }
            return dict
        }
        let projects = await projectsAsync

        let failures = results.filter { if case .failure = $0.value { return true } else { return false } }
        if failures.count == calls.count, case let .failure(err)? = failures.values.first { throw err }

        func tasksOf(_ key: String) -> [DidaTask] {
            if case let .success(text)? = results[key] { return DidaParser.extractTasks(text) }
            return []
        }

        let limit = Day.add(today, days: 7)
        var open: [String: DidaTask] = [:]
        var order: [String] = []
        for key in ["undone_overdue", "undone_upcoming", "undone_today", "undone_next7"] {
            for t in tasksOf(key) {
                guard let d = t.date, !t.done, d <= limit, open[t.id] == nil else { continue }
                open[t.id] = t
                order.append(t.id)
            }
        }
        let all = order.compactMap { open[$0] }

        var undated = tasksOf("undone_inbox").filter { !$0.done && $0.date == nil }
        undated.sort { ($0.createdAt ?? 0) > ($1.createdAt ?? 0) }

        var done = tasksOf("completed").map { t -> DidaTask in var c = t; c.done = true; return c }
        done.sort { ($0.completedAt ?? 0) > ($1.completedAt ?? 0) }

        var warning: String?
        if !failures.isEmpty {
            warning = "部分滴答请求失败：" + failures.map { "\($0.key)：\(($0.value.failureMessage))" }.joined(separator: "；")
        }
        return DidaOverview(
            overdue: all.filter { $0.date! < today },
            upcoming: all.filter { $0.date! >= today },
            undated: Array(undated.prefix(100)),
            done: done,
            projects: projects,
            warning: warning
        )
    }

    /// 查单个任务；查不到返回 nil
    func fetchTask(_ taskId: String) async -> DidaTask? {
        guard let text = try? await mcp.callText("get_task_by_id", ["task_id": taskId]) else { return nil }
        return DidaParser.extractTasks(text).first
    }

    /// 指定日期范围内的任务（未完成 + 已完成），日历用。接口单次最多 14 天，按 14 天一段并行拉取；全部失败才抛异常。
    func tasksInRange(_ from: String, _ to: String) async throws -> [DidaTask] {
        var windows: [(String, String)] = []
        var cursor = from
        while cursor <= to {
            let end = min(Day.add(cursor, days: 13), to)
            windows.append((cursor, end))
            cursor = Day.add(end, days: 1)
        }
        let results: [Result<[DidaTask], Error>] = await withTaskGroup(of: Result<[DidaTask], Error>.self) { group in
            for (a, b) in windows {
                group.addTask {
                    do {
                        let undone = try await mcp.callText("list_undone_tasks_by_date", rangeArgs(a, b))
                        return .success(DidaParser.extractTasks(undone).filter { !$0.done })
                    } catch { return .failure(error) }
                }
                group.addTask {
                    do {
                        let done = try await mcp.callText("list_completed_tasks_by_date", rangeArgs(a, b))
                        return .success(DidaParser.extractTasks(done).map { t in var c = t; c.done = true; return c })
                    } catch { return .failure(error) }
                }
            }
            var out: [Result<[DidaTask], Error>] = []
            for await r in group { out.append(r) }
            return out
        }
        if !results.isEmpty, results.allSatisfy({ if case .failure = $0 { return true } else { return false } }),
           case let .failure(err)? = results.first { throw err }
        var seen = Set<String>()
        var out: [DidaTask] = []
        for r in results { if case let .success(ts) = r { for t in ts where seen.insert("\(t.id)|\(t.done)").inserted { out.append(t) } } }
        return out
    }

    /// 区间内已完成的任务（回顾用）。接口单次最多 14 天，长范围按 14 天一段并行拉取；全部失败才抛异常。
    func completedInRange(_ from: String, _ to: String) async throws -> [DidaTask] {
        var windows: [(String, String)] = []
        var cursor = from
        while cursor <= to {
            let end = min(Day.add(cursor, days: 13), to)
            windows.append((cursor, end))
            cursor = Day.add(end, days: 1)
        }
        let results: [Result<[DidaTask], Error>] = await withTaskGroup(of: Result<[DidaTask], Error>.self) { group in
            for (a, b) in windows {
                group.addTask {
                    do {
                        let text = try await mcp.callText("list_completed_tasks_by_date", rangeArgs(a, b))
                        return .success(DidaParser.extractTasks(text).map { t in var c = t; c.done = true; return c })
                    } catch { return .failure(error) }
                }
            }
            var out: [Result<[DidaTask], Error>] = []
            for await r in group { out.append(r) }
            return out
        }
        if !results.isEmpty, results.allSatisfy({ if case .failure = $0 { return true } else { return false } }),
           case let .failure(err)? = results.first { throw err }
        var seen = Set<String>()
        var out: [DidaTask] = []
        for r in results { if case let .success(ts) = r { for t in ts where seen.insert(t.id).inserted { out.append(t) } } }
        return out
    }
}

private extension Result {
    var failureMessage: String {
        if case let .failure(e) = self { return e.localizedDescription }
        return ""
    }
}
