import Foundation
import SwiftUI

/*
 * 项目主页笔记在闪念贝壳里是一篇完整的笔记，用 `## 小节` 划分；项目页把每个小节拆成独立的组件来显示，
 * 往组件里「添加」的内容会写回那篇笔记对应的小节（和安卓端 ProjectHomeSections 同一套规则，两端互通）。
 *
 *   目标 / 交付成果      整节文字，可编辑
 *   里程碑与进展         带时间的记录，最新在上，可追加一行
 *   资料与链接           列表，链接可点开，可追加
 *   复盘与经验           带时间的段落，最新在上，可追加
 *   项目状态（自动汇总）  只读，「更新汇总」重新生成
 */

enum HomeSection {
    static let goal = "目标"
    static let deliver = "交付成果"
    static let links = "资料与链接"
    static let milestone = "里程碑与进展"
    static let review = "复盘与经验"
    static let status = "项目状态（自动汇总）"
    static let tasks = "任务笔记（自动汇总）"
}

enum HomeEditMode { case replace, link, milestone, review }

/// 点了某个组件的「添加 / 编辑」：对话框要写哪个小节、怎么写
struct HomeEdit: Identifiable {
    let id = UUID()
    var section: String
    var title: String
    var label: String
    var hint: String
    var initial: String
    var mode: HomeEditMode
}

@MainActor
final class ProjectHomeStore: ObservableObject {
    /// 主页笔记正文；nil = 还没读到（或没有主页笔记）
    @Published private(set) var text: String?
    @Published private(set) var loading = false
    /// 正在「更新汇总」
    @Published private(set) var busy = false
    @Published var error: String?

    private weak var model: AppModel?
    private var project: Project?

    /// 读过的主页正文按笔记 id 缓存：切回项目时先显示上次的，再静默刷新
    private static var cache: [String: String] = [:]

    func body(_ section: String) -> String? { text.flatMap { NoteSections.sectionBody($0, title: section) } }

    /// 读主页笔记；每次都读最新的（编辑发生在手机端也要能看到）
    func load(model: AppModel, project: Project) async {
        self.model = model
        self.project = project
        guard let id = model.homeOf(project.keyword), model.hasIdeashell else { text = nil; return }
        if text == nil, let cached = Self.cache[id] { text = cached }
        loading = true
        defer { loading = false }
        do {
            let latest = try await model.ideashell.noteFull(id).content
            text = latest
            Self.cache[id] = latest
            error = nil
        } catch {
            self.error = "读取项目主页失败：" + error.localizedDescription
        }
    }

