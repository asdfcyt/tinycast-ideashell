import AppKit
import ApplicationServices
import Foundation
import SwiftUI

/// 能接活的对象
enum DispatchTarget: String, CaseIterable, Identifiable {
    case workbuddy, opencode
    var id: String { rawValue }

    var title: String { self == .workbuddy ? "WorkBuddy" : "opencode" }
    var color: Color { self == .workbuddy ? AgentSource.workbuddy.color : AgentSource.opencode.color }
    var icon: String { self == .workbuddy ? "briefcase.fill" : "terminal.fill" }
    /// 万能输入里 @ 后面能写的名字（小写）
    var aliases: [String] { self == .workbuddy ? ["workbuddy", "wb"] : ["opencode", "oc"] }

    /// 现在能不能用：WorkBuddy 要在设置里接入；opencode 装了命令行就行
    var enabled: Bool {
        switch self {
        case .workbuddy: return AgentPrefs.isOn(.workbuddy)
        case .opencode: return OpenCodeRunner.binary != nil
        }
    }

    static var available: [DispatchTarget] { allCases.filter(\.enabled) }
}

/// 一次「派活」：从拾忆把一件事交给某个 Agent 去做
struct DispatchJob: Identifiable {
    enum State: Equatable {
        case running
        case sent
        case failed(String)
    }

    let id = UUID()
    let started = Date()
    var target: DispatchTarget
    var prompt: String
    var state: State
}

/// 这句话交给谁、是新开对话还是接着聊
struct DispatchPlan {
    var target: DispatchTarget
    /// true = 新开对话；false = 接着上一个对话（WorkBuddy：当前打开的那个；opencode：下面的会话）
    var fresh = true
    /// opencode 新开对话的工作目录
    var dir = ""
    /// opencode 继续对话的会话
    var session: OpenCodeSession?
}

struct DispatchOutcome {
    var ok: Bool
    var message: String
}

/// 派活（「发」）：和审批 / 验收（「收」）配成一对。
///
/// WorkBuddy 没有任何「带任务内容」的深链或对外接口（它的登录凭据只在 App 内部流转，命令行也不能共用），
/// 所以想共用桌面端的账号和额度，只有走 App 自己的输入框：
/// 1. 用深链 `workbuddy://home` 回到首页（= 新对话）；
/// 2. 通过辅助功能找到输入框，粘贴任务，等「发送」按钮亮起后点它；
/// 3. 发完立刻把焦点还给你原来在用的 App——任务在 WorkBuddy 后台跑，进度和验收卡显示在岛上。
@MainActor
final class DispatchCenter: ObservableObject {
    static let shared = DispatchCenter()

    static let autoKey = "dispatch.workbuddy.autoApprove"

    @Published private(set) var jobs: [DispatchJob] = []

    static func registerDefaults() {}

