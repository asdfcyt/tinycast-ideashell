import AppKit
import SwiftUI

// MARK: - 外观主题

/// 界面主题：跟随系统 / 明亮 / 暗黑。直接设给整个应用（主窗口、菜单栏弹窗、各种弹窗一起变）
enum AppTheme: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }
    static let key = "ui.theme"

    static var current: AppTheme {
        AppTheme(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .system
    }

    var title: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "明亮"
        case .dark: return "暗黑"
        }
    }

    var subtitle: String {
        switch self {
        case .system: return "随系统外观自动切换"
        case .light: return "始终使用浅色界面"
        case .dark: return "始终使用深色界面"
        }
    }

    var icon: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max"
        case .dark: return "moon"
        }
    }

    var appearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    @MainActor func apply() {
        guard NSApp.appearance?.name != appearance?.name else { return }
        NSApp.appearance = appearance
    }
}

// MARK: - 后台运行

/// 后台运行：关掉主窗口后应用继续跑（专注计时、提醒、灵动岛 / 菜单栏照常）；可选同时隐藏 Dock 图标
enum BackgroundPrefs {
    /// 没有窗口时隐藏 Dock 图标，只留菜单栏 / 灵动岛
    static let hideDockKey = "app.hideDockWhenClosed"
    static var hideDock: Bool { UserDefaults.standard.bool(forKey: hideDockKey) }
}

/// 计时进行中时告诉系统「这个应用有正事在做」：不要把它放进 App Nap，否则后台的秒级计时会被拉长、到点提醒会晚
@MainActor
enum BackgroundActivity {
    private static var token: NSObjectProtocol?

    static func set(_ active: Bool) {
        if active, token == nil {
            token = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "拾忆：专注计时与提醒")
        } else if !active, let t = token {
            ProcessInfo.processInfo.endActivity(t)
            token = nil
        }
    }
}

extension AppModel {
    /// 给系统「服务」菜单这类拿不到 SwiftUI 环境的入口用
    static weak var current: AppModel?
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var observers: [NSObjectProtocol] = []

    /// 系统「服务」菜单里的「记到拾忆」：在任何 App 里选中文字 / 图片 / 文件，右键 → 服务 → 记到拾忆。
    /// 内容和拖到灵动岛一样处理（文字自动识别成待办 / 日记 / 笔记，图片存成带识别文字的笔记）。
    @objc func captureService(_ pboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let raw = DropReader.read(pboard)
        guard !raw.isEmpty else {
            error.pointee = "没有读到可以保存的内容"
            return
        }
        Task { @MainActor in
            guard let model = AppModel.current else {
                Notifier.post(id: "shiyi.service", title: "拾忆", body: "拾忆还没准备好，请稍后再试")
                return
            }
            do {
                let msg = try await model.submitDrop(raw)
                model.showNotice(msg)
                Notifier.post(id: "shiyi.service", title: "已记到拾忆", body: msg)
            } catch {
                Notifier.post(id: "shiyi.service", title: "记到拾忆失败", body: error.localizedDescription)
            }
        }
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        AppTheme.current.apply()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 系统不要在应用空闲时把它自动退出：它要一直在后台提醒
        ProcessInfo.processInfo.disableAutomaticTermination("拾忆在后台运行")
        ProcessInfo.processInfo.disableSuddenTermination()
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()

        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                AppTheme.current.apply()
                self?.updateDockPolicy()
            }
        })
        for name in [NSWindow.willCloseNotification, NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification, NSWindow.didBecomeMainNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                // 窗口关闭的通知发出时它还算「可见」：等一拍再看
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self?.updateDockPolicy() }
            })
        }
    }

    /// 关掉最后一个窗口，应用不退出
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// 点 Dock 图标：窗口都关着就重新打开主窗口
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !hasMainWindow { MainWindow.show() }
        return true
    }

    private var hasMainWindow: Bool {
        NSApp.windows.contains { $0.canBecomeMain && ($0.isVisible || $0.isMiniaturized) }
    }

    /// 勾了「隐藏 Dock 图标」且没有窗口时变成纯后台（accessory）；有窗口就变回普通应用
    private func updateDockPolicy() {
        let want: NSApplication.ActivationPolicy = (BackgroundPrefs.hideDock && !hasMainWindow) ? .accessory : .regular
        if NSApp.activationPolicy() != want { NSApp.setActivationPolicy(want) }
    }
}