    /// 往主页笔记的某个小节写内容：先改本机显示的正文（立刻看到），再同步到闪念贝壳；同步失败就还原并提示
    func save(section: String, mode: HomeEditMode, input: String) {
        guard let model, let project, let id = model.homeOf(project.keyword) else { return }
        let value = input.trimmed
        if value.isEmpty && mode != .replace { return }
        let fn: (String) -> String = { old in
            let kept = old.components(separatedBy: "\n").filter { !NoteSections.isPlaceholderLine($0) }.joined(separator: "\n").trimmed
            let gap = kept.isEmpty ? "" : "\n"
            switch mode {
            case .replace: return value
            case .link: return kept + gap + NoteSections.bullets(value)
            case .milestone:
                let one = RX(#"\s*\n\s*"#, multiline: false).replace(in: value, with: " ")
                return kept + gap + "- \(NoteSections.minuteStamp()) \(one)"
            case .review: return kept + (kept.isEmpty ? "" : "\n\n") + "\(NoteSections.minuteStamp())：\(value)"
            }
        }
        let before = text
        if let before { text = NoteSections.editSection(before, title: section, fn) }
        Task {
            do {
                // 以云端最新的为准再改一次，避免覆盖手机端刚写的内容
                let latest = try await model.ideashell.noteFull(id).content
                let updated = NoteSections.editSection(latest, title: section, fn)
                _ = try await model.ideashell.updateNoteBody(id, body: updated)
                model.noteCache[id] = nil
                text = updated
                Self.cache[id] = updated
            } catch {
                text = before
                model.showNotice("保存失败：" + error.localizedDescription)
            }
        }
    }

    /// 项目主页自动汇总：每个成果的状态、步骤进度、近 7 天专注，以及项目的下一步，写进主页笔记的两个小节。
    /// 全部是精确读取（任务状态 / `- [x]` 计数 / 专注记录），没有任何猜测（与安卓端 `refreshSummary` 一致）。
    func refreshSummary() async {
        guard let model, let project, let homeId = model.homeOf(project.keyword), !busy else { return }
        busy = true
        defer { busy = false }
        let notes = model.allTaskNotes
            .filter { ($0.value.project ?? "").lowercased() == project.keyword.lowercased() }
            .sorted { ($0.value.createdAt ?? 0) > ($1.value.createdAt ?? 0) }
            .prefix(15)
        let focus = model.focus.summary
        let hasDida = model.hasDida
        let dida = model.dida, api = model.ideashell

        struct Row { var line: String; var open: Bool; var delivered: Bool; var min: Int }
        let noteList = Array(notes)
        let rows: [Row] = await runConcurrently(noteList.count) { i in
            let e = noteList[i]
            let taskId = e.key.hasPrefix("dida:") ? String(e.key.dropFirst(5)) : e.key
            var state = "未知"
            if hasDida, !e.key.hasPrefix("cal:"), let t = await dida.fetchTask(taskId) { state = t.done ? "已交付" : "进行中" }
            let detail = try? await api.noteFull(e.value.noteId)
            let steps = detail.flatMap { NoteSections.stepProgress($0.content) }
            let min = focus?.byTask[taskId]?.weekMin ?? 0
            var parts = [state == "未知" ? "状态未知" : state]
            if let steps { parts.append("步骤 \(steps.done)/\(steps.total)") }
            if min > 0 { parts.append("近 7 天专注 \(FocusParser.formatMinutes(min))") }
            let name = e.value.deliverable?.nonEmpty ?? "任务笔记"
            return Row(line: "- [\(name)](\(noteURL(e.value.noteId).absoluteString)) · " + parts.joined(separator: " · "),
                       open: state != "已交付", delivered: state == "已交付", min: min)
        }
        let weekMin = rows.reduce(0) { $0 + $1.min }
        let status = [
            "更新于 \(Day.today())",
            "- 下一步：" + ((project.next?.trimmed).flatMap { $0.isEmpty ? nil : $0 } ?? "（还没写，在项目页设置）"),
            "- 成果：进行中 \(rows.filter(\.open).count) · 已交付 \(rows.filter(\.delivered).count)",
            "- 近 7 天专注（成果相关任务）：" + (weekMin > 0 ? FocusParser.formatMinutes(weekMin) : "无"),
        ].joined(separator: "\n")
        do {
            var content = try await api.noteFull(homeId).content
            content = NoteSections.editSection(content, title: HomeSection.tasks) { _ in
                rows.map(\.line).joined(separator: "\n").nonEmpty ?? "（还没有任务笔记）"
            }
            content = NoteSections.editSection(content, title: HomeSection.status) { _ in status }
            _ = try await api.updateNoteBody(homeId, body: content)
            model.noteCache[homeId] = nil
            text = content
            model.showNotice("已更新项目状态汇总")
        } catch {
            model.showNotice("更新汇总失败：" + error.localizedDescription)
        }
    }
}

// MARK: - 里程碑解析（移植自安卓端 milestoneEntries）

enum MilestoneEntry: Identifiable {
    /// 一个完成的成果：带复盘总结，和完成之前记过的过程
    case done(Done)
    /// 一句单独的记录
    case note(stamp: String, text: String)

    struct Done {
        var stamp: String
        var title: String
        var url: String?
        var review: [String]
        var process: [(stamp: String, text: String)]
    }

    var id: String {
        switch self {
        case let .done(d): return "done|" + d.title
        case let .note(s, t): return "note|" + s + "|" + t
        }
    }