    private static var appURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: AgentSource.workbuddy.bundleID)
    }

    // MARK: 派活入口

    func send(_ prompt: String, plan: DispatchPlan) async -> DispatchOutcome {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return DispatchOutcome(ok: false, message: "还没有写要做什么") }
        let job = DispatchJob(target: plan.target, prompt: text, state: .running)
        let id = job.id
        jobs.insert(job, at: 0)
        if jobs.count > 20 { jobs.removeLast(jobs.count - 20) }
        let r: DispatchOutcome
        switch plan.target {
        case .workbuddy:
            r = await deliver(text, newChat: plan.fresh)
        case .opencode:
            if plan.fresh {
                r = await OpenCodeRunner.run(prompt: text, dir: plan.dir, sessionId: nil)
            } else if let s = plan.session {
                r = await OpenCodeRunner.run(prompt: text, dir: s.dir, sessionId: s.id)
            } else {
                r = DispatchOutcome(ok: false, message: "没有可以继续的 opencode 会话")
            }
        }
        if let i = jobs.firstIndex(where: { $0.id == id }) { jobs[i].state = r.ok ? .sent : .failed(r.message) }
        OpenCodeStore.shared.refresh(after: 8, force: true)
        return r
    }

    // MARK: 投递

    private func deliver(_ text: String, newChat: Bool) async -> DispatchOutcome {
        let ws = NSWorkspace.shared
        let bid = AgentSource.workbuddy.bundleID
        guard let url = Self.appURL else { return DispatchOutcome(ok: false, message: "没有找到 WorkBuddy，请确认已安装") }
        let previous = ws.frontmostApplication.flatMap { $0.bundleIdentifier == bid ? nil : $0 }

        var fresh = false
        if NSRunningApplication.runningApplications(withBundleIdentifier: bid).isEmpty {
            fresh = true
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = false
            _ = try? await ws.openApplication(at: url, configuration: cfg)
        }
        guard let app = await waitForApp(bid) else { return DispatchOutcome(ok: false, message: "WorkBuddy 没有启动起来") }
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetAttributeValue(ax, "AXManualAccessibility" as CFString, kCFBooleanTrue)

        // 冷启动：等主窗口里的输入框出现（最多 20 秒）
        if fresh {
            for _ in 0 ..< 40 where Self.findComposer(ax) == nil { try? await Task.sleep(nanoseconds: 500_000_000) }
        }
        // 新对话：深链回到首页；继续对话：直接用它当前打开的那个
        if newChat, let deep = URL(string: "workbuddy://home") {
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = false
            ws.open(deep, configuration: cfg, completionHandler: nil)
        }
        try? await Task.sleep(nanoseconds: newChat ? 1_100_000_000 : 300_000_000)

        guard AXIsProcessTrusted() else {
            _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
            copyForManual(text)
            app.activate(options: [.activateAllWindows])
            return DispatchOutcome(ok: true, message: "已复制到剪贴板并打开 WorkBuddy。拾忆还没有「辅助功能」权限，请手动粘贴并回车；授权后下次就能自动发送。")
        }
        guard let composer = Self.findComposer(ax) else {
            copyForManual(text)
            app.activate(options: [.activateAllWindows])
            return DispatchOutcome(ok: true, message: "没找到 WorkBuddy 的输入框，任务已复制到剪贴板，请手动粘贴并回车。")
        }

        // 粘贴需要它在前台一小会儿
        let pb = NSPasteboard.general
        let old = pb.string(forType: .string)
        pb.clearContents()
        pb.setString(text, forType: .string)
        let change = pb.changeCount

        app.activate(options: [.activateAllWindows])
        for _ in 0 ..< 12 where ws.frontmostApplication?.bundleIdentifier != bid { try? await Task.sleep(nanoseconds: 150_000_000) }
        AXUIElementSetAttributeValue(composer.area, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        try? await Task.sleep(nanoseconds: 250_000_000)
        Self.press(9, command: true) // ⌘V

        // 等「发送」按钮亮起（说明输入框真的收到了内容），再点它；点不到就回车
        var armed = false
        for _ in 0 ..< 14 {
            try? await Task.sleep(nanoseconds: 150_000_000)
            if let b = Self.findComposer(ax)?.send, Self.axValue(b, kAXEnabledAttribute) as? Bool == true { armed = true; break }
        }
        if armed, let b = Self.findComposer(ax)?.send {
            AXUIElementPerformAction(b, kAXPressAction as CFString)
        } else {
            Self.press(36, command: false)
        }

        // 还给你原来的 App；剪贴板也还原
        try? await Task.sleep(nanoseconds: 600_000_000)
        if let previous, !previous.isTerminated {
            app.hide() // 把 WorkBuddy 的窗口收起来（任务继续在后台跑），不留在你桌面上
            previous.activate()
        }
        if let old {
            Task {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                if pb.changeCount == change { pb.clearContents(); pb.setString(old, forType: .string) }
            }
        }
        return DispatchOutcome(ok: true, message: "已发送给 WorkBuddy，在后台运行。进度会显示在岛上，做完会弹验收卡。")
    }

    /// 接着 opencode 的某个会话再跑一轮（验收卡上追加指令）
    func continueOpenCode(sessionId: String?, dir: String, text: String) async -> DispatchOutcome {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return DispatchOutcome(ok: false, message: "没有内容") }
        let job = DispatchJob(target: .opencode, prompt: t, state: .running)
        let id = job.id
        jobs.insert(job, at: 0)
        let r = await OpenCodeRunner.run(prompt: t, dir: dir, sessionId: sessionId)
        if let i = jobs.firstIndex(where: { $0.id == id }) { jobs[i].state = r.ok ? .sent : .failed(r.message) }
        return r
    }

    private func waitForApp(_ bid: String) async -> NSRunningApplication? {
        for _ in 0 ..< 40 {
            if let a = NSRunningApplication.runningApplications(withBundleIdentifier: bid).first { return a }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return nil
    }

    private func copyForManual(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private static func press(_ key: CGKeyCode, command: Bool) {
        let src = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let ev = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: down)
            if command { ev?.flags = .maskCommand }
            ev?.post(tap: .cghidEventTap)
        }
    }

    // MARK: 辅助功能：找输入框和「发送」按钮

    /// WorkBuddy 的输入框是窗口里一个 AXTextArea，旁边有描述为「发送」的按钮（取最靠下的那组）
    private static func findComposer(_ app: AXUIElement) -> (area: AXUIElement, send: AXUIElement?)? {
        var area: (AXUIElement, CGFloat)?
        var send: (AXUIElement, CGFloat)?
        var visited = 0
        func walk(_ el: AXUIElement, _ depth: Int) {
            guard depth < 40, visited < 6000 else { return }
            visited += 1
            let role = axValue(el, kAXRoleAttribute) as? String ?? ""
            if role == "AXTextArea" {
                let y = axPoint(el)?.y ?? 0
                if area == nil || y > area!.1 { area = (el, y) }
            } else if role == "AXButton", (axValue(el, kAXDescriptionAttribute) as? String)?.hasPrefix("发送") == true || (axValue(el, kAXDescriptionAttribute) as? String) == "Send" {
                let y = axPoint(el)?.y ?? 0
                if send == nil || y > send!.1 { send = (el, y) }
            }
            for k in (axValue(el, kAXChildrenAttribute) as? [AXUIElement] ?? []) { walk(k, depth + 1) }
        }
        for w in (axValue(app, kAXWindowsAttribute) as? [AXUIElement] ?? []) { walk(w, 0) }
        guard let a = area else { return nil }
        return (a.0, send?.0)
    }

    private static func axValue(_ el: AXUIElement, _ attr: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success ? v : nil
    }

    private static func axPoint(_ el: AXUIElement) -> CGPoint? {
        guard let v = axValue(el, kAXPositionAttribute), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero
        return AXValueGetValue(v as! AXValue, .cgPoint, &p) ? p : nil
    }
}
