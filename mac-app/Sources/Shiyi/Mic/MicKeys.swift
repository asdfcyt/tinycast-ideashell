import Foundation
import CoreGraphics

struct MicModInfo {
    let code: CGKeyCode
    let flag: UInt64   // 通用修饰位
    let dev: UInt64    // 设备相关位(区分左右键)
}

struct MicChord {
    var mods: [MicModInfo]
    var key: CGKeyCode?
}

enum MicKeys {
    static let modifiers: [String: MicModInfo] = [
        "cmd": MicModInfo(code: 55, flag: 0x100000, dev: 0x08), "rcmd": MicModInfo(code: 54, flag: 0x100000, dev: 0x10),
        "shift": MicModInfo(code: 56, flag: 0x20000, dev: 0x02), "rshift": MicModInfo(code: 60, flag: 0x20000, dev: 0x04),
        "alt": MicModInfo(code: 58, flag: 0x80000, dev: 0x20), "ralt": MicModInfo(code: 61, flag: 0x80000, dev: 0x40),
        "ctrl": MicModInfo(code: 59, flag: 0x40000, dev: 0x01), "rctrl": MicModInfo(code: 62, flag: 0x40000, dev: 0x2000),
        "fn": MicModInfo(code: 63, flag: 0x800000, dev: 0),
    ]
    static let modAliases: [String: String] = [
        "command": "cmd", "meta": "cmd", "win": "cmd", "super": "cmd", "rcommand": "rcmd",
        "option": "alt", "opt": "alt", "roption": "ralt", "ropt": "ralt",
        "control": "ctrl", "rcontrol": "rctrl", "globe": "fn",
    ]
    static let modifierCodes: Set<CGKeyCode> = Set(modifiers.values.map { $0.code })

    static let keycodes: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11,
        "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21,
        "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31,
        "u": 32, "[": 33, "i": 34, "p": 35, "enter": 36, "l": 37, "j": 38, "'": 39, "k": 40,
        ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "tab": 48, "space": 49,
        "`": 50, "backspace": 51, "esc": 53, "capslock": 57,
        "f5": 96, "f6": 97, "f7": 98, "f3": 99, "f8": 100, "f9": 101, "f11": 103, "f13": 105,
        "f16": 106, "f14": 107, "f10": 109, "f12": 111, "f15": 113, "help": 114, "home": 115,
        "pageup": 116, "delete": 117, "f4": 118, "end": 119, "f2": 120, "pagedown": 121, "f1": 122,
        "left": 123, "right": 124, "down": 125, "up": 126, "f17": 64, "f18": 79, "f19": 80, "f20": 90,
    ]
    static let keyAliases: [String: String] = [
        "return": "enter", "escape": "esc", "del": "backspace", "forwarddelete": "delete",
        "spacebar": "space", "pgup": "pageup", "pgdn": "pagedown", "minus": "-", "equal": "=",
        "comma": ",", "period": ".", "slash": "/", "semicolon": ";", "quote": "'", "grave": "`",
    ]

    /// 解析如 "cmd+shift+space"、"fn"、"ralt"、"enter" 的组合键;无法识别返回 nil。
    static func parse(_ text: String) -> MicChord? {
        var mods: [MicModInfo] = []
        var key: CGKeyCode?
        let parts = text.split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        for raw in parts where !raw.isEmpty {
            let name = modAliases[raw] ?? raw
            if let m = modifiers[name] {
                mods.append(m)
                continue
            }
            let k = keyAliases[name] ?? name
            guard let code = keycodes[k], key == nil else { return nil }
            key = code
        }
        if mods.isEmpty && key == nil { return nil }
        return MicChord(mods: mods, key: key)
    }

    /// 解析逗号分隔的多个组合键序列,如 "cmd+a, backspace"。任意一段无效则返回 nil。
    static func parseSequence(_ text: String) -> [MicChord]? {
        var out: [MicChord] = []
        for part in text.split(separator: ",") {
            let s = part.trimmingCharacters(in: .whitespaces)
            if s.isEmpty { continue }
            guard let c = parse(s) else { return nil }
            out.append(c)
        }
        return out.isEmpty ? nil : out
    }
}

/// 基于 CGEvent 的键盘事件注入(需要「辅助功能」权限)。
@MainActor
final class MicInjector {
    private var held: [String: (chord: MicChord, flags: UInt64)] = [:]

    private func post(code: CGKeyCode, down: Bool, flags: UInt64) {
        let src = CGEventSource(stateID: .hidSystemState)
        let ev: CGEvent?
        if MicKeys.modifierCodes.contains(code) {
            // 真实修饰键是 flagsChanged 事件;flags 必须带 0x100,否则豆包的 Fn 识别会失败
            ev = CGEvent(source: src)
            ev?.type = .flagsChanged
            ev?.setIntegerValueField(.keyboardEventKeycode, value: Int64(code))
            ev?.flags = CGEventFlags(rawValue: flags | 0x100)
        } else {
            ev = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down)
            ev?.flags = CGEventFlags(rawValue: flags)
        }
        ev?.post(tap: .cghidEventTap)
    }

    private func press(_ c: MicChord) -> UInt64 {
        var flags: UInt64 = 0
        for m in c.mods {
            flags |= m.flag | m.dev
            post(code: m.code, down: true, flags: flags)
        }
        if let k = c.key { post(code: k, down: true, flags: flags) }
        return flags
    }

    private func release(_ c: MicChord, flags startFlags: UInt64) {
        var flags = startFlags
        if let k = c.key { post(code: k, down: false, flags: flags) }
        for m in c.mods.reversed() {
            flags &= ~m.dev
            flags &= ~m.flag
            post(code: m.code, down: false, flags: flags)
        }
    }

    func tap(_ c: MicChord, holdMs: Int = 30) async {
        let flags = press(c)
        try? await Task.sleep(nanoseconds: UInt64(holdMs) * 1_000_000)
        release(c, flags: flags)
    }

    func down(_ c: MicChord, id: String) {
        if held[id] != nil { return }
        let flags = press(c)
        held[id] = (c, flags)
    }

    func up(id: String) {
        guard let h = held.removeValue(forKey: id) else { return }
        release(h.chord, flags: h.flags)
    }

    var isHolding: Bool { !held.isEmpty }

    func releaseAll() {
        for id in Array(held.keys) { up(id: id) }
    }
}
