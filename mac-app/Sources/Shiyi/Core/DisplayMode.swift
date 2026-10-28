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
    /// 灵动岛：暂存架（展开页底部、拖放右半边、截图提示的「暂存」）
    static let shelfKey = "ui.islandShelf"
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
    static var shelfEnabled: Bool { flag(shelfKey) }
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

/// 灵动岛的全局快捷键：几个预设 + 自定义录制（Carbon 热键，不需要辅助功能权限）
enum IslandHotkey: String, CaseIterable, Identifiable {
    case off, optSpace, ctrlOptSpace, optShiftSpace, custom

    static let customCodeKey = "ui.islandHotkey.code"
    static let customModsKey = "ui.islandHotkey.mods"
    static let customNameKey = "ui.islandHotkey.name"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: return "关闭"
        case .optSpace: return "⌥ Space"
        case .ctrlOptSpace: return "⌃⌥ Space"
        case .optShiftSpace: return "⌥⇧ Space"
        case .custom: return "自定义…"
        }
    }

    /// 实际要注册的组合；关闭、或选了自定义但还没录制时为 nil
    var combo: HotkeyCombo? {
        let o = HotkeyCombo.Mod.option
        switch self {
        case .off: return nil
        case .optSpace: return HotkeyCombo(code: HotkeyCombo.spaceCode, mods: o, name: "Space")
        case .ctrlOptSpace: return HotkeyCombo(code: HotkeyCombo.spaceCode, mods: HotkeyCombo.Mod.control | o, name: "Space")
        case .optShiftSpace: return HotkeyCombo(code: HotkeyCombo.spaceCode, mods: o | HotkeyCombo.Mod.shift, name: "Space")
        case .custom: return Self.savedCustom
        }
    }

    static var savedCustom: HotkeyCombo? {
        let d = UserDefaults.standard
        guard d.object(forKey: customCodeKey) != nil else { return nil }
        return HotkeyCombo(
            code: UInt32(max(d.integer(forKey: customCodeKey), 0)),
            mods: UInt32(max(d.integer(forKey: customModsKey), 0)),
            name: d.string(forKey: customNameKey) ?? "?"
        )
    }

    static func saveCustom(_ c: HotkeyCombo) {
        let d = UserDefaults.standard
        d.set(Int(c.code), forKey: customCodeKey)
        d.set(Int(c.mods), forKey: customModsKey)
        d.set(c.name, forKey: customNameKey)
    }
}
