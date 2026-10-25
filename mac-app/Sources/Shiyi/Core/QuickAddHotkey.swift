import AppKit
import Foundation

/// 一个全局组合键：硬件键码 + Carbon 修饰键（cmd 256 / shift 512 / option 2048 / control 4096）
struct HotkeyCombo: Equatable {
    var code: UInt32
    var mods: UInt32
    /// 按键的显示名（录制时取，布局相关）
    var name: String

    enum Mod {
        static let cmd: UInt32 = 256
        static let shift: UInt32 = 512
        static let option: UInt32 = 2048
        static let control: UInt32 = 4096
    }

    static let spaceCode: UInt32 = 49

    /// 「⌃⌥ N」
    var label: String { Self.symbols(mods) + " " + name }

    static func symbols(_ mods: UInt32) -> String {
        var s = ""
        if mods & Mod.control != 0 { s += "⌃" }
        if mods & Mod.option != 0 { s += "⌥" }
        if mods & Mod.shift != 0 { s += "⇧" }
        if mods & Mod.cmd != 0 { s += "⌘" }
        return s
    }

    static func carbonMods(_ f: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if f.contains(.command) { m |= Mod.cmd }
        if f.contains(.shift) { m |= Mod.shift }
        if f.contains(.option) { m |= Mod.option }
        if f.contains(.control) { m |= Mod.control }
        return m
    }

    static func keyName(code: UInt16, chars: String?) -> String {
        switch code {
        case 49: return "Space"
        case 36, 76: return "↩"
        case 48: return "⇥"
        case 51: return "⌫"
        case 117: return "⌦"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        case 115: return "Home"
        case 119: return "End"
        case 116: return "PgUp"
        case 121: return "PgDn"
        case 122: return "F1"
        case 120: return "F2"
        case 99: return "F3"
        case 118: return "F4"
        case 96: return "F5"
        case 97: return "F6"
        case 98: return "F7"
        case 100: return "F8"
        case 101: return "F9"
        case 109: return "F10"
        case 103: return "F11"
        case 111: return "F12"
        default:
            let c = (chars ?? "").trimmingCharacters(in: .whitespaces).uppercased()
            return c.isEmpty ? "键 \(code)" : c
        }
    }

    /// nil = 可以用；否则是不能用的原因。
    /// 全局热键会吞掉这个组合：只有 ⌘ / ⇧ 的组合会把各个 App 自己的快捷键（⌘Q、⌘W、⇧⌘N…）抢走，所以必须带 ⌃ 或 ⌥，
    /// 带一个 ⌃ 或 ⌥ 加字母就可以（如 ⌥ V）。
    var problem: String? {
        let hasCtrlOrOpt = mods & (Mod.control | Mod.option) != 0
        if !hasCtrlOrOpt { return "要包含 ⌃ 或 ⌥：只有 ⌘ / ⇧ 的组合会抢走各个 App 自己的快捷键" }
        if DisplayMode.current == .island, let ik = DisplayMode.hotkey.keyCode,
           ik == code, DisplayMode.hotkey.modifiers == mods {
            return "和灵动岛的快捷键相同，请换一个"
        }
        return nil
    }
}

/// 全局万能输入快捷键的设置：几个预设 + 自定义录制。默认 ⌃⌥ N。
enum QuickAddHotkey: String, CaseIterable, Identifiable {
    case off, ctrlOptN, optCmdN, ctrlOptSpace, custom

    static let key = "ui.quickAddHotkey"
    static let customCodeKey = "ui.quickAddHotkey.code"
    static let customModsKey = "ui.quickAddHotkey.mods"
    static let customNameKey = "ui.quickAddHotkey.name"

    var id: String { rawValue }

    static var current: QuickAddHotkey {
        QuickAddHotkey(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .ctrlOptN
    }

    var label: String {
        switch self {
        case .off: return "关闭"
        case .ctrlOptN: return "⌃⌥ N"
        case .optCmdN: return "⌥⌘ N"
        case .ctrlOptSpace: return "⌃⌥ Space"
        case .custom: return "自定义…"
        }
    }

    /// 实际要注册的组合；关闭、或选了自定义但还没录制时为 nil
    var combo: HotkeyCombo? {
        switch self {
        case .off: return nil
        case .ctrlOptN: return HotkeyCombo(code: 45, mods: HotkeyCombo.Mod.control | HotkeyCombo.Mod.option, name: "N")
        case .optCmdN: return HotkeyCombo(code: 45, mods: HotkeyCombo.Mod.option | HotkeyCombo.Mod.cmd, name: "N")
        case .ctrlOptSpace: return HotkeyCombo(code: HotkeyCombo.spaceCode, mods: HotkeyCombo.Mod.control | HotkeyCombo.Mod.option, name: "Space")
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
