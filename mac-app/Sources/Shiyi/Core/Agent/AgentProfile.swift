import AppKit
import Foundation
import SwiftUI

/// 权限三档：翻译成各命令行自己的权限参数
enum AgentAccess: String, Codable, CaseIterable {
    case read, edit, full

    var label: String {
        switch self {
        case .read: return "只读"
        case .edit: return "可改文件"
        case .full: return "完全放开"
        }
    }
}

/// 数据驱动的派活目标：一份命令模板 + 会话续接 + 权限参数 + 输出解析方式。
/// 模板里的 `{prompt}` `{cwd}` `{session}` `{file}` `{dir}` 都作为独立参数传给进程（不经过 shell），指令里的任何字符都不会被当成命令执行。
struct AgentProfile: Codable, Identifiable, Hashable {
    enum Kind: String, Codable {
        /// WorkBuddy：通过辅助功能操作它的输入框
        case workbuddyUI
        /// 命令行
        case command
    }

    enum Parser: String, Codable {
        case text
        /// `claude -p --output-format json`：一个 JSON 对象，含 result / session_id / usage / total_cost_usd
        case claudeJSON
    }

    var id: String
    var name: String
    var kind: Kind = .command
    /// 命令名（在 PATH 和常见目录里找）或绝对路径
    var exe = ""
    /// 基础参数，含 {prompt}
    var args: [String] = []
    /// 接着已有会话时追加，含 {session}
    var resume: [String] = []
    /// 新开会话时追加，含 {session}（由拾忆生成会话 id，Claude Code 用）
    var newSession: [String] = []
    /// 带资料时追加：{file} = 资料文件，{dir} = 资料所在目录
    var fileArgs: [String] = []
    /// true = 命令行没法附加文件，只能把资料文件的路径写进提示词
    var materialByPath = false
    /// 三档权限各自追加的参数（键：read / edit / full）
    var accessArgs: [String: [String]] = [:]
    var parser: Parser = .text
    /// 万能输入里 @ 后面能写的名字（小写）
    var aliases: [String] = []
    var color = "gray"
    var icon = "terminal"
    /// 验收卡里归在哪个来源（影响图标和颜色）：opencode / claude / cli / workbuddy
    var sourceName = "cli"
    /// true = 这个 Agent 自己有钩子 / 插件接入拾忆（会弹验收卡）；false = 跑完由派活账本弹验收卡
    var hooked = false
    var builtin = false

    init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    // 自定义文件里的字段可以省略
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .command
        exe = try c.decodeIfPresent(String.self, forKey: .exe) ?? ""
        args = try c.decodeIfPresent([String].self, forKey: .args) ?? []
        resume = try c.decodeIfPresent([String].self, forKey: .resume) ?? []
        newSession = try c.decodeIfPresent([String].self, forKey: .newSession) ?? []
        fileArgs = try c.decodeIfPresent([String].self, forKey: .fileArgs) ?? []
        materialByPath = try c.decodeIfPresent(Bool.self, forKey: .materialByPath) ?? false
        accessArgs = try c.decodeIfPresent([String: [String]].self, forKey: .accessArgs) ?? [:]
        parser = try c.decodeIfPresent(Parser.self, forKey: .parser) ?? .text
        aliases = try c.decodeIfPresent([String].self, forKey: .aliases) ?? []
        color = try c.decodeIfPresent(String.self, forKey: .color) ?? "gray"
        icon = try c.decodeIfPresent(String.self, forKey: .icon) ?? "terminal"
        sourceName = try c.decodeIfPresent(String.self, forKey: .sourceName) ?? "cli"
        hooked = try c.decodeIfPresent(Bool.self, forKey: .hooked) ?? false
        builtin = false
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, kind, exe, args, resume, newSession, fileArgs, materialByPath, accessArgs, parser, aliases, color, icon, sourceName, hooked
    }

    var swiftColor: Color {
        switch color {
        case "orange": return .orange
        case "teal": return .teal
        case "purple": return .purple
        case "indigo": return .indigo
        case "blue": return .blue
        case "green": return .green
        case "pink": return .pink
        default: return .gray
        }
    }

    var source: AgentSource { AgentSource(rawValue: sourceName) ?? .cli }

    /// 命令行的位置；找不到 = 没装
    var binary: String? { kind == .command ? AgentBinary.find(exe) : nil }

    /// 现在能不能用：WorkBuddy 要在设置里接入；命令行装了才行
    var enabled: Bool {
        switch kind {
        case .workbuddyUI: return AgentPrefs.isOn(.workbuddy)
        case .command: return binary != nil
        }
    }

    /// 当前选的权限档（设置里改；默认「可改文件」）
    var access: AgentAccess {
        get { AgentAccess(rawValue: UserDefaults.standard.string(forKey: Self.accessKey(id)) ?? "") ?? .edit }
        nonmutating set { UserDefaults.standard.set(newValue.rawValue, forKey: Self.accessKey(id)) }
    }

    static func accessKey(_ id: String) -> String { "dispatch.access.\(id)" }

    /// 是不是只能新开对话 / 接着聊要靠账本里记的会话
    var supportsResume: Bool { !resume.isEmpty }
}

/// 在 PATH 和常见安装目录里找命令行（结果缓存几十秒，界面刷新时不会反复扫盘）
enum AgentBinary {
    private static let lock = NSLock()
    private static var cache: [String: (path: String?, at: Date)] = [:]

