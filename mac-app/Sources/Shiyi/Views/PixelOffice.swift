import AppKit
import SwiftUI

// 像素办公室的数据来源：把派活账本 / 运行状态 / 审批整理成「几只猫、各自在干嘛」。
// 画面和素材见 PixelOfficeArt.swift（素材来自 Star-Office-UI，仅限非商用）。

// MARK: - 数据来源

/// 现在有哪些小人、各自什么状态
@MainActor
enum OfficeCast {
    static func build() -> [OfficeAgent] {
        let ledger = DispatchLedger.shared
        let runs = AgentRunTracker.shared
        let center = ApprovalCenter.shared

        struct Row {
            var id: String
            var name: String
            var color: Color
            var source: AgentSource?
            var target: String?
        }
        var rows: [Row] = []
        for t in DispatchTarget.available {
            let src = t.profile.source
            rows.append(Row(id: t.id, name: t.title, color: t.color, source: src == .cli ? nil : src, target: t.id))
        }
        let covered = Set(rows.compactMap(\.source))
        for src in [AgentSource.cursor, .opencode, .workbuddy, .claude] where !covered.contains(src) {
            let live = runs.runs.contains { $0.source == src } || center.pending.contains { $0.source == src } || AgentPrefs.isOn(src)
            if live { rows.append(Row(id: "src." + src.rawValue, name: src.title, color: src.color, source: src, target: nil)) }
        }

        let recent = Date().addingTimeInterval(-30 * 60)
        var out: [OfficeAgent] = []
        for r in rows {
            let job = r.target.flatMap { id in ledger.jobs.first { $0.target == id && $0.state.isActive } }
            let run = r.source.flatMap { s in runs.runs.first { $0.source == s } }
            let appr = r.source.flatMap { s in center.pending.first { $0.source == s } }
            let comp = center.completions.first { c in
                if let s = r.source { return c.source == s }
                return false
            }
            let failed = r.target.flatMap { id in
                ledger.jobs.first { $0.target == id && ($0.state == .failed || $0.state == .interrupted) && $0.dismissed != true && ($0.endedAt ?? $0.createdAt) > recent }
            }

            var a = OfficeAgent(id: r.id, name: r.name, color: r.color, mood: .idle)
            if let job {
                a.task = job.prompt
                a.started = job.startedAt ?? job.createdAt
                a.jobId = job.id
                a.jobActive = true
            } else if let run {
                a.started = run.started
                a.task = run.project
            }
            a.activity = run?.activity

            if let appr {
                a.mood = .waiting
                a.say = short(appr.heading)
            } else if let comp, !comp.failed {
                a.mood = .waiting
                a.say = short("做完了：" + comp.summary)
            } else if job != nil || run != nil {
                a.mood = .working
                a.say = short(run?.activity ?? job?.prompt ?? "")
            } else if let failed {
                a.mood = .error
                a.task = failed.prompt
                a.jobId = failed.id
                a.canRerun = failed.managed
                a.say = short(failed.message.isEmpty ? "没跑成" : failed.message)
            } else if let comp, comp.failed {
                a.mood = .error
                a.say = short(comp.summary)
            }
            out.append(a)
        }
        return out
    }

    private static func short(_ s: String) -> String? {
        let one = s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        if one.isEmpty { return nil }
        return one.count > 9 ? String(one.prefix(9)) + ".." : one
    }
}

