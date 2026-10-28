import Carbon
import Foundation

/// 全局快捷键（Carbon `RegisterEventHotKey`，不需要辅助功能权限）。
/// 每个实例是一个独立的热键（用 id 区分）：`shared` 给灵动岛，`quickAdd` 给全局万能输入，两个可以同时存在。
final class GlobalHotkey {
    static let shared = GlobalHotkey(id: 1)
    static let quickAdd = GlobalHotkey(id: 2)
    static let voice = GlobalHotkey(id: 3)

    var onPress: (() -> Void)?
    /// 松开（只有需要「按住说话」的热键用）
    var onRelease: (() -> Void)?

    private let id: UInt32
    private var ref: EventHotKeyRef?

    private static var handler: EventHandlerRef?
    private static var instances: [UInt32: GlobalHotkey] = [:]

    private init(id: UInt32) {
        self.id = id
        Self.instances[id] = self
    }

    /// 注册一个组合键；已被系统或其他 App 占用时返回 false
    @discardableResult
    func register(keyCode: UInt32, modifiers: UInt32) -> Bool {
        unregister()
        Self.installHandler()
        var r: EventHotKeyRef?
        let hid = EventHotKeyID(signature: OSType(0x5359_4958), id: id)
        let status = RegisterEventHotKey(keyCode, modifiers, hid, GetApplicationEventTarget(), 0, &r)
        guard status == noErr else { return false }
        ref = r
        return true
    }

    func unregister() {
        if let r = ref { UnregisterEventHotKey(r) }
        ref = nil
    }

    /// 只装一个系统事件处理器，按热键 id 分发给对应的实例
    private static func installHandler() {
        guard handler == nil else { return }
        var specs = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hkID = EventHotKeyID()
            let status = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &hkID
            )
            if status == noErr {
                let id = hkID.id
                if GetEventKind(event) == UInt32(kEventHotKeyReleased) {
                    DispatchQueue.main.async { GlobalHotkey.instances[id]?.onRelease?() }
                } else {
                    DispatchQueue.main.async { GlobalHotkey.instances[id]?.onPress?() }
                }
            }
            return noErr
        }, 2, &specs, nil, &handler)
    }
}
