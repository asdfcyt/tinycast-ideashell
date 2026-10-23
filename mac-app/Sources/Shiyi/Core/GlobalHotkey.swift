import Carbon
import Foundation

/// 全局快捷键（Carbon `RegisterEventHotKey`，不需要辅助功能权限）。同一时间只注册一个。
final class GlobalHotkey {
    static let shared = GlobalHotkey()

    var onPress: (() -> Void)?
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?

    func register(_ hk: IslandHotkey) {
        unregister()
        guard let code = hk.keyCode else { return }
        if handler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                DispatchQueue.main.async { GlobalHotkey.shared.onPress?() }
                return noErr
            }, 1, &spec, nil, &handler)
        }
        let id = EventHotKeyID(signature: OSType(0x5359_4958), id: 1)
        RegisterEventHotKey(code, hk.modifiers, id, GetApplicationEventTarget(), 0, &ref)
    }

    func unregister() {
        if let r = ref { UnregisterEventHotKey(r) }
        ref = nil
    }
}
