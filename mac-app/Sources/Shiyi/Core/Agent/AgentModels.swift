import AppKit
import SwiftUI

// MARK: - AI 调度台：数据模型
//
// 把 Cursor / opencode（结审）/ WorkBuddy 里「要等人拍板」的请求汇到拾忆：
// 一条审批请求 = 一次待批的操作（执行命令、调用 MCP、删除文件…），决定 = 允许 / 拒绝（可带理由）。

/// 审批请求的来源。每个来源在设置里有独立的「是否批阅」开关。
enum AgentSource: String, Codable, CaseIterable {
    case cursor, opencode, workbuddy
    /// 派活账本启动的命令行 Agent（没有钩子，跑完由账本弹验收卡）
    case claude, cli

    var title: String {
        switch self {
        case .cursor: return "Cursor"
        case .opencode: return "opencode"
        case .workbuddy: return "WorkBuddy"
        case .claude: return "Claude Code"
        case .cli: return "命令行 Agent"
        }
    }

    var color: Color {
        switch self {
        case .cursor: return .indigo
        case .opencode: return .teal
        case .workbuddy: return .orange
        case .claude: return .purple
        case .cli: return .gray
        }
    }

    /// 「打开 Agent」按钮用
    var bundleID: String {
        switch self {
        case .cursor: return "com.todesktop.230313mzl4w4u92"
        case .opencode: return "ai.opencode.desktop"
        case .workbuddy: return "com.tencent.workbuddy.mac"
        case .claude, .cli: return "" // 没有桌面 App
        }
    }

    var icon: String {
        switch self {
        case .cursor: return "cursorarrow.rays"
        case .opencode: return "terminal.fill"
        case .workbuddy: return "briefcase.fill"
        case .claude: return "sparkle"
        case .cli: return "terminal"
        }
    }
}

enum AgentKind: String, Codable {
    case shell, mcp, delete, edit

    var label: String {
        switch self {
        case .shell: return "要执行命令"
        case .mcp: return "要调用 MCP 工具"
        case .delete: return "要删除文件"
        case .edit: return "要修改文件"
        }
    }

    var icon: String {
        switch self {
        case .shell: return "terminal"
        case .mcp: return "puzzlepiece.extension"
        case .delete: return "trash"
        case .edit: return "square.and.pencil"
        }
    }
}

enum AgentRisk: Int, Codable {
    case low, medium, high

    var label: String {
        switch self {
        case .low: return "低风险"
        case .medium: return "注意"
        case .high: return "高风险"
        }
    }

    var tint: Color {
        switch self {
        case .low: return .green
        case .medium: return .orange
        case .high: return .red
        }
    }
}

struct Approval: Identifiable {
    let id = UUID()
    let created = Date()
    var source: AgentSource
    var kind: AgentKind
    var project: String
    var cwd: String
    /// 命令原文 / MCP 参数 / 路径
    var detail: String
    /// 一行摘要（MCP：服务 · 工具）
    var heading: String
    var risk: AgentRisk
    var reasons: [String]
    /// 「以后同类都准」的规则键；nil = 不允许记住（复合命令、高风险、删除）
    var ruleKey: String?
    var timeout: TimeInterval
    var deadline: Date { created.addingTimeInterval(timeout) }
}

/// Agent 做完一轮后的「验收卡」：看结论 + 追加指令（Cursor 回 followup_message，WorkBuddy 回 Stop 的 block + reason）
struct AgentCompletion: Identifiable {
    struct Option: Identifiable {
        let id = UUID()
        var label: String
        var instruction: String
        /// Agent 在回执里推荐的那个
        var recommended = false
    }

    let id = UUID()
    let created = Date()
    var source: AgentSource
    var project: String
    var cwd: String
    var failed: Bool
    /// Agent 最后一条回复（截断后）
    var summary: String
    /// Agent 最后是在向你提问
    var asksQuestion: Bool
    /// 可以追加指令（卡片停留期间对方在等）；false 时只展示
    var canFollowUp: Bool
    /// 对方最多等多久
    var wait: TimeInterval
    /// AI 写的一句话结论（设置里打开「用 AI 生成建议」才有）
    var conclusion: String?
    var options: [Option]
    /// 这一轮跑了多久（有运行状态记录时才有）
    var duration: TimeInterval?
    /// 对方还会等到这个时刻（悬停 / 正在输入时会顺延）
    var deadline = Date()
    /// 对方已经不再等你了（超时放行 / 钩子断开 / 只展示模式）：卡片还留着，点指令会复制到剪贴板带你回去粘贴
    var detached = false
    /// 追加指令不走钩子回传，而是由拾忆重新发给对方（opencode run：接着这个会话再跑一轮）
    var viaDispatch = false
    /// 对方的会话 id（viaDispatch 时用来接着聊）
    var sessionId: String?
    /// 派活目标的 id（viaDispatch 时用来接着聊；空 = opencode）
    var profileId: String?
    /// 卡片上显示的名字（派活目标的名字）；空 = 用来源的名字
    var name: String?
    var displayName: String { name ?? source.title }
    /// 选项来自 Agent 的回执（不被 AI 建议覆盖）
    var optionsFromReceipt = false
    /// 回执里要稍后复查的事
    var laters: [AgentReceipt.Later] = []
    /// 复查提醒的处理结果（已建滴答提醒 / 没建成）
    var laterStatus: String?
    /// 末尾有回执代码块，但格式不对
    var receiptMalformed = false
}

