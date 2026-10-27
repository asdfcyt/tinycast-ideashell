import AppKit
import CoreGraphics

/// 按键录制:录制期间在系统事件层拦截键盘事件(吞掉),
/// 这样录制 ⌥Space 之类的组合时,不会触发其它 App(或本机)已经绑定的全局热键。
/// 支持:普通组合键(alt+space)、单独的修饰键(fn / rcmd / ralt…,按下再松开)。
/// 需要「辅助功能」权限才能创建系统层拦截;没有权限时退回到只在本窗口内录制。
@MainActor
final class MicKeyRecorder: ObservableObject {
    static let shared = MicKeyRecorder()

    @Published private(set) var activeID: String?
    @Published private(set) var usingSystemTap = false
    private var completion: ((String) -> Void)?

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var localMonitor: Any?

    // 单独修饰键的录制状态
    private var candidate: String?
    private var sawKey = false

    private static let modifierNames: [Int64: String] = [
        55: "cmd", 54: "rcmd", 56: "shift", 60: "rshift",
        58: "alt", 61: "ralt", 59: "ctrl", 62: "rctrl", 63: "fn",
    ]
    private static let keyNames: [Int64: String] = {
        var m: [Int64: String] = [:]
        for (name, code) in MicKeys.keycodes { m[Int64(code)] = name }
        return m
    }()

    func begin(id: String, completion: @escaping (String) -> Void) {
        cancel()
        activeID = id
        VoiceController.shared.suspendHotkey()   // 免得录制到拾忆自己的语音热键时反而开始录音
        self.completion = completion
        candidate = nil
        sawKey = false
        if !installTap() { installLocalMonitor() }
    }

    func cancel() {
        removeTap()
        if let m = localMonitor { NSEvent.removeMonitor(m); localMonitor = nil }
        if activeID != nil { VoiceController.shared.resumeHotkey() }
        activeID = nil
        completion = nil
        candidate = nil
        usingSystemTap = false
    }

    private func finish(_ text: String) {
        let done = completion
        cancel()
        done?(text)
    }

    // MARK: - 系统层拦截

    private func installTap() -> Bool {
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        let callback: CGEventTapCallBack = { _, type, event, ctx in
            guard let ctx else { return Unmanaged.passUnretained(event) }
            let rec = Unmanaged<MicKeyRecorder>.fromOpaque(ctx).takeUnretainedValue()
            return MainActor.assumeIsolated { rec.handleTap(type: type, event: event) }
        }
        var created: CFMachPort?
        for location in [CGEventTapLocation.cghidEventTap, CGEventTapLocation.cgSessionEventTap] {
            created = CGEvent.tapCreate(tap: location, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: mask, callback: callback, userInfo: ctx)
            if created != nil { break }
        }
        guard let port = created else { return false }
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        tap = port
        source = src
        usingSystemTap = true
        return true
    }

    private func removeTap() {
        if let port = tap { CGEvent.tapEnable(tap: port, enable: false); CFMachPortInvalidate(port) }
        if let src = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes) }
        tap = nil
        source = nil
    }

    private func handleTap(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let port = tap { CGEvent.tapEnable(tap: port, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags.rawValue
        switch type {
        case .keyDown:
            handleKeyDown(code: code, flags: flags)
            return nil           // 吞掉,不让别的 App 的全局热键响应
        case .keyUp:
            return nil
        case .flagsChanged:
            handleFlags(code: code, flags: flags)
            return Unmanaged.passUnretained(event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    // MARK: - 窗口内兜底

    private func installLocalMonitor() {
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] e in
            guard let self else { return e }
            let code = Int64(e.keyCode)
            let flags = UInt64(e.modifierFlags.rawValue)
            if e.type == .keyDown {
                self.handleKeyDown(code: code, flags: flags)
                return nil
            }
            self.handleFlags(code: code, flags: flags)
            return e
        }
    }

    // MARK: - 解析

    private func handleKeyDown(code: Int64, flags: UInt64) {
        sawKey = true
        let mods = Self.modifierPrefix(flags)
        if code == 53 && mods.isEmpty {       // 单独 Esc:取消录制
            cancel()
            return
        }
        guard let name = Self.keyNames[code] else { return }
        finish((mods + [name]).joined(separator: "+"))
    }

    private func handleFlags(code: Int64, flags: UInt64) {
        guard let name = Self.modifierNames[code] else { return }
        let isDown = Self.isDown(code: code, flags: flags)
        if isDown {
            candidate = name
            sawKey = false
        } else if candidate == name, !sawKey {
            finish(name)                       // 按下后直接松开:单独修饰键
        }
    }

    private static func isDown(code: Int64, flags: UInt64) -> Bool {
        switch code {
        case 55: return flags & 0x08 != 0
        case 54: return flags & 0x10 != 0
        case 56: return flags & 0x02 != 0
        case 60: return flags & 0x04 != 0
        case 58: return flags & 0x20 != 0
        case 61: return flags & 0x40 != 0
        case 59: return flags & 0x01 != 0
        case 62: return flags & 0x2000 != 0
        case 63: return flags & 0x800000 != 0
        default: return false
        }
    }

    /// 当前按住的修饰键(区分左右)。
    private static func modifierPrefix(_ flags: UInt64) -> [String] {
        var out: [String] = []
        func side(_ left: UInt64, _ right: UInt64, _ generic: UInt64, _ l: String, _ r: String) {
            guard flags & generic != 0 else { return }
            let hasL = flags & left != 0, hasR = flags & right != 0
            if hasL { out.append(l) }
            if hasR { out.append(r) }
            if !hasL && !hasR { out.append(l) }   // 没有设备位时按左侧处理
        }
        side(0x01, 0x2000, 0x40000, "ctrl", "rctrl")
        side(0x20, 0x40, 0x80000, "alt", "ralt")
        side(0x02, 0x04, 0x20000, "shift", "rshift")
        side(0x08, 0x10, 0x100000, "cmd", "rcmd")
        if flags & 0x800000 != 0 { out.append("fn") }
        return out
    }
}
