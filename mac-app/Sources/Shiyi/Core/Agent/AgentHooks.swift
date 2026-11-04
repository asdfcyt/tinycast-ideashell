import Foundation

/// 钩子进程（shiyi-hook）和拾忆之间的「桥接文件」：端口、令牌、超时和回退策略。
/// 放在拾忆的数据目录里，只有自己可读（0600）。拾忆没开时钩子也能读到回退策略。
enum AgentBridge {
    static var file: URL { LocalStore.dir.appendingPathComponent("agent-bridge.json") }
    nonisolated(unsafe) static var lastPort: UInt16 = 0
    /// 点了「停止」的 opencode 会话（插件读到后会让它停下）：20 秒后自动撤掉
    nonisolated(unsafe) static var stops: [String: Date] = [:]

    static func requestStop(session: String) {
        stops[session] = Date()
        rewrite()
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
            stops[session] = nil
            rewrite()
        }
    }

    static let token: String = {
        if let d = try? Data(contentsOf: file),
           let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
           let t = j["token"] as? String, t.count >= 32 { return t }
        return (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "")
    }()

    static func preferredPort() -> UInt16 {
        if let d = try? Data(contentsOf: file),
           let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
           let p = j["port"] as? Int, p > 1024, p < 65536 { return UInt16(p) }
        return 47821
    }

    static func write(port: UInt16) {
        lastPort = port
        rewrite()
    }

    /// 设置里的超时 / 回退策略变了，重写一遍
    static func rewrite() {
        guard lastPort > 0 else { return }
        let info: [String: Any] = [
            "port": Int(lastPort), "token": token,
            "timeout": AgentPrefs.bridgeTimeout,
            "fallback": AgentPrefs.fallbackDeny ? "deny" : "ask",
            "observePorts": AgentPrefs.opencodeObservePorts,
            "stop": Array(stops.keys).sorted(),
        ]
        guard let d = try? JSONSerialization.data(withJSONObject: info, options: [.sortedKeys]) else { return }
        try? d.write(to: file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}

/// 往各个 Agent 的配置里装 / 卸拾忆的钩子。只动带 `shiyi-hook` 标记的条目，别的（比如别的小组件装的钩子）原样保留。
enum AgentHooks {
    static let marker = "shiyi-hook"

    static var cursorFile: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cursor/hooks.json") }

    /// 钩子可执行文件：和拾忆主程序放在同一个目录里
    static var hookExecutable: String {
        let dir = Bundle.main.executableURL?.deletingLastPathComponent() ?? URL(fileURLWithPath: "/Applications/拾忆.app/Contents/MacOS")
        return dir.appendingPathComponent(marker).path
    }

    static var hookExists: Bool { FileManager.default.isExecutableFile(atPath: hookExecutable) }

    /// 各事件钩子的超时：审批要等人、验收卡要等人，状态事件立刻就回
    private static func timeout(event: String) -> Int {
        switch event {
        case "stop", "Stop": return AgentPrefs.holdCap + 20
        case "beforeSubmitPrompt", "postToolUse", "UserPromptSubmit", "PostToolUse": return 10
        default: return AgentPrefs.timeoutSeconds + 20
        }
    }

    private static func isOurs(_ entry: Any) -> Bool {
        ((entry as? [String: Any])?["command"] as? String)?.contains(marker) == true
    }

    /// Cursor 需要哪些事件：事件 → matcher
    private static func cursorWanted() -> [(event: String, matcher: String?)] {
        guard AgentPrefs.isOn(.cursor) else { return [] }
        let ud = UserDefaults.standard
        var w: [(String, String?)] = []
        if ud.bool(forKey: AgentPrefs.cursorShell) { w.append(("beforeShellExecution", nil)) }
        if ud.bool(forKey: AgentPrefs.cursorMcp) { w.append(("beforeMCPExecution", nil)) }
        if ud.bool(forKey: AgentPrefs.cursorDelete) { w.append(("preToolUse", "Delete")) }
        if ud.bool(forKey: AgentPrefs.cursorDone) { w.append(("stop", nil)) }
        // 运行状态：提交提问 = 开始，每次工具调用后 = 还在跑，stop = 结束
        if ud.bool(forKey: AgentPrefs.runStatus) {
            w.append(("beforeSubmitPrompt", nil))
            w.append(("postToolUse", nil))
            if !w.contains(where: { $0.0 == "stop" }) { w.append(("stop", nil)) }
        }
        return w
    }

    /// 按当前设置同步 `~/.cursor/hooks.json`。返回错误说明（nil = 成功）。
    @discardableResult
    static func syncCursor() -> String? {
        let fm = FileManager.default
        let wanted = cursorWanted()
        var root: [String: Any] = [:]
        let exists = fm.fileExists(atPath: cursorFile.path)
        if exists {
            guard let d = try? Data(contentsOf: cursorFile),
                  let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else {
                return "hooks.json 不是合法的 JSON，拾忆没有改动它"
            }
            root = j
        } else if wanted.isEmpty {
            return nil
        }
        if !wanted.isEmpty, !hookExists { return "找不到钩子程序：\(hookExecutable)" }

        var hooks = root["hooks"] as? [String: Any] ?? [:]
        // 先把自己的条目都拿掉，再按需要加回去
        for (k, v) in hooks {
            guard let arr = v as? [Any] else { continue }
            let rest = arr.filter { !isOurs($0) }
            if rest.isEmpty { hooks.removeValue(forKey: k) } else { hooks[k] = rest }
        }
        for (event, matcher) in wanted {
            let timeout = Self.timeout(event: event)
            var entry: [String: Any] = ["command": "'\(hookExecutable)' cursor", "timeout": timeout]
            // 追加指令会让 Agent 多跑几轮：默认最多 5 轮，放宽一点
            if event == "stop" { entry["loop_limit"] = 20 }
            if let matcher { entry["matcher"] = matcher }
            hooks[event] = (hooks[event] as? [Any] ?? []) + [entry]
        }
        var out = root
        if hooks.isEmpty { out.removeValue(forKey: "hooks") } else { out["hooks"] = hooks }
        if out["version"] == nil { out["version"] = 1 }
        // 没有变化就不写（避免 Cursor 反复重载）
        if exists, (out as NSDictionary).isEqual(to: root) { return nil }
        if !exists, hooks.isEmpty { return nil }

        do {
            try fm.createDirectory(at: cursorFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            // 第一次改之前留一份原件
            let backup = cursorFile.appendingPathExtension("shiyi-backup")
            if exists, !fm.fileExists(atPath: backup.path) { try? fm.copyItem(at: cursorFile, to: backup) }
            let d = try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try d.write(to: cursorFile, options: .atomic)
            return nil
        } catch {
            return "写入 hooks.json 失败：\(error.localizedDescription)"
        }
    }

    // MARK: WorkBuddy（Claude Code 规范：settings.json 的 hooks → 事件 → [{matcher, hooks: [{type, command, timeout}]}]）

    static var workbuddyFile: URL {
        if let dir = ProcessInfo.processInfo.environment["WORKBUDDY_CONFIG_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir).appendingPathComponent("settings.json")
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".workbuddy/settings.json")
    }

    /// 事件 → matcher（工具名正则）
    private static func workbuddyWanted() -> [(event: String, matcher: String?)] {
        guard AgentPrefs.isOn(.workbuddy) else { return [] }
        let ud = UserDefaults.standard
        var tools: [String] = []
        if ud.bool(forKey: AgentPrefs.workbuddyShell) { tools.append("Bash") }
        if ud.bool(forKey: AgentPrefs.workbuddyMcp) { tools.append("mcp__.*") }
        if ud.bool(forKey: AgentPrefs.workbuddyEdit) { tools.append("Write|Edit|MultiEdit|NotebookEdit") }
        var w: [(String, String?)] = []
        if !tools.isEmpty { w.append(("PreToolUse", tools.map { "^(\($0))$" }.joined(separator: "|"))) }
        if ud.bool(forKey: AgentPrefs.workbuddyDone) || ud.bool(forKey: AgentPrefs.runStatus) { w.append(("Stop", nil)) }
        if ud.bool(forKey: AgentPrefs.runStatus) {
            w.append(("UserPromptSubmit", nil))
            w.append(("PostToolUse", nil))
        }
        return w
    }

    /// 一个事件下的条目里，有没有带拾忆标记的 command
    private static func groupIsOurs(_ group: Any) -> Bool {
        guard let g = group as? [String: Any], let inner = g["hooks"] as? [Any] else { return false }
        return inner.contains(where: isOurs)
    }

    /// 按当前设置同步 `~/.workbuddy/settings.json` 的 hooks。只动带 `shiyi-hook` 标记的条目，其余设置原样保留。
    @discardableResult
    static func syncWorkBuddy() -> String? {
        let fm = FileManager.default
        let file = workbuddyFile
        let wanted = workbuddyWanted()
        guard fm.fileExists(atPath: file.path) else {
            return wanted.isEmpty ? nil : "没找到 WorkBuddy 的设置文件（\(file.path)），先打开过 WorkBuddy 再试"
        }
        guard let d = try? Data(contentsOf: file),
              let root = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else {
            return "WorkBuddy 的 settings.json 不是合法的 JSON，拾忆没有改动它"
        }
        if !wanted.isEmpty, !hookExists { return "找不到钩子程序：\(hookExecutable)" }

        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for (k, v) in hooks {
            guard let arr = v as? [Any] else { continue }
            let rest = arr.filter { !groupIsOurs($0) }
            if rest.isEmpty { hooks.removeValue(forKey: k) } else { hooks[k] = rest }
        }
        for (event, matcher) in wanted {
            let timeout = Self.timeout(event: event)
            var group: [String: Any] = ["hooks": [["type": "command", "command": "'\(hookExecutable)' workbuddy", "timeout": timeout] as [String: Any]]]
            if let matcher { group["matcher"] = matcher }
            hooks[event] = (hooks[event] as? [Any] ?? []) + [group]
        }
        var out = root
        if hooks.isEmpty { out.removeValue(forKey: "hooks") } else { out["hooks"] = hooks }
        if (out as NSDictionary).isEqual(to: root) { return nil }

        do {
            let backup = file.appendingPathExtension("shiyi-backup")
            if !fm.fileExists(atPath: backup.path) { try? fm.copyItem(at: file, to: backup) }
            let data = try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try data.write(to: file, options: .atomic)
            return nil
        } catch {
            return "写入 WorkBuddy 的 settings.json 失败：\(error.localizedDescription)"
        }
    }

    // MARK: opencode（没有 shell 钩子，装一个全局插件；结审的服务端口由插件自己跳过）

    static var opencodePluginFile: URL {
        let env = ProcessInfo.processInfo.environment
        let base: URL
        if let d = env["OPENCODE_CONFIG_DIR"], !d.isEmpty {
            base = URL(fileURLWithPath: d)
        } else if let x = env["XDG_CONFIG_HOME"], !x.isEmpty {
            base = URL(fileURLWithPath: x).appendingPathComponent("opencode")
        } else {
            base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/opencode")
        }
        return base.appendingPathComponent("plugins/shiyi.js")
    }

    static var opencodeInstalled: Bool {
        guard let s = try? String(contentsOf: opencodePluginFile, encoding: .utf8) else { return false }
        return s.hasPrefix("// shiyi-opencode-plugin")
    }

    /// 装 / 更新 / 删除插件。只动 shiyi.js 这一个文件；opencode 的其他配置和插件都不碰。对新启动的 opencode 生效。
    @discardableResult
    static func syncOpenCode() -> String? {
        let fm = FileManager.default
        let file = opencodePluginFile
        let want = AgentPrefs.isOn(.opencode)
        if !want {
            if opencodeInstalled { try? fm.removeItem(at: file) }
            return nil
        }
        if let cur = try? String(contentsOf: file, encoding: .utf8), cur == OpenCodePlugin.source { return nil }
        // 同名但不是我们写的文件：不覆盖
        if fm.fileExists(atPath: file.path), !opencodeInstalled { return "\(file.path) 已经存在且不是拾忆写的，没有改动它" }
        do {
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try OpenCodePlugin.source.write(to: file, atomically: true, encoding: .utf8)
            return nil
        } catch {
            return "写入 opencode 插件失败：\(error.localizedDescription)"
        }
    }

    static func workbuddyInstalledEvents() -> [String] {
        guard let d = try? Data(contentsOf: workbuddyFile),
              let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let hooks = j["hooks"] as? [String: Any] else { return [] }
        return hooks.filter { ($0.value as? [Any])?.contains(where: groupIsOurs) == true }.map(\.key).sorted()
    }

    /// 设置页显示用：hooks.json 里已经装了拾忆钩子的事件
    static func cursorInstalledEvents() -> [String] {
        guard let d = try? Data(contentsOf: cursorFile),
              let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let hooks = j["hooks"] as? [String: Any] else { return [] }
        return hooks.filter { ($0.value as? [Any])?.contains(where: isOurs) == true }.map(\.key).sorted()
    }
}

/// 总开关：按各来源的开关启停本机服务、同步钩子、刷新桥接文件
@MainActor
enum AgentRuntime {
    static func start() {
        AgentPrefs.register()
        ApprovalCenter.shared.start()
        refresh()
        OpenCodeStore.shared.refresh(after: 3)
    }

    /// 返回各来源的错误说明（没有错误的来源不在里面）
    @discardableResult
    static func refresh() -> [AgentSource: String] {
        let any = AgentSource.allCases.contains { AgentPrefs.isOn($0) }
        if any { ApprovalServer.shared.start() } else { ApprovalServer.shared.stop() }
        for s in AgentSource.allCases where !AgentPrefs.isOn(s) || !AgentRunTracker.enabled { AgentRunTracker.shared.clear(s) }
        var errors: [AgentSource: String] = [:]
        if let e = AgentHooks.syncCursor() { errors[.cursor] = e }
        if let e = AgentHooks.syncWorkBuddy() { errors[.workbuddy] = e }
        if let e = AgentHooks.syncOpenCode() { errors[.opencode] = e }
        AgentBridge.rewrite()
        return errors
    }
}
