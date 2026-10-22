import Foundation

/// 项目主页笔记：模板与安卓端 `NoteSections.projectHomeBody` / `ProjectService.createHome` 一致
enum ProjectHomeBuilder {
    static func title(_ keyword: String) -> String {
        let t = keyword + " 项目主页"
        return t.count <= 30 ? t : String(t.prefix(29)) + "…"
    }

    static func body(keyword: String, tags: [String], links: String) -> String {
        [
            "## 目标\n（这个项目最终要达成什么？）",
            "## 交付成果\n（要交付的成果，而不是要做的事情。例如「完成一篇可发表的论文初稿」）",
            "## 任务笔记（自动汇总）\n" + (links.isEmpty ? "（还没有任务笔记）" : links),
            "## 项目状态（自动汇总）\n（在项目主页点「更新汇总」：下一步、成果进度、近 7 天专注）",
            "## 资料与链接\n- （把资料、链接贴在这里）",
            "## 里程碑与进展\n- \(NoteSections.minuteStamp()) 建立项目主页",
            "## 复盘与经验\n",
            "项目关键词：" + ([keyword] + tags).joined(separator: "、"),
        ].joined(separator: "\n\n")
    }
}

extension AppModel {
    /// 云端备份里的 + 本机新建的项目主页（关键词 → 笔记 id）
    var allHomes: [String: String] {
        (backup?.workspace.homes ?? [:]).merging(localHomes) { _, local in local }
    }

    func homeOf(_ keyword: String) -> String? { allHomes[keyword] }

    private func saveLocalHomes() {
        if let d = try? JSONEncoder().encode(localHomes), let text = String(data: d, encoding: .utf8) {
            LocalStore.write("homes.json", text)
        }
    }

    /// 新建项目主页笔记。笔记里已经有同名的（比如在手机端建过）就直接用，不重复创建。返回笔记 id
    func createProjectHome(_ p: Project) async -> String? {
        guard hasIdeashell else { showNotice("先到「设置」填写闪念贝壳 API Key"); return nil }
        let title = ProjectHomeBuilder.title(p.keyword)
        func key(_ t: String) -> String { t.trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "#")).trimmed.lowercased() }
        do {
            let found = (try? await ideashell.searchNotes(p.keyword + " 项目主页", limit: 20)) ?? []
            let kw = key(p.keyword)
            let hit = found.first { $0.title.trimmed == title }
                ?? found.first { n in let tags = n.tags.map(key); return tags.contains("项目主页") && tags.contains(kw) }
            if let hit {
                localHomes[p.keyword] = hit.id
                saveLocalHomes()
                return hit.id
            }
            let links = allTaskNotes
                .filter { ($0.value.project ?? "").lowercased() == p.keyword.lowercased() }
                .sorted { ($0.value.createdAt ?? 0) > ($1.value.createdAt ?? 0) }
                .map { "- [\($0.value.deliverable?.nonEmpty ?? "任务笔记")](\(noteURL($0.value.noteId).absoluteString))" }
                .joined(separator: "\n")
            let created = try await ideashell.createNote(
                title: title,
                body: ProjectHomeBuilder.body(keyword: p.keyword, tags: p.tags ?? [], links: links),
                tags: ["项目主页", p.keyword]
            )
            guard let id = TaskNoteBuilder.noteId(from: created) else {
                throw NSError(domain: "Shiyi", code: 1, userInfo: [NSLocalizedDescriptionKey: "没有从创建结果里取到笔记 id：" + String(created.prefix(100))])
            }
            localHomes[p.keyword] = id
            saveLocalHomes()
            showNotice("已创建项目主页笔记")
            return id
        } catch {
            showNotice("创建项目主页失败：" + error.localizedDescription)
            return nil
        }
    }
}
