import AppKit
import SwiftUI

/// 应用内（菜单栏里的）快捷键：可以在「设置 → 通用」里改。全局快捷键另有一套（Carbon 热键，见 GlobalHotkey）。
enum AppShortcutID: String, CaseIterable, Identifiable {
    case quickAdd, note, todo, daily, refresh, settings, mainWindow
    case pageToday, pageFocus, pageTodos, pageCalendar, pageReview, pageInsights

    var id: String { rawValue }

    /// 「切换页面」那一组
    var section: AppSection? {
        switch self {
        case .pageToday: return .today
        case .pageFocus: return .focus
        case .pageTodos: return .todos
        case .pageCalendar: return .calendar
        case .pageReview: return .review
        case .pageInsights: return .insights
        default: return nil
        }
    }

    static func page(_ s: AppSection) -> AppShortcutID? {
        allCases.first { $0.section == s }
    }

    static var actions: [AppShortcutID] { allCases.filter { $0.section == nil } }
    static var pages: [AppShortcutID] { allCases.filter { $0.section != nil } }

    var title: String {
        if let s = section { return s.title }
        switch self {
        case .quickAdd: return "万能输入"
        case .note: return "记笔记"
        case .todo: return "记待办"
        case .daily: return "记日记"
        case .refresh: return "刷新当前页"
        case .settings: return "打开设置"
        case .mainWindow: return "打开拾忆主窗口"
        default: return ""
        }
    }

    /// 出厂快捷键
    var defaultShortcut: AppShortcut {
        let cmd = HotkeyCombo.Mod.cmd, shift = HotkeyCombo.Mod.shift
        switch self {
        case .quickAdd: return AppShortcut(key: "n", mods: cmd)
        case .note: return AppShortcut(key: "n", mods: cmd | shift)
        case .todo: return AppShortcut(key: "t", mods: cmd | shift)
        case .daily: return AppShortcut(key: "d", mods: cmd | shift)
        case .refresh: return AppShortcut(key: "r", mods: cmd)
        case .settings: return AppShortcut(key: ",", mods: cmd)
        case .mainWindow: return AppShortcut(key: "0", mods: cmd)
        case .pageToday: return AppShortcut(key: "1", mods: cmd)
        case .pageFocus: return AppShortcut(key: "2", mods: cmd)
        case .pageTodos: return AppShortcut(key: "3", mods: cmd)
        case .pageCalendar: return AppShortcut(key: "4", mods: cmd)
        case .pageReview: return AppShortcut(key: "5", mods: cmd)
        case .pageInsights: return AppShortcut(key: "6", mods: cmd)
        }
    }
}

/// 一个应用内快捷键：按键（单个字符，或 space / return / tab / delete / left / right / up / down）+ Carbon 修饰键
struct AppShortcut: Codable, Equatable {
    var key: String
    var mods: UInt32

    var keyEquivalent: KeyEquivalent? {
        switch key {
        case "space": return .space
        case "return": return .return
        case "tab": return .tab
        case "delete": return .delete
        case "left": return .leftArrow
        case "right": return .rightArrow
        case "up": return .upArrow
        case "down": return .downArrow
        default:
            guard let c = key.first, key.count == 1 else { return nil }
            return KeyEquivalent(c)
        }
    }

    var eventModifiers: EventModifiers {
        var m: EventModifiers = []
        if mods & HotkeyCombo.Mod.cmd != 0 { m.insert(.command) }
        if mods & HotkeyCombo.Mod.shift != 0 { m.insert(.shift) }
        if mods & HotkeyCombo.Mod.option != 0 { m.insert(.option) }
        if mods & HotkeyCombo.Mod.control != 0 { m.insert(.control) }
        return m
    }

    var keyLabel: String {
        switch key {
        case "space": return "Space"
        case "return": return "↩"
        case "tab": return "⇥"
        case "delete": return "⌫"
        case "left": return "←"
        case "right": return "→"
        case "up": return "↑"
        case "down": return "↓"
        default: return key.uppercased()
        }
    }

    var label: String { HotkeyCombo.symbols(mods) + " " + keyLabel }

