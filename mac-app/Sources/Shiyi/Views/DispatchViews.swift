import AppKit
import SwiftUI

// MARK: - 灵动岛里的「派活」行

/// 岛上的派活区：排队 / 等待重试 / 刚失败的派活（运行中的已经在运行状态条里：opencode 由插件上报，其他命令行由账本上报）
extension AgentAccess {
    /// 「完全放开」要二次确认：设置和工作台共用
    @MainActor static func confirmFull(for name: String) -> Bool {
        let a = NSAlert()
        a.messageText = "让 \(name) 完全放开权限？"
        a.informativeText = "它可以不经询问地改文件、执行命令。派活的内容里如果混进了恶意指令，后果由这档权限决定。"
        a.addButton(withTitle: "取消")
        a.addButton(withTitle: "完全放开")
        return a.runModal() == .alertSecondButtonReturn
    }
}

struct DispatchStripRows: View {
    @ObservedObject private var ledger = DispatchLedger.shared

    static func rows(_ jobs: [LedgerJob]) -> [LedgerJob] {
        let now = Date()
        return Array(jobs.filter { j in
            guard j.managed, j.dismissed != true else { return false }
            switch j.state {
            case .queued, .retrying: return true
            case .failed: return now.timeIntervalSince(j.endedAt ?? .distantPast) < 900
            default: return false
            }
        }.prefix(4))
    }

    var body: some View {
        ForEach(Self.rows(ledger.jobs)) { j in DispatchStripRow(j: j) }
    }
}

private struct DispatchStripRow: View {
    let j: LedgerJob
    private var ledger: DispatchLedger { DispatchLedger.shared }

    private var tint: Color { DispatchTarget(rawValue: j.target)?.color ?? .gray }

    private var status: (text: String, color: Color) {
        switch j.state {
        case .queued: return ("排队中", .secondary)
        case .retrying:
            let at = j.nextRetryAt.map { Self.clock($0) } ?? ""
            return ("第 \(j.attempts) 次没跑成 · \(at) 重试", .yellow)
        case .failed: return ("没跑成 · " + String(j.message.replacingOccurrences(of: "\n", with: " ").suffix(50)), .red)
        default: return (j.state.label, .secondary)
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 9) {
                Image(systemName: DispatchTarget(rawValue: j.target)?.icon ?? "terminal").font(.system(size: 10.5, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 22, height: 22).background(tint.gradient, in: Circle())
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(j.targetTitle).font(.system(size: 12, weight: .semibold))
                        Text("·").foregroundStyle(.tertiary)
                        Text(j.prompt.replacingOccurrences(of: "\n", with: " ")).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                    }
                    Text(status.text).font(.system(size: 11)).foregroundStyle(status.color).lineLimit(1).truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            switch j.state {
            case .queued, .retrying:
                circle("stop.fill", color: .red, help: "取消") { ledger.stop(j.id) }
            case .failed:
                circle("arrow.clockwise", color: .secondary, help: "重跑") { ledger.rerun(j.id) }
                circle("xmark", color: .secondary, help: "知道了") { ledger.dismiss(j.id) }
            default:
                EmptyView()
            }
        }
        .contentShape(Rectangle())
    }

    private func circle(_ symbol: String, color: Color, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 9, weight: .bold)).foregroundStyle(color)
                .frame(width: 22, height: 22).background(Color.primary.opacity(0.1), in: Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private static func clock(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDateInToday(d) ? "HH:mm" : "M月d日 HH:mm"
        return f.string(from: d)
    }
}

// MARK: - 派活详情（时间线）

