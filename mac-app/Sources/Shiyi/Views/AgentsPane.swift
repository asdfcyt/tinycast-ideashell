import SwiftUI

/// 设置 → AI 调度台：每个 Agent 一个独立的「是否批阅」开关
struct AgentsPane: View {
    @ObservedObject private var center = ApprovalCenter.shared
    @AppStorage(AgentPrefs.cursorOn) private var cursorOn = false
    @AppStorage(AgentPrefs.cursorShell) private var shell = true
    @AppStorage(AgentPrefs.cursorMcp) private var mcp = true
    @AppStorage(AgentPrefs.cursorDelete) private var del = false
    @AppStorage(AgentPrefs.cursorDone) private var done = true
    @AppStorage(AgentPrefs.workbuddyOn) private var wbOn = false
    @AppStorage(AgentPrefs.workbuddyShell) private var wbShell = true
    @AppStorage(AgentPrefs.workbuddyMcp) private var wbMcp = true
    @AppStorage(AgentPrefs.workbuddyEdit) private var wbEdit = false
    @AppStorage(AgentPrefs.workbuddyDone) private var wbDone = true
    @AppStorage(AgentPrefs.opencodeOn) private var ocOn = false
    @AppStorage(AgentPrefs.opencodeShell) private var ocShell = true
    @AppStorage(AgentPrefs.opencodeMcp) private var ocMcp = true
    @AppStorage(AgentPrefs.opencodeEdit) private var ocEdit = false
    @AppStorage(AgentPrefs.opencodeDone) private var ocDone = true
    @AppStorage(AgentPrefs.opencodeObserve) private var ocObserve = "4196"
    @AppStorage(AgentPrefs.opencodeObserveCards) private var ocObserveCards = false
    @AppStorage(AgentPrefs.policy) private var policy = "high"
    @AppStorage(AgentPrefs.completionWait) private var doneWait = 30
    @AppStorage(AgentPrefs.doneAI) private var doneAI = false
    @AppStorage(AgentPrefs.runStatus) private var runStatus = true
    @AppStorage(AgentPrefs.autoReadOnly) private var autoRO = true
    @AppStorage(AgentPrefs.timeout) private var timeout = 90
    @AppStorage(AgentPrefs.fallback) private var fallback = "ask"
    @AppStorage(AgentPrefs.sound) private var sound = true

    @State private var installed: [String] = []
    @State private var wbInstalled: [String] = []
    @State private var ocInstalled = false
    @State private var serverUp = false
    @State private var errors: [AgentSource: String] = [:]

    private var cursorStatus: (ok: Bool, text: String)? {
        guard cursorOn else { return nil }
        if let error = errors[.cursor] { return (false, error) }
        return installed.isEmpty ? (false, "钩子没装上") : nil
    }

    private var wbStatus: (ok: Bool, text: String)? {
        guard wbOn else { return nil }
        if let error = errors[.workbuddy] { return (false, error) }
        return wbInstalled.isEmpty ? (false, "钩子没装上") : nil
    }

    private var ocStatus: (ok: Bool, text: String)? {
        guard ocOn else { return nil }
        if let error = errors[.opencode] { return (false, error) }
        return ocInstalled ? nil : (false, "插件没装上")
    }

    private var ocChip: (String, Color)? {
        guard ocOn else { return nil }
        return serverUp ? ("审批中", Color.green) : ("启动中", Color.orange)
    }

    private var wbChip: (String, Color)? {
        guard wbOn else { return nil }
        return serverUp ? ("审批中", Color.green) : ("启动中", Color.orange)
    }

    private var cursorChip: (String, Color)? {
        guard cursorOn else { return nil }
        return serverUp ? ("审批中", Color.green) : ("启动中", Color.orange)
    }