enum CompletionOutcome {
    case dismissed
    case followUp(String)
    case timeout
    case cancelled
}

enum ApprovalOutcome {
    case allow
    /// 规则自动放行（只读命令 / 已记住的规则）：不替对方做权限决定，让对方自己的流程继续
    case autoAllow
    case deny(String)
    case timeout
    case cancelled
}

/// 流水账：每张审批请求最后怎么处理的
struct ApprovalRecord: Codable, Identifiable {
    var id = UUID()
    var time = Date()
    var source: AgentSource
    var kind: AgentKind
    var project: String
    var heading: String
    var detail: String
    /// 准 / 驳 / 超时 / 取消
    var result: String
    /// 手动 / 自动 · 只读命令 / 自动 · 已记住的规则 / 超时 / 已取消
    var by: String
    var comment: String?
    var seconds: Int
}

// MARK: - 设置键

enum AgentPrefs {
    static var defaults: UserDefaults { .standard }
    static let cursorOn = "agent.cursor.enabled"
    static let cursorShell = "agent.cursor.shell"
    static let cursorMcp = "agent.cursor.mcp"
    static let cursorDelete = "agent.cursor.delete"
    static let cursorDone = "agent.cursor.done"
    static let autoReadOnly = "agent.autoReadOnly"
    static let timeout = "agent.timeout"
    /// 超时 / 拾忆没开时怎么办："ask" 交还给工具自己询问；"deny" 直接拒绝
    static let fallback = "agent.fallback"
    static let sound = "agent.sound"
    static let rules = "agent.rules"
    static let denyRules = "agent.denyRules"
    /// 什么级别的操作才需要你批："high" 只拦高风险（默认）/ "medium" 中高风险 / "all" 全部
    static let policy = "agent.policy"
    /// 完成卡片：对方最多等你多久（秒）；0 = 只展示，不等待、不能追加指令
    static let completionWait = "agent.completionWait"
    /// 完成卡片用 AI 生成结论和建议（会把 Agent 的最后一条回复发给你配置的模型）
    static let doneAI = "agent.doneAI"
    /// 运行时在岛上显示 Agent 的运行状态
    static let runStatus = "agent.runStatus"

    static let workbuddyOn = "agent.workbuddy.enabled"
    static let workbuddyShell = "agent.workbuddy.shell"
    static let workbuddyMcp = "agent.workbuddy.mcp"
    static let workbuddyEdit = "agent.workbuddy.edit"
    static let workbuddyDone = "agent.workbuddy.done"

    static let opencodeOn = "agent.opencode.enabled"
    static let opencodeShell = "agent.opencode.shell"
    static let opencodeMcp = "agent.opencode.mcp"
    static let opencodeEdit = "agent.opencode.edit"
    static let opencodeDone = "agent.opencode.done"
    /// 「只观察」的 opencode 服务端口（逗号分隔）：只显示状态和验收卡，不拦截、不能追加指令。结审的服务默认是 4196
    static let opencodeObserve = "agent.opencode.observePorts"
    /// 「只观察」的服务（结审）每轮结束要不要弹验收卡；默认不弹，只显示运行状态
    static let opencodeObserveCards = "agent.opencode.observeCards"

    static func register() {
        UserDefaults.standard.register(defaults: [
            cursorOn: false, cursorShell: true, cursorMcp: true, cursorDelete: false, cursorDone: true,
            workbuddyOn: false, workbuddyShell: true, workbuddyMcp: true, workbuddyEdit: false, workbuddyDone: true,
            opencodeOn: false, opencodeShell: true, opencodeMcp: true, opencodeEdit: false, opencodeDone: true, opencodeObserve: "4196", opencodeObserveCards: false,
            policy: "high", completionWait: 120, doneAI: false, runStatus: true,
            autoReadOnly: true, timeout: 90, fallback: "ask", sound: true,
        ])
    }

    static func isOn(_ s: AgentSource) -> Bool {
        return UserDefaults.standard.bool(forKey: "agent.\(s.rawValue).enabled")
    }

    static var timeoutSeconds: Int { max(UserDefaults.standard.integer(forKey: timeout), 15) }
    static var completionWaitSeconds: Int { UserDefaults.standard.integer(forKey: completionWait) }

    /// 钩子等你的最长时间（审批超时 / 完成卡片等待取大的那个）
    static var bridgeTimeout: Int { max(timeoutSeconds, holdCap) }

    /// 验收卡：对方最长可能被拦多久（悬停 / 输入会顺延，上限 10 分钟）；不等待时为 0
    static var holdCap: Int { completionWaitSeconds > 0 ? 660 : 0 }

    /// 这个风险级别要不要人批
    static func needsHuman(_ r: AgentRisk) -> Bool {
        switch UserDefaults.standard.string(forKey: policy) {
        case "all": return true
        case "medium": return r.rawValue >= AgentRisk.medium.rawValue
        default: return r == .high
        }
    }

    static var opencodeObservePorts: [Int] {
        (UserDefaults.standard.string(forKey: opencodeObserve) ?? "4196")
            .split(whereSeparator: { ", ，、;；".contains($0) }).compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    }

    static var fallbackDeny: Bool { UserDefaults.standard.string(forKey: fallback) == "deny" }
}
