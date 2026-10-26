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
    /// 结审任务的计划开始日（nil = 清除）；滴答任务没有这个概念
    case startDate(String?)
    /// 结审任务所属的审计阶段
    case phase(String)
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
        guard hasDida || SjzTasks.owns(task.id) else { return }
        if case .startDate = change, !SjzTasks.owns(task.id) { return }
        if case .phase = change, !SjzTasks.owns(task.id) { return }
        var n = localTask(task.id) ?? task
        switch change {
        case let .priority(p): n.priority = p
        case let .schedule(d, t): n.date = d; n.time = t
        case .clearDate: n.date = nil; n.time = nil
        case let .list(id): n.projectId = id
        case let .tags(t): n.tags = t
        case let .details(title, content, tags): n.title = title; n.content = content; n.tags = tags
        case let .startDate(d): n.startDate = d
        case let .phase(p): n.phase = p
        }
        let before = overview
        if var ov = overview {
            if n.done {
                ov = ov.withoutTask(task.id)
                if let i = ov.done.firstIndex(where: { $0.id == n.id }) { ov.done[i] = n }
            } else {
                ov = ov.placing(n)
            }
            overview = ov
        }
        if calendarTasks[task.id] != nil { calendarTasks[task.id] = n }
        invalidateHistory()
        showNotice("已修改")
        if SyncQueue.handles(task) {
            // 本机已经改好，进同步队列，稍后和别的改动一起批量发
            let op: SyncQueue.Op
            switch change {
            case let .priority(p): op = .priority(p)
            case let .schedule(d, t): op = .schedule(date: d, time: t)
            case .clearDate: op = .clearDate
            case let .list(id): op = .move(id)
            case let .tags(t): op = .tags(t)
            case let .details(title, content, tags): op = .details(title: title, content: content, tags: tags)
            case .startDate, .phase: return
            }
            SyncQueue.shared.enqueue(task, op, model: self)
            return
        }
        if SjzTasks.owns(task.id) {
            // 结审任务：本机已改好，进结审同步队列后立刻返回，不等网络、也不去重拉滴答概览
            do {
                switch change {
                case let .priority(p): try await dida.setPriority(task, p)
                case let .schedule(d, t): try await dida.reschedule(task, date: d, time: t)
                case .clearDate: try await dida.clearDate(task)
                case let .details(title, content, tags): try await dida.setDetails(task, title: title, content: content, tags: tags)
                case let .startDate(d): try await dida.setStartDate(task, d)
                case let .phase(p): try await dida.setPhase(task, p)
                case .list, .tags: break
                }
            } catch {
                overview = before
                showNotice("修改失败：" + error.localizedDescription)
            }
            return
        }
        do {
            switch change {
            case let .priority(p): try await dida.setPriority(task, p)
            case let .schedule(d, t): try await dida.reschedule(task, date: d, time: t)
            case .clearDate: try await dida.clearDate(task)
            case let .list(id): try await dida.move(task, toProject: id)
            case let .tags(t): try await dida.setTags(task, t)
            case let .details(title, content, tags): try await dida.setDetails(task, title: title, content: content, tags: tags)
            case let .startDate(d): try await dida.setStartDate(task, d)
            case let .phase(p): try await dida.setPhase(task, p)
            }
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