    var body: some View {
        SPage {
            SGroup("Cursor", chip: cursorChip, result: cursorStatus, trailing: {
                if cursorOn { SIconButton(symbol: "arrow.triangle.2.circlepath", help: "重新安装钩子") { apply() } }
                SIconButton(symbol: "rectangle.stack.badge.plus", help: "发一条测试请求") { center.demo() }
            }) {
                SToggle("启用", nil, $cursorOn)
                if cursorOn {
                    SToggle("Shell 命令", nil, $shell)
                    SToggle("MCP 工具调用", nil, $mcp)
                    SToggle("删除文件", nil, $del)
                    SToggle("验收卡", nil, $done)
                }
            }

            SGroup("WorkBuddy", chip: wbChip, result: wbStatus, trailing: {
                if wbOn { SIconButton(symbol: "arrow.triangle.2.circlepath", help: "重新安装钩子") { apply() } }
            }) {
                SToggle("启用", nil, $wbOn)
                if wbOn {
                    SToggle("Bash 命令", nil, $wbShell)
                    SToggle("MCP 工具调用", nil, $wbMcp)
                    SToggle("修改文件", nil, $wbEdit)
                    SToggle("验收卡", nil, $wbDone)
                }
            }

            SGroup("opencode", chip: ocChip, result: ocStatus, trailing: {
                if ocOn { SIconButton(symbol: "arrow.triangle.2.circlepath", help: "重新安装插件") { apply() } }
            }) {
                SToggle("启用", nil, $ocOn)
                if ocOn {
                    SToggle("Bash 命令", nil, $ocShell)
                    SToggle("MCP 工具调用", nil, $ocMcp)
                    SToggle("修改文件", nil, $ocEdit)
                    SToggle("验收卡", nil, $ocDone)
                    SRow("只观察的端口") {
                        TextField("", text: $ocObserve, prompt: Text("4196"))
                            .textFieldStyle(.roundedBorder).frame(width: 130).multilineTextAlignment(.trailing)
                    }
                    SToggle("观察端口的验收卡", nil, $ocObserveCards)
                }
            }

            SGroup("审批") {
                SRow("拦截范围") {
                    SPick(selection: $policy, options: [("high", "高风险（推荐）"), ("medium", "中、高风险"), ("all", "全部")])
                }
                if policy == "all" {
                    SToggle("只读命令放行", nil, $autoRO)
                }
                SRow("等待时间") {
                    SPick(selection: $timeout, options: [(30, "30 秒"), (60, "60 秒"), (90, "90 秒"), (180, "3 分钟"), (300, "5 分钟")])
                }
                SRow("超时后") {
                    SPick(selection: $fallback, options: [("ask", "交还对方询问"), ("deny", "直接拒绝")])
                }
                SToggle("提示音", nil, $sound)
            }

            SGroup("岛上") {
                SToggle("运行状态", nil, $runStatus)
                SRow("验收卡等待") {
                    SPick(selection: $doneWait, options: [(0, "不等待"), (60, "1 分钟"), (120, "2 分钟"), (300, "5 分钟")])
                }
                SToggle("AI 写结论和建议", nil, $doneAI)
            }

            if !center.denyRules.isEmpty {
                SGroup("拒绝规则") {
                    ForEach(center.denyRules, id: \.self) { k in
                        SRow(Self.ruleTitle(k)) {
                            SIconButton(symbol: "xmark", help: "移除") { center.removeDenyRule(k) }
                        }
                    }
                }
            }

            if !center.rules.isEmpty {
                SGroup("放行规则") {
                    ForEach(center.rules, id: \.self) { k in
                        SRow(Self.ruleTitle(k)) {
                            SIconButton(symbol: "xmark", help: "移除") { center.removeRule(k) }
                        }
                    }
                }
            }
        }
        .onAppear { refreshStatus() }
        .onReceive(Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()) { _ in refreshStatus() }
        .onChange(of: cursorOn) { _, _ in apply() }
        .onChange(of: shell) { _, _ in apply() }
        .onChange(of: mcp) { _, _ in apply() }
        .onChange(of: del) { _, _ in apply() }
        .onChange(of: done) { _, _ in apply() }
        .onChange(of: ocOn) { _, _ in apply() }
        .onChange(of: ocShell) { _, _ in apply() }
        .onChange(of: ocMcp) { _, _ in apply() }
        .onChange(of: ocEdit) { _, _ in apply() }
        .onChange(of: ocDone) { _, _ in apply() }
        .onChange(of: ocObserve) { _, _ in AgentBridge.rewrite() }
        .onChange(of: wbOn) { _, _ in apply() }
        .onChange(of: wbShell) { _, _ in apply() }
        .onChange(of: wbMcp) { _, _ in apply() }
        .onChange(of: wbEdit) { _, _ in apply() }
        .onChange(of: wbDone) { _, _ in apply() }
        .onChange(of: timeout) { _, _ in apply() }
        .onChange(of: doneWait) { _, _ in apply() }
        .onChange(of: runStatus) { _, _ in apply() }
        .onChange(of: fallback) { _, _ in AgentBridge.rewrite() }
    }

    private func apply() {
        errors = AgentRuntime.refresh()
        refreshStatus()
    }

    private func refreshStatus() {
        installed = AgentHooks.cursorInstalledEvents()
        wbInstalled = AgentHooks.workbuddyInstalledEvents()
        ocInstalled = AgentHooks.opencodeInstalled
        serverUp = ApprovalServer.shared.isRunning
    }

    private static func ruleTitle(_ k: String) -> String {
        // 键的形状：来源|shell:git push 或 来源|mcp:服务/工具
        let parts = k.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2, let src = AgentSource(rawValue: parts[0]) else { return k }
        let body = parts[1]
        if body.hasPrefix("shell:") { return "\(src.title) · 命令 " + body.dropFirst(6) }
        if body.hasPrefix("mcp:") { return "\(src.title) · MCP " + body.dropFirst(4) }
        return "\(src.title) · \(body)"
    }
}
