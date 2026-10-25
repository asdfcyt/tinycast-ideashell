import AppKit
import ApplicationServices

/// 单个修饰键的「按住」热键（只按 ⌥ / fn 之类，不带别的键）。
/// Carbon 的热键必须有一个普通键，做不到「只按 Option」，所以改用事件监听：
///   · 按下并保持超过 `holdDelay` 才算触发——快速点一下 Option、或者 Option+别的键 / Option+点击，都不会误触发
///   · 触发后一直到松开修饰键，才发 `onRelease`
/// 监听别的 App 里的按键需要「输入监控」（或「辅助功能」）权限。
@MainActor
final class ModifierHotkey {
    struct Key: Equatable {
        /// 左 / 右键对应的 keyCode
        let codes: Set<UInt16>
        let flag: NSEvent.ModifierFlags
    }

    static let option = Key(codes: [58, 61], flag: .option)
    static let rightOption = Key(codes: [61], flag: .option)
    static let rightCommand = Key(codes: [54], flag: .command)
    static let fn = Key(codes: [63], flag: .function)

    static let holdDelay: TimeInterval = 0.15

    var onHold: (() -> Void)?
    var onRelease: (() -> Void)?

    private var key: Key?
    private var global: Any?
    private var local: Any?
    private var down = Set<UInt16>()
    private var timer: Timer?
    private var fired = false

    static var permitted: Bool { CGPreflightListenEventAccess() || AXIsProcessTrusted() }

    /// 弹出系统的「输入监控」授权提示（只会弹一次，之后要到系统设置里手动开）
    static func requestPermission() { _ = CGRequestListenEventAccess() }

    func start(_ key: Key) {
        if self.key == key, global != nil { return }
        stop()
        self.key = key
        // 不监听鼠标按下：「按住 ⌥ + 点击」靠触发时看最近有没有点击来排除，免得给鼠标事件加监听影响窗口按钮的点击
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown]
        global = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] e in
            let type = e.type, code = e.keyCode, flags = e.modifierFlags
            MainActor.assumeIsolated { self?.handle(type: type, code: code, flags: flags) }
        }
        // 拾忆自己的窗口在前台（比如录音卡片是 key window）时，事件不会走全局监听
        local = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] e in
            let type = e.type, code = e.keyCode, flags = e.modifierFlags
            MainActor.assumeIsolated { self?.handle(type: type, code: code, flags: flags) }
            return e
        }
    }

    func stop() {
        if let g = global { NSEvent.removeMonitor(g) }
        if let l = local { NSEvent.removeMonitor(l) }
        global = nil
        local = nil
        key = nil
        down.removeAll()
        timer?.invalidate()
        timer = nil
        if fired {
            fired = false
            onRelease?()
        }
    }

    private func handle(type: NSEvent.EventType, code: UInt16, flags: NSEvent.ModifierFlags) {
        guard let key else { return }
        switch type {
        case .keyDown, .leftMouseDown, .rightMouseDown:
            // 按住修饰键时又按了别的键 / 点了鼠标：是正常的组合用法，不触发
            if !fired { cancelTimer() }
        case .flagsChanged:
            let others = flags.intersection([.command, .option, .control, .shift]).subtracting(key.flag)
            if key.codes.contains(code) {
                if flags.contains(key.flag) { down.insert(code) } else { down.remove(code) }
            }
            if !flags.contains(key.flag) { down.removeAll() }

            if !down.isEmpty, others.isEmpty {
                if timer == nil, !fired {
                    let t = Timer(timeInterval: Self.holdDelay, repeats: false) { [weak self] _ in
                        MainActor.assumeIsolated { self?.fire() }
                    }
                    RunLoop.main.add(t, forMode: .common)
                    timer = t
                }
            } else if down.isEmpty {
                cancelTimer()
                if fired {
                    fired = false
                    onRelease?()
                }
            } else {
                // 又按了别的修饰键（比如 ⌥⌘）：没触发就放弃这次
                if !fired { cancelTimer() }
            }
        default: break
        }
    }

    private func cancelTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func fire() {
        timer = nil
        guard !down.isEmpty else { return }
        // 按住修饰键期间点过鼠标：是 ⌥ + 点击这类组合用法，不触发
        let sinceClick = min(
            CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .leftMouseDown),
            CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .rightMouseDown)
        )
        if sinceClick < Self.holdDelay + 0.05 { return }
        fired = true
        onHold?()
    }
}
