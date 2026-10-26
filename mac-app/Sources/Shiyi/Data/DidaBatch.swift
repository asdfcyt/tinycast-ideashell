import Foundation

/// 滴答清单 MCP 的批量接口：一次请求改很多条，返回里带每一条的结果。
/// - `batch_update_tasks`：改字段（日期 / 优先级 / 标签 / 标题备注 / 恢复未完成），失败的任务在 `id2error`
/// - `batch_add_tasks`：批量新建，`items[i].taskId` 对应传入的第 i 条
/// - `complete_tasks_in_project`：同一清单里批量完成（一次最多 20 条），失败的在 `failedTaskIds`
/// - `move_task`：本来就是数组
/// 删除没有批量接口，只能一条一条（并发）发。
extension DidaApi {
    private static func object(_ text: String) -> [String: Any] {
        guard let d = text.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
        return o
    }

    /// 批量改字段；返回失败的 任务 id → 原因
    func batchUpdate(_ tasks: [JSON]) async throws -> [String: String] {
        guard !tasks.isEmpty else { return [:] }
        let text = try await mcp.callText("batch_update_tasks", ["tasks": tasks])
        let errs = (Self.object(text)["id2error"] as? [String: Any]) ?? [:]
        return errs.mapValues { "\($0)" }
    }

    /// 批量新建；返回和传入顺序一一对应的新任务 id（失败的那条是 nil）
    func batchAdd(_ tasks: [JSON]) async throws -> [String?] {
        guard !tasks.isEmpty else { return [] }
        let text = try await mcp.callText("batch_add_tasks", ["tasks": tasks, "client_timezone": TimeZone.current.identifier])
        var ids = [String?](repeating: nil, count: tasks.count)
        for it in (Self.object(text)["items"] as? [[String: Any]]) ?? [] {
            guard let i = it["index"] as? Int, ids.indices.contains(i), it["errorCode"] is NSNull || it["errorCode"] == nil else { continue }
            ids[i] = it["taskId"] as? String
        }
        return ids
    }

    /// 同一个清单里批量完成；返回失败的任务 id
    func completeMany(projectId: String, taskIds: [String]) async throws -> Set<String> {
        guard !taskIds.isEmpty else { return [] }
        let text = try await mcp.callText("complete_tasks_in_project", ["project_id": projectId, "task_ids": taskIds])
        return Set(((Self.object(text)["failedTaskIds"] as? [Any]) ?? []).compactMap { $0 as? String })
    }

    /// 批量换清单
    func moveMany(_ moves: [(from: String, to: String, taskId: String)]) async throws {
        guard !moves.isEmpty else { return }
        _ = try await mcp.callText("move_task", ["moves": moves.map { ["fromProjectId": $0.from, "toProjectId": $0.to, "taskId": $0.taskId] as JSON }])
    }

    /// 按任务 id 直接删（同步队列用，不需要整个任务）
    func deleteRaw(projectId: String, taskId: String) async throws {
        _ = try await mcp.callText("delete_task", ["project_id": projectId, "task_id": taskId])
    }

    /// 新建任务的字段（和 `createTask` 一致；批量新建要带清单 id）
    static func newTaskJSON(projectId: String, title: String, date: String?, time: String?, priority: Int) -> JSON {
        let tz = TimeZone.current.identifier
        var task: JSON = ["title": title, "projectId": projectId]
        if priority > 0 { task["priority"] = priority }
        if let date {
            let due = Day.dueString(date, time: time)
            task["startDate"] = due
            task["dueDate"] = due
            task["isAllDay"] = (time == nil)
            task["timeZone"] = tz
            task["reminders"] = [time != nil ? "TRIGGER:PT0S" : "TRIGGER:P0DT9H0M0S"]
        }
        return task
    }
}