    /// 从按键事件生成；不支持的键（F 键等）返回 nil
    static func from(_ e: NSEvent) -> AppShortcut? {
        let flags = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let mods = HotkeyCombo.carbonMods(flags)
        switch e.keyCode {
        case 49: return AppShortcut(key: "space", mods: mods)
        case 36, 76: return AppShortcut(key: "return", mods: mods)
        case 48: return AppShortcut(key: "tab", mods: mods)
        case 51: return AppShortcut(key: "delete", mods: mods)
        case 123: return AppShortcut(key: "left", mods: mods)
        case 124: return AppShortcut(key: "right", mods: mods)
        case 125: return AppShortcut(key: "down", mods: mods)
        case 126: return AppShortcut(key: "up", mods: mods)
        default:
            guard let s = e.characters(byApplyingModifiers: [])?.lowercased(), s.count == 1,
                  let u = s.unicodeScalars.first, !(0xF700 ... 0xF8FF).contains(u.value), u.value >= 0x21 else { return nil }
            return AppShortcut(key: s, mods: mods)
        }
    }

    /// 系统和标准编辑菜单占着的组合，不让改成它们
    private static let reserved: Set<String> = [
        "q|\(HotkeyCombo.Mod.cmd)", "w|\(HotkeyCombo.Mod.cmd)", "h|\(HotkeyCombo.Mod.cmd)", "m|\(HotkeyCombo.Mod.cmd)",
        "c|\(HotkeyCombo.Mod.cmd)", "v|\(HotkeyCombo.Mod.cmd)", "x|\(HotkeyCombo.Mod.cmd)", "a|\(HotkeyCombo.Mod.cmd)",
        "z|\(HotkeyCombo.Mod.cmd)", "z|\(HotkeyCombo.Mod.cmd | HotkeyCombo.Mod.shift)",
        "h|\(HotkeyCombo.Mod.cmd | HotkeyCombo.Mod.option)",
    ]

    var isReserved: Bool { Self.reserved.contains("\(key)|\(mods)") }
}

/// 应用内快捷键的存取：只存用户改过的，没改的用出厂值
@MainActor
final class AppShortcutStore: ObservableObject {
    static let shared = AppShortcutStore()
    static let key = "ui.appShortcuts"

    @Published private(set) var custom: [String: AppShortcut]
    /// 正在录制的那一行（同一时间只有一行）
    @Published var recordingID: AppShortcutID?

    private init() { custom = Self.loadCustom() }

    nonisolated static func loadCustom() -> [String: AppShortcut] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let m = try? JSONDecoder().decode([String: AppShortcut].self, from: data) else { return [:] }
        return m
    }

    /// 不依赖主线程的读取（给全局快捷键查撞键用）
    nonisolated static func current(_ id: AppShortcutID) -> AppShortcut {
        loadCustom()[id.rawValue] ?? id.defaultShortcut
    }

    /// 全局快捷键（⌃/⌥ + 键）和哪个应用内快捷键撞了
    nonisolated static func conflictingID(key: String, mods: UInt32) -> AppShortcutID? {
        let k = key.lowercased()
        return AppShortcutID.allCases.first { id in
            let s = current(id)
            return s.mods == mods && s.key == k
        }
    }

    func shortcut(_ id: AppShortcutID) -> AppShortcut { custom[id.rawValue] ?? id.defaultShortcut }
    func isCustom(_ id: AppShortcutID) -> Bool { custom[id.rawValue] != nil }
    var hasAnyCustom: Bool { !custom.isEmpty }

    /// nil = 可以用；否则是原因
    func problem(_ s: AppShortcut, for id: AppShortcutID) -> String? {
        if s.mods & (HotkeyCombo.Mod.cmd | HotkeyCombo.Mod.control) == 0 {
            return "要包含 ⌘ 或 ⌃，否则会和打字冲突"
        }
        if s.isReserved { return "这个组合是系统保留的，请换一个" }
        for other in AppShortcutID.allCases where other != id {
            if shortcut(other) == s { return "已经是「\(other.title)」的快捷键" }
        }
        for o in HotkeyOwner.allCases {
            if let c = o.currentCombo, c.mods == s.mods, c.name.lowercased() == s.key {
                return "和全局快捷键「\(o.title)」相同"
            }
        }
        return nil
    }

    func set(_ id: AppShortcutID, _ s: AppShortcut) {
        if s == id.defaultShortcut { custom[id.rawValue] = nil } else { custom[id.rawValue] = s }
        save()
    }

    func reset(_ id: AppShortcutID) {
        custom[id.rawValue] = nil
        save()
    }

    /// 外部（导入设置）改了 UserDefaults 之后重新读一遍
    func reload() { custom = Self.loadCustom() }

    func resetAll() {
        custom = [:]
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(custom) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}

extension View {
    /// 菜单项上挂应用内快捷键（没有按键就不挂）
    @ViewBuilder func appShortcut(_ s: AppShortcut) -> some View {
        if let k = s.keyEquivalent {
            keyboardShortcut(k, modifiers: s.eventModifiers)
        } else {
            self
        }
    }
}