struct DispatchJobDetail: View {
    let id: UUID
    @ObservedObject private var ledger = DispatchLedger.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let j = ledger.jobs.first(where: { $0.id == id }) {
            content(j)
        } else {
            VStack(spacing: 12) {
                Text("这条记录已经不在了").foregroundStyle(.secondary)
                Button("关闭") { dismiss() }
            }
            .padding(40).frame(width: 520)
        }
    }

    private func content(_ j: LedgerJob) -> some View {
        let target = DispatchTarget(rawValue: j.target)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: target?.icon ?? "terminal").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 26, height: 26).background((target?.color ?? .gray).gradient, in: Circle())
                Text(j.targetTitle).font(.system(size: 15, weight: .semibold))
                Text(j.state.label).font(.system(size: 12, weight: .medium)).foregroundStyle(Self.color(j.state))
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 18).padding(.vertical, 14)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    section("指令") {
                        Text(j.prompt).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    section("信息") {
                        VStack(alignment: .leading, spacing: 5) {
                            if !j.cwd.isEmpty { info("目录", (j.cwd as NSString).abbreviatingWithTildeInPath) }
                            if let a = j.access, let acc = AgentAccess(rawValue: a) { info("权限", acc.label) }
                            info("来源", j.origin + (j.hasMaterial ? " · 带资料" : ""))
                            if j.managed { info("尝试", "\(j.attempts) 次") }
                            if let d = j.duration { info("耗时", Self.duration(d)) }
                            if let sid = j.sessionId, !sid.isEmpty { info("会话", sid) }
                            if let u = j.usage {
                                info("用量", DispatchResult.compact(u.tokens) + " Token（输入 \(DispatchResult.compact(u.input)) · 输出 \(DispatchResult.compact(u.output))）"
                                    + (u.cost.map { String(format: " · $%.4f", $0) } ?? ""))
                            } else if j.managed, !j.state.isActive {
                                info("用量", "未上报")
                            }
                        }
                    }
                    if let r = j.result, !r.isEmpty {
                        section("结果") {
                            Text(r).textSelection(.enabled).font(.system(size: 12.5)).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else if !j.message.isEmpty {
                        section(j.state == .done ? "输出" : "说明") {
                            Text(j.message).textSelection(.enabled).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    section("时间线") {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(j.events.enumerated()), id: \.offset) { _, e in
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    Text(Self.time(e.at)).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.tertiary)
                                    Text(e.text).font(.system(size: 12.5))
                                }
                            }
                        }
                    }
                }
                .padding(18)
            }
            Divider()
            HStack(spacing: 10) {
                if j.managed {
                    if j.state.isActive {
                        Button("停止") { ledger.stop(j.id) }
                    } else {
                        Button("重跑") { ledger.rerun(j.id) }
                    }
                    Button("打开日志") { NSWorkspace.shared.open(DispatchLedger.logURL(j.id)) }
                }
                if j.hasMaterial {
                    Button("查看资料") { NSWorkspace.shared.open(DispatchLedger.materialURL(j.id)) }
                }
                if !j.cwd.isEmpty {
                    Button("打开目录") { NSWorkspace.shared.open(URL(fileURLWithPath: j.cwd)) }
                }
                Spacer()
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
        }
        .frame(width: 540, height: 600)
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ body: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.secondary)
            body()
        }
    }

    private func info(_ k: String, _ v: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(k).foregroundStyle(.secondary).frame(width: 40, alignment: .leading)
            Text(v).textSelection(.enabled).lineLimit(2).truncationMode(.middle)
        }
        .font(.system(size: 12.5))
    }

    private static func color(_ s: LedgerState) -> Color {
        switch s {
        case .queued, .running: return .orange
        case .retrying: return .yellow
        case .done: return .green
        case .failed: return .red
        case .cancelled, .interrupted: return .secondary
        }
    }

    private static func time(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDateInToday(d) ? "HH:mm:ss" : "M/d HH:mm:ss"
        return f.string(from: d)
    }

    private static func duration(_ s: TimeInterval) -> String {
        let n = Int(s)
        return n >= 60 ? "\(n / 60) 分 \(n % 60) 秒" : "\(n) 秒"
    }
}

// MARK: - 派活目标：添加 / 修改命令行

/// 自己加一个命令行 Agent：命令 + 参数模板（{prompt} 是你写的指令，{cwd} 是工作目录，{session} 是会话 id）。
/// 参数之间用空格分开；指令是作为一个整体参数传的，不经过 shell。
struct AgentProfileEditor: View {
    let existing: AgentProfile?
    var onSave: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var exe = ""
    @State private var args = "-p {prompt}"
    @State private var resume = ""
    @State private var aliases = ""
    @State private var readArgs = ""
    @State private var editArgs = ""
    @State private var fullArgs = ""
    @State private var error: String?

