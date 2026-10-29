import Foundation

/// 把笔记 / 结审记录交给便签，以及把结审的证据 / 法规 / 线索钉成「保存目标」
extension AppModel {
    // MARK: 使用便签打开

    /// 笔记：取全文放进一张新便签（拷贝，不是同一份：改便签不会改笔记）
    func openNoteAsSticky(_ id: String, title: String) {
        Task {
            do {
                let d = try await noteDetail(id)
                // 正文原样放进去（不加标题行）：写回时就是整篇覆盖笔记正文
                let src = StickySource(kind: "note", id: id, title: title, writable: true)
                StickyController.shared.create(text: d.content, source: src)
            } catch {
                showNotice("用便签打开失败：" + error.localizedDescription)
            }
        }
    }

    /// 结审记录（想法 / 证据 / 法规 / 线索）：去掉摘录标记和图片引用，放进一张新便签
    func openSjzAsSticky(project: String, capture c: SjzCapture) {
        Task {
            let detail = SjzDetailStore.cached(project: project, id: c.id)
            let d: SjzDetailStore.Detail?
            if let detail { d = detail } else { d = await SjzDetailStore.load(api: sjz, project: project, id: c.id) }
            let raw = d?.content ?? c.summary
            let lines = raw.components(separatedBy: "\n").filter { line in
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("<!--"), t.hasSuffix("-->") { return false }
                if t.range(of: "^!\\[[^\\]]*\\]\\[img\\d+\\]$", options: .regularExpression) != nil { return false }
                return true
            }
            var body = lines.joined(separator: "\n").trimmed
            let title = (c.title.isEmpty ? "" : c.title).mdPlain
            // 想法 / 线索：正文原样放进去，能写回（没有被去掉的摘录标记和图片引用时）。
            // 证据 / 法规带摘录和图片，写回会丢结构：只读，标题放在最前面
            let writable = (c.kind == "idea" || c.kind == "clue") && lines.count == raw.components(separatedBy: "\n").count && d != nil
            if !writable, !title.isEmpty, !body.hasPrefix("#") { body = "## \(title)\n\n\(body)" }
            let to: String
            switch c.kind {
            case "clue": to = "/suspicious?clue=" + AppModel.urlEnc(c.id)
            case "idea": to = c.logRel.isEmpty ? "/" : "/documents?open=" + AppModel.urlEnc(c.logRel)
            default: to = c.path.isEmpty ? "/documents" : "/documents?open=" + AppModel.urlEnc(c.path)
            }
            let src = StickySource(kind: "sjz", id: c.id, project: project, captureKind: c.kind, title: title, writable: writable, openTo: to)
            StickyController.shared.create(text: body, source: src)
        }
    }

    // MARK: 钉住

    /// 这条记录现在是不是钉着的（岛和万能输入都往它里面保存）
    func sjzIsPinned(_ c: SjzCapture, project: String) -> Bool {
        guard sjzPin.project == project else { return false }
        switch c.kind {
        case "evidence": return !sjzPin.evidencePath.isEmpty && sjzPin.evidencePath == c.path
        case "regulation": return !sjzPin.regulation.isEmpty && sjzPin.regulation == Self.regName(c)
        case "clue": return sjzPin.clueId == c.id
        default: return false
        }
    }

    func sjzCanPin(_ c: SjzCapture) -> Bool { ["evidence", "regulation", "clue"].contains(c.kind) }

    private static func regName(_ c: SjzCapture) -> String { (c.title.isEmpty ? c.summary : c.title).mdPlain }

    /// 钉住 / 取消钉住：项目不是当前项目时先把项目设为当前项目
    func sjzTogglePin(_ c: SjzCapture, project: String) async {
        if sjzIsPinned(c, project: project) {
            switch c.kind {
            case "evidence": await sjzUnpinNote()
            case "regulation": await sjzUnpinRegulation()
            default: await sjzUnpinClue()
            }
            showNotice("已取消钉住")
            return
        }
        if sjzPin.project != project { await sjzSetProject(project) }
        switch c.kind {
        case "evidence":
            // 只有项目里独立的 evidence/*.md 能追加
            guard c.path.hasPrefix("evidence/"), c.path.hasSuffix(".md"), !c.path.dropFirst(9).contains("/") else {
                showNotice("这条证据不是独立的证据文件，不能钉住")
                return
            }
            await sjzPin(evidence: c)
        case "regulation": await sjzPin(regulation: Self.regName(c))
        case "clue": await sjzPin(clue: c)
        default: return
        }
        if sjzError == nil { showNotice("已钉住：灵动岛和万能输入都会保存到它") }
    }
}
