import Foundation

/// 判断一条命令的风险、是不是纯只读、能不能「以后同类都准」。
/// 宁可多问：拿不准（引号里有分隔符、重定向、命令替换…）一律当成需要人批。
enum AgentRiskAssess {
    // MARK: 风险

    private static let rules: [(pattern: String, level: AgentRisk, reason: String)] = [
        (#"\bsudo\b"#, .high, "sudo 提权"),
        (#"\brm\s+-[a-zA-Z]*[rRfF][a-zA-Z]*"#, .high, "递归 / 强制删除"),
        (#"\brm\b"#, .medium, "删除文件"),
        (#"\bgit\s+push\b.*(--force|--force-with-lease|\s-f\b)"#, .high, "强制推送"),
        (#"\bgit\s+push\b"#, .high, "推送到远端（对外发布）"),
        (#"\bgit\s+reset\s+--hard"#, .high, "丢弃所有未提交改动"),
        (#"\bgit\s+clean\s+-[a-zA-Z]*f"#, .high, "清除未跟踪文件"),
        (#"\bgit\s+(checkout|restore)\s+(--\s+)?\."#, .medium, "丢弃工作区改动"),
        (#"\bgit\s+branch\s+-D\b"#, .medium, "强制删除分支"),
        (#"(curl|wget)[^|;&]*\|\s*(sudo\s+)?(sh|bash|zsh)\b"#, .high, "下载后直接执行"),
        (#"\bchmod\s+(-R\s+)?[0-7]?777\b"#, .high, "开放全部权限"),
        (#"\bchown\s+-R\b"#, .medium, "批量改属主"),
        (#"\bdd\s+if="#, .high, "磁盘级写入"),
        (#"\bmkfs"#, .high, "格式化磁盘"),
        (#"(?i)\b(drop|truncate)\s+(table|database)\b"#, .high, "删库 / 清表"),
        (#"\.ssh/|\.aws/|id_rsa|\bsecurity\s+find-|keychain"#, .high, "涉及密钥 / 凭证"),
        (#"\b(npm|pnpm|yarn)\s+publish\b|\bcargo\s+publish\b|\bpod\s+trunk\s+push\b"#, .high, "发布到公共仓库"),
        (#"\b(aws\s+iam|gcloud\s+.*\biam\b|ssh-keygen|gpg\s+--(gen|delete)|security\s+add-)"#, .high, "改权限 / 密钥"),
        (#"\bkill(all)?\s+-9\b|\bpkill\b"#, .medium, "强制结束进程"),
        (#"\blaunchctl\b|\bdefaults\s+(write|delete)\b|\bosascript\b"#, .medium, "改系统设置 / 脚本控制"),
        (#"\bmv\b"#, .medium, "移动 / 重命名"),
        (#"\b(curl|wget|ssh|scp|rsync|nc)\b"#, .medium, "访问网络 / 远程主机"),
        (#"(?<![0-9&>])>>?\s*(?!&|/dev/null)\S"#, .medium, "写入文件"),
    ]

    private static let compiled: [(NSRegularExpression, AgentRisk, String)] = rules.compactMap { r in
        (try? NSRegularExpression(pattern: r.pattern)).map { ($0, r.level, r.reason) }
    }

    static func assess(command: String) -> (AgentRisk, [String]) {
        let ns = command as NSString
        let full = NSRange(location: 0, length: ns.length)
        var level = AgentRisk.low
        var reasons: [String] = []
        for (re, lv, why) in compiled where re.firstMatch(in: command, range: full) != nil {
            if !reasons.contains(why) { reasons.append(why) }
            if lv.rawValue > level.rawValue { level = lv }
        }
        // 「rm -rf」已经算高风险，不再重复列「删除文件」
        if reasons.contains("递归 / 强制删除") { reasons.removeAll { $0 == "删除文件" } }
        if reasons.contains("强制推送") { reasons.removeAll { $0 == "推送到远端（对外发布）" } }
        return (level, reasons)
    }

    /// MCP 工具按名字里的动词估计
    static func assess(tool: String) -> (AgentRisk, [String]) {
        let n = tool.lowercased()
        if ["delete", "remove", "drop", "destroy", "purge"].contains(where: n.contains) { return (.high, ["会删除数据"]) }
        if ["send", "publish", "tweet", "email", "mail", "message", "notify", "broadcast", "post_", "_post", "reply", "comment"].contains(where: n.contains) {
            return (.high, ["会对外发送 / 发布内容"])
        }
        if ["pay", "purchase", "charge", "order", "buy", "billing", "refund", "transfer"].contains(where: n.contains) {
            return (.high, ["涉及付款 / 花钱"])
        }
        if ["create", "update", "write", "edit", "set", "add", "move", "push", "commit", "post"].contains(where: n.contains) {
            return (.medium, ["会修改数据"])
        }
        return (.low, [])
    }

    // MARK: 命令拆解

    /// 去掉开头的「cd 某目录 &&」（Agent 几乎每条命令都带）
    static func stripCd(_ command: String) -> String {
        var c = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let re = try? NSRegularExpression(pattern: #"^cd\s+("[^"]*"|'[^']*'|[^\s;&|]+)\s*&&\s*"#)
        while let re, let m = re.firstMatch(in: c, range: NSRange(location: 0, length: (c as NSString).length)) {
            c = (c as NSString).substring(from: m.range.upperBound)
        }
        return c
    }

    private static func tokens(_ segment: String) -> [String] {
        var t = segment.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        // 跳过开头的 VAR=value
        while let f = t.first, f.range(of: #"^[A-Za-z_][A-Za-z0-9_]*="#, options: .regularExpression) != nil { t.removeFirst() }
        return t
    }

    /// 没有任何拼接 / 管道 / 重定向 / 命令替换的单条命令
    static func isSimple(_ command: String) -> Bool {
        let c = stripCd(command)
        if c.isEmpty { return false }
        for bad in ["&&", "||", ";", "|", "`", "$(", "<(", ">", "<", "\n", "&"] where c.contains(bad) { return false }
        return true
    }

    // MARK: 只读命令

    private static let readOnlyCommands: Set<String> = [
        "ls", "cat", "pwd", "echo", "printf", "head", "tail", "wc", "grep", "egrep", "fgrep", "rg", "fd", "tree", "which", "type",
        "stat", "file", "du", "df", "date", "whoami", "uname", "hostname", "sort", "uniq", "cut", "jq", "diff", "basename", "dirname",
        "realpath", "readlink", "test", "[", "true", "false", "cd", "id", "nl", "tr", "column", "less", "more", "md5", "shasum", "ps",
    ]
    private static let readOnlyGit: Set<String> = [
        "status", "diff", "log", "show", "branch", "remote", "rev-parse", "ls-files", "blame", "describe", "tag", "shortlog",
        "ls-remote", "rev-list", "cat-file", "grep", "reflog", "stash",
    ]
    private static let versionFlags: Set<String> = ["--version", "-v", "-V", "version", "-version"]

    private static func readOnly(_ tokens: [String]) -> Bool {
        guard let first = tokens.first else { return true }
        let cmd = (first as NSString).lastPathComponent
        let args = Array(tokens.dropFirst())
        if readOnlyCommands.contains(cmd) { return true }
        switch cmd {
        case "git":
            var a = args
            while let f = a.first, f.hasPrefix("-") {
                a.removeFirst()
                if f == "-C" || f == "-c", !a.isEmpty { a.removeFirst() }
            }
            guard let sub = a.first, readOnlyGit.contains(sub) else { return false }
            // 会改东西的写法：git branch -d / git tag -a / git stash（除 list）/ git remote add
            let rest = Array(a.dropFirst())
            if sub == "stash" { return rest.first == "list" || rest.first == "show" }
            if sub == "branch" { return !rest.contains(where: { $0 == "-d" || $0 == "-D" || $0 == "-m" || $0 == "-M" || $0 == "-c" || $0 == "-C" }) }
            if sub == "tag" { return rest.isEmpty || rest.allSatisfy { $0.hasPrefix("-l") || $0 == "--list" || $0 == "-n" } }
            if sub == "remote" { return rest.isEmpty || rest.first == "-v" || rest.first == "show" || rest.first == "get-url" }
            return true
        case "find":
            return !args.contains(where: { ["-delete", "-exec", "-execdir", "-ok", "-okdir", "-fprint", "-fprintf"].contains($0) })
        case "sed":
            return !args.contains(where: { $0.hasPrefix("-i") || $0 == "--in-place" })
        case "node", "python", "python3", "ruby", "swift", "swiftc", "go", "cargo", "npm", "pnpm", "yarn", "java", "rustc", "xcodebuild", "brew", "pod":
            return args.count == 1 && versionFlags.contains(args[0])
        default:
            return false
        }
    }

    /// 整条命令（含 && / ; / | 拼起来的每一段）都是只读的
    static func isReadOnly(_ command: String) -> Bool {
        var c = stripCd(command)
        if c.isEmpty { return false }
        for bad in ["$(", "`", "<(", ">(", "<<"] where c.contains(bad) { return false }
        for ok in ["2>&1", "&>/dev/null", "2>/dev/null", ">/dev/null", "1>/dev/null"] { c = c.replacingOccurrences(of: ok, with: " ") }
        if c.contains(">") { return false }
        let segs = c.replacingOccurrences(of: "&&", with: "\n").replacingOccurrences(of: "||", with: "\n")
            .replacingOccurrences(of: ";", with: "\n").replacingOccurrences(of: "|", with: "\n")
            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if segs.isEmpty { return false }
        return segs.allSatisfy { readOnly(tokens($0)) }
    }

    // MARK: 「以后同类都准」

    /// 单条命令取前两个词（git push、npm install…）作为规则键；复合命令返回 nil
    static func ruleKey(command: String) -> String? {
        guard isSimple(command) else { return nil }
        let t = tokens(stripCd(command))
        guard let f = t.first else { return nil }
        let name = (f as NSString).lastPathComponent
        if t.count >= 2, !t[1].hasPrefix("-") { return "shell:\(name) \(t[1])" }
        return "shell:\(name)"
    }
}