    private static func join(_ a: [String]) -> String { a.joined(separator: " ") }
    private static func split(_ s: String) -> [String] { s.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(existing == nil ? "添加命令行目标" : "修改「\(existing?.name ?? "")」").font(.system(size: 15, weight: .semibold))
                .padding(.horizontal, 18).padding(.vertical, 14)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    field("名称", "比如 Aider", $name)
                    field("命令", "命令名（aider）或完整路径", $exe)
                    field("参数", "含 {prompt}，比如 -p {prompt}；需要工作目录写 {cwd}", $args, mono: true)
                    field("接着聊（可空）", "有会话时追加，含 {session}，比如 --resume {session}", $resume, mono: true)
                    field("@ 别名（可空）", "空格分开，比如 aider ai", $aliases)
                    Text("三档权限各自追加的参数（可空）").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.secondary).padding(.top, 4)
                    field("只读", "", $readArgs, mono: true)
                    field("可改文件", "", $editArgs, mono: true)
                    field("完全放开", "", $fullArgs, mono: true)
                    if let error { Text(error).font(.caption).foregroundStyle(.red) }
                }
                .padding(18)
            }
            Divider()
            HStack(spacing: 10) {
                if let existing, !existing.builtin {
                    Button("删除", role: .destructive) {
                        AgentProfiles.remove(existing.id)
                        onSave()
                        dismiss()
                    }
                }
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") { save() }.keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
        }
        .frame(width: 500, height: 560)
        .onAppear(perform: load)
    }

    private func field(_ title: String, _ hint: String, _ text: Binding<String>, mono: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.secondary)
            TextField(hint, text: text).textFieldStyle(.roundedBorder).font(mono ? .system(size: 12.5, design: .monospaced) : .system(size: 13))
        }
    }

    private func load() {
        guard let p = existing else { return }
        name = p.name
        exe = p.exe
        args = Self.join(p.args)
        resume = Self.join(p.resume)
        aliases = Self.join(p.aliases)
        readArgs = Self.join(p.accessArgs["read"] ?? [])
        editArgs = Self.join(p.accessArgs["edit"] ?? [])
        fullArgs = Self.join(p.accessArgs["full"] ?? [])
    }

    private func save() {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let e = exe.trimmingCharacters(in: .whitespacesAndNewlines)
        let a = Self.split(args)
        guard !n.isEmpty else { error = "名称不能为空"; return }
        guard !e.isEmpty else { error = "命令不能为空"; return }
        guard a.contains(where: { $0.contains("{prompt}") }) else { error = "参数里要有 {prompt}，指令才传得进去"; return }
        let al = Self.split(aliases.lowercased())
        // 别名不能和别的目标重名，否则 @ 的时候分不清
        let others = AgentProfiles.all.filter { $0.id != (existing?.id ?? "") }
        if let clash = al.first(where: { x in others.contains { $0.aliases.contains(x) } }) { error = "别名「\(clash)」已被别的目标用了"; return }
        var p = existing ?? AgentProfile(id: Self.makeID(n), name: n)
        p.name = n
        p.kind = .command
        p.exe = e
        p.args = a
        p.resume = Self.split(resume)
        p.aliases = al.isEmpty ? [n.lowercased().replacingOccurrences(of: " ", with: "")] : al
        p.accessArgs = ["read": Self.split(readArgs), "edit": Self.split(editArgs), "full": Self.split(fullArgs)]
        if existing == nil { p.color = "blue"; p.icon = "terminal"; p.sourceName = "cli" }
        AgentProfiles.save(p)
        onSave()
        dismiss()
    }

    private static func makeID(_ name: String) -> String {
        let base = "custom-" + name.lowercased().filter { $0.isLetter || $0.isNumber }
        var id = base
        var k = 2
        while AgentProfiles.profile(id) != nil { id = base + "-\(k)"; k += 1 }
        return id
    }
}
