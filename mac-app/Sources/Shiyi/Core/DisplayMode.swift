import Foundation

/// 小组件的呈现方式：菜单栏图标（点开弹窗），或贴在屏幕顶部的灵动岛（悬停展开）
enum DisplayMode: String, CaseIterable, Identifiable {
    case menuBar
    case island

    var id: String { rawValue }

    static let key = "ui.displayMode"
    /// 灵动岛：是否悬停刘海就展开（关掉后只能点击展开）
    static let hoverKey = "ui.islandHover"
    /// 灵动岛：触控板双指下滑展开 / 上滑收起
    static let swipeKey = "ui.islandSwipe"
    /// 灵动岛：截图 / 剪贴板里有新图片时弹出提示
    static let captureKey = "ui.islandCapture"
    /// 灵动岛：专注完成、待办到点等状态提醒
    static let activityKey = "ui.islandActivities"
    /// 灵动岛：全局快捷键
    static let hotkeyKey = "ui.islandHotkey"

    static var current: DisplayMode {
        DisplayMode(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .menuBar
    }

    static func flag(_ key: String, default d: Bool = true) -> Bool {
        (UserDefaults.standard.object(forKey: key) as? Bool) ?? d
    }

    static var hoverEnabled: Bool { flag(hoverKey) }
    static var swipeEnabled: Bool { flag(swipeKey) }
    static var captureEnabled: Bool { flag(captureKey) }
    static var activitiesEnabled: Bool { flag(activityKey) }
    static var hotkey: IslandHotkey {
        IslandHotkey(rawValue: UserDefaults.standard.string(forKey: hotkeyKey) ?? "") ?? .optSpace
    }

    var title: String {
        switch self {
        case .menuBar: return "状态栏图标"
        case .island: return "灵动岛"
        }
    }

    var subtitle: String {
        switch self {
        case .menuBar: return "图标显示在菜单栏，点击弹出待办"
        case .island: return "贴在屏幕顶部（刘海处），悬停展开"
        }
    }

    var icon: String {
        switch self {
        case .menuBar: return "menubar.rectangle"
        case .island: return "capsule.tophalf.filled"
        }
    }
}

/// 灵动岛的全局快捷键预设（Carbon 热键，不需要辅助功能权限）
enum IslandHotkey: String, CaseIterable, Identifiable {
    case off, optSpace, ctrlOptSpace, optShiftSpace

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: return "关闭"
        case .optSpace: return "⌥ Space"
        case .ctrlOptSpace: return "⌃⌥ Space"
        case .optShiftSpace: return "⌥⇧ Space"
        }
    }

    var keyCode: UInt32? { self == .off ? nil : 49 }

    /// Carbon 修饰键：cmd 256 / shift 512 / option 2048 / control 4096
    var modifiers: UInt32 {
        switch self {
        case .off: return 0
        case .optSpace: return 2048
        case .ctrlOptSpace: return 4096 | 2048
        case .optShiftSpace: return 2048 | 512
        }
    }
}
