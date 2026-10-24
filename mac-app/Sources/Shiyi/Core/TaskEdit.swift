import Foundation

/// 任务详情里可以改的东西
enum TaskEdit {
    case priority(Int)
    case schedule(date: String, time: String?)
    case clearDate
    /// 移到另一个滴答清单（含收集箱）
    case list(String)
    /// 整体替换标签（用来改「项目」：项目靠标签 / 关键词归属）
    case tags([String])
    /// 编辑任务：标题、备注、标签一起改
    case details(title: String, content: String, tags: [String])
}

extension AppModel {
    /// 收集箱的清单 id（滴答里是 inbox + 用户 id，从已有任务里认出来）
    var inboxId: String? {
        guard let ov = overview else { return nil }
        return (ov.overdue + ov.upcoming + ov.undated + ov.done).first { $0.projectId.lowercased().hasPrefix("inbox") }?.projectId
    }

    /// 可以移动到的滴答清单（名称排序，收集箱放第一个）
    var didaLists: [(id: String, name: String)] {
        var out: [(id: String, name: String)] = (overview?.projects ?? [:]).map { ($0.key, $0.value) }.sorted { $0.name < $1.name }
        if let inbox = inboxId, !out.contains(where: { $0.id == inbox }) { out.insert((inbox, "收集箱"), at: 0) }
        return out
    }

    /// 改任务：界面先动，再写进滴答，失败了回滚并提示
    func edit(_ task: DidaTask, _ change: TaskEdit) async {
        guard hasDida else { return }
        var n = localTask(task.id) ?? task
        switch change {
        case let .priority(p): n.priority = p
        case let .schedule(d, t): n.date = d; n.time = t
        case .clearDate: n.date = nil; n.time = nil
        case let .list(id): n.projectId = id
        case let .tags(t): n.tags = t
        case let .details(title, content, tags): n.title = title; n.content = content; n.tags = tags
        }
        let before = overview
        if var ov = overview {
            ov = ov.withoutTask(task.id)
            if n.done {
                if let i = ov.done.firstIndex(where: { $0.id == n.id }) { ov.done[i] = n }
            } else {
                if let d = n.date { if d < Day.today() { ov.overdue.append(n) } else { ov.upcoming.append(n) } } else { ov.undated.append(n) }
            }
            overview = ov
        }
        if calendarTasks[task.id] != nil { calendarTasks[task.id] = n }
        do {
            switch change {
            case let .priority(p): try await dida.setPriority(task, p)
            case let .schedule(d, t): try await dida.reschedule(task, date: d, time: t)
            case .clearDate: try await dida.clearDate(task)
            case let .list(id): try await dida.move(task, toProject: id)
            case let .tags(t): try await dida.setTags(task, t)
            case let .details(title, content, tags): try await dida.setDetails(task, title: title, content: content, tags: tags)
            }
            invalidateHistory()
            showNotice("已修改")
            await loadOverview(silent: true)
            if section == .calendar { await loadCalendar() }
        } catch {
            overview = before
            showNotice("修改失败：" + error.localizedDescription)
            await loadOverview(silent: true)
        }
    }

    /// 把任务归到某个本地项目：去掉能让原项目匹配上的标签，再加上新项目的关键词标签；nil = 移出项目
    func setProject(_ task: DidaTask, to new: Project?) async {
        let cur = localTask(task.id) ?? task
        var tags = cur.tags
        if let old = projectOf(cur) {
            let terms = Set(old.terms.map { $0.lowercased() })
            tags.removeAll { terms.contains($0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "#"))) }
        }
        if let new {
            let k = new.keyword
            if !tags.contains(where: { $0.lowercased() == k.lowercased() }) { tags.append(k) }
        }
        await edit(task, .tags(tags))
    }
}