    var stamp: String {
        switch self {
        case let .done(d): return d.stamp
        case let .note(s, _): return s
        }
    }
}

enum HomeParse {
    private static let stamped = RX(#"^(\d{4})-(\d{2}-\d{2})(?: (\d{2}:\d{2}))?[\s：:]*([\s\S]*)$"#, multiline: false)
    private static let done = RX(#"^完成[：:]\s*([\s\S]*?)(?:（\[任务笔记\]\(([^)\s]+)\)）)?$"#, multiline: false)
    private static let tagged = RX(#"^〔([^〕]*)〕\s*([\s\S]*)$"#, multiline: false)
    private static let reviewRe = RX(#"^复盘[：:]\s*([\s\S]*)$"#, multiline: false)
    static let mdLink = RX(#"\[([^\]]+)\]\(([^)\s]+)\)"#, multiline: false)
    private static let bareUrl = RX(#"https?://[^\s)]+"#, multiline: false)
    private static let boardId = RX(#"/boards/([a-f0-9]+)"#, multiline: false, ignoreCase: true)

    /// 去掉 Markdown 链接的外壳，只留文字
    static func plain(_ s: String) -> String { mdLink.replace(in: s, with: "$1") }

    static func firstUrl(_ s: String) -> String? {
        if let m = mdLink.first(in: s) { return m.group(2) }
        return bareUrl.first(in: s).map { $0.group(0) }
    }

    static func noteId(inUrl url: String) -> String? { boardId.first(in: url).map { $0.group(1) } }

    /// 小节正文按行拆成条目：去掉列表符号和占位行
    static func items(_ body: String?) -> [String] {
        (body ?? "").components(separatedBy: "\n")
            .filter { !NoteSections.isPlaceholderLine($0) }
            .map { l -> String in
                var t = l.trimmed
                if t.hasPrefix("-") || t.hasPrefix("*") { t = String(t.dropFirst()).trimmed }
                return t
            }
            .filter { !$0.isEmpty }
    }

    /// 小节正文按空行拆成段落
    static func paragraphs(_ body: String?) -> [String] {
        RX(#"\n\s*\n"#, multiline: false).re
            .splitKeepingEmpty(body ?? "")
            .map { $0.trimmed }
            .filter { !$0.isEmpty && !NoteSections.isPlaceholderLine($0) }
    }

    static func withoutPlaceholder(_ body: String?) -> String {
        (body ?? "").components(separatedBy: "\n").filter { !NoteSections.isPlaceholderLine($0) }.joined(separator: "\n").trimmed
    }

    /// 戳：「2026-10-23 21:30」
    static func stampOf(_ m: RXMatch) -> String {
        "\(m.group(1))-\(m.group(2))" + (m.group(3).isEmpty ? "" : " " + m.group(3))
    }

    /// 「10-23」
    static func shortStamp(_ s: String) -> String { s.count >= 10 ? String(s.dropFirst(5)) : s }

    /// 把「里程碑与进展」里的行整理成条目：「完成：成果」是一张卡，带上同一成果的「〔成果〕复盘：…」作为复盘总结，
    /// 同一成果的其他「〔成果〕…」记录归为折叠的过程；没有对应完成行的记录单独成行。最新在上。
    static func milestones(_ lines: [String]) -> [MilestoneEntry] {
        struct Ln { var stamp: String; var body: String }
        let rows: [Ln] = lines.map { line in
            if let m = stamped.first(in: line) { return Ln(stamp: stampOf(m), body: m.group(4).isEmpty ? line : m.group(4)) }
            return Ln(stamp: "", body: line)
        }
        let doneTitles = Set(rows.compactMap { r in done.first(in: r.body)?.group(1).trimmed }.filter { !$0.isEmpty })
        var review: [String: [String]] = [:]
        var process: [String: [(String, String)]] = [:]
        var out: [MilestoneEntry] = []
        for r in rows {
            if done.first(in: r.body) != nil { continue }
            if let t = tagged.first(in: r.body) {
                let tag = t.group(1).trimmed
                if doneTitles.contains(tag) {
                    let rest = t.group(2).trimmed
                    if let rv = reviewRe.first(in: rest) { review[tag, default: []].append(rv.group(1).trimmed) }
                    else { process[tag, default: []].append((r.stamp, rest)) }
                } else {
                    out.append(.note(stamp: r.stamp, text: "\(tag) · \(t.group(2).trimmed)"))
                }
            } else {
                out.append(.note(stamp: r.stamp, text: r.body))
            }
        }
        // 同一个成果可能完成过不止一次（重新打开再完成）：合并成一张卡，取最新的完成时间
        var order: [String] = []
        var dones: [String: (stamp: String, url: String?)] = [:]
        for r in rows {
            guard let d = done.first(in: r.body) else { continue }
            let title = d.group(1).trimmed.isEmpty ? "已完成" : d.group(1).trimmed
            let url = d.group(2).isEmpty ? nil : d.group(2)
            if let old = dones[title] {
                dones[title] = (max(old.stamp, r.stamp), url ?? old.url)
            } else {
                dones[title] = (r.stamp, url)
                order.append(title)
            }
        }
        for title in order {
            guard let v = dones[title] else { continue }
            var seenP = Set<String>()
            out.append(.done(.init(
                stamp: v.stamp, title: title, url: v.url,
                review: Array(NSOrderedSet(array: (review[title] ?? []).map { $0.trimmed }.filter { !$0.isEmpty })) as? [String] ?? [],
                process: (process[title] ?? []).filter { !$0.1.isEmpty && seenP.insert($0.1.trimmed).inserted }.map { (stamp: $0.0, text: $0.1) }
            )))
        }
        return out.sorted { $0.stamp > $1.stamp }
    }
}

private extension NSRegularExpression {
    /// 按匹配拆开字符串（保留空串，调用方自己过滤）
    func splitKeepingEmpty(_ s: String) -> [String] {
        let ns = s as NSString
        var parts: [String] = []
        var last = 0
        for m in matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            parts.append(ns.substring(with: NSRange(location: last, length: m.range.location - last)))
            last = m.range.location + m.range.length
        }
        parts.append(ns.substring(from: last))
        return parts
    }
}