    static func find(_ name: String) -> String? {
        guard !name.isEmpty else { return nil }
        lock.lock()
        if let hit = cache[name], Date().timeIntervalSince(hit.at) < 30 { lock.unlock(); return hit.path }
        lock.unlock()
        let fm = FileManager.default
        var found: String?
        if name.hasPrefix("/") {
            found = fm.isExecutableFile(atPath: name) ? name : nil
        } else {
            let home = fm.homeDirectoryForCurrentUser.path
            var dirs = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
            dirs += ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.opencode/bin", "\(home)/.bun/bin", "\(home)/.local/bin", "\(home)/.npm-global/bin", "\(home)/.volta/bin", "\(home)/.claude/local"]
            for d in dirs where fm.isExecutableFile(atPath: d + "/" + name) { found = d + "/" + name; break }
        }
        lock.lock()
        cache[name] = (found, Date())
        lock.unlock()
        return found
    }
}

/// 所有派活目标：内置的 + `dispatch-profiles.json` 里自己加的（同 id 的覆盖内置）
enum AgentProfiles {
    static let builtin: [AgentProfile] = {
        var wb = AgentProfile(id: "workbuddy", name: "WorkBuddy")
        wb.kind = .workbuddyUI
        wb.aliases = ["workbuddy", "wb"]
        wb.color = "orange"
        wb.icon = "briefcase.fill"
        wb.sourceName = "workbuddy"
        wb.hooked = true

        var oc = AgentProfile(id: "opencode", name: "opencode")
        oc.exe = "opencode"
        oc.args = ["run", "--dir", "{cwd}", "{prompt}"]
        oc.resume = ["-s", "{session}"]
        oc.fileArgs = ["-f", "{file}"]
        oc.accessArgs = ["read": ["--agent", "plan"], "edit": [], "full": ["--auto"]]
        oc.aliases = ["opencode", "oc"]
        oc.color = "teal"
        oc.icon = "terminal.fill"
        oc.sourceName = "opencode"
        oc.hooked = true

        var cc = AgentProfile(id: "claude", name: "Claude Code")
        cc.exe = "claude"
        cc.args = ["-p", "{prompt}", "--output-format", "json"]
        cc.resume = ["--resume", "{session}"]
        cc.newSession = ["--session-id", "{session}"]
        cc.fileArgs = ["--add-dir", "{dir}"]
        cc.materialByPath = true
        cc.accessArgs = [
            "read": ["--permission-mode", "plan"],
            "edit": ["--permission-mode", "acceptEdits"],
            "full": ["--permission-mode", "bypassPermissions"],
        ]
        cc.parser = .claudeJSON
        cc.aliases = ["claude", "cc"]
        cc.color = "purple"
        cc.icon = "sparkle"
        cc.sourceName = "claude"

        // 模板：本机装了才会出现（没装的不显示）
        var cx = AgentProfile(id: "codex", name: "Codex")
        cx.exe = "codex"
        cx.args = ["exec", "-C", "{cwd}", "{prompt}"]
        cx.accessArgs = [
            "read": ["--sandbox", "read-only"],
            "edit": ["--sandbox", "workspace-write"],
            "full": ["--sandbox", "danger-full-access"],
        ]
        cx.materialByPath = true
        cx.aliases = ["codex", "cx"]
        cx.color = "green"
        cx.icon = "chevron.left.forwardslash.chevron.right"

        var all = [wb, oc, cc, cx]
        for i in all.indices { all[i].builtin = true }
        return all
    }()

    private static var customFile: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Shiyi/dispatch-profiles.json")
    }

    /// 自己加的目标
    private(set) static var custom: [AgentProfile] = {
        guard let d = try? Data(contentsOf: customFile) else { return [] }
        return (try? JSONDecoder().decode([AgentProfile].self, from: d)) ?? []
    }()

    static var all: [AgentProfile] {
        let ids = Set(custom.map(\.id))
        return builtin.filter { !ids.contains($0.id) } + custom
    }

    /// 新增 / 修改一个自己加的目标（同 id 覆盖），立即生效并存盘
    static func save(_ p: AgentProfile) {
        var list = custom
        if let i = list.firstIndex(where: { $0.id == p.id }) { list[i] = p } else { list.append(p) }
        write(list)
    }

    static func remove(_ id: String) { write(custom.filter { $0.id != id }) }

    private static func write(_ list: [AgentProfile]) {
        custom = list
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(list) { try? d.write(to: customFile, options: .atomic) }
    }

    static func profile(_ id: String) -> AgentProfile? { all.first { $0.id == id } }
}

/// 把模板填成真正的参数
enum AgentCommand {
    struct Vars {
        var prompt = ""
        var cwd = ""
        var session = ""
        var file = ""
        var dir = ""
    }

    static func fill(_ tokens: [String], _ v: Vars) -> [String] {
        // 指令放最后替换：指令里碰巧写了 {cwd} 之类的也不会被再替换一次
        tokens.map { t in
            t.replacingOccurrences(of: "{cwd}", with: v.cwd)
                .replacingOccurrences(of: "{session}", with: v.session)
                .replacingOccurrences(of: "{file}", with: v.file)
                .replacingOccurrences(of: "{dir}", with: v.dir)
                .replacingOccurrences(of: "{prompt}", with: v.prompt)
        }
    }
}
