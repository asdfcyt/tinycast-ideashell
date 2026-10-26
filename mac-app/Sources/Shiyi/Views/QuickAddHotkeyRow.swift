import AppKit
import SwiftUI

/// 设置页「快捷键」里的一行：全局万能输入的快捷键。几个预设 + 自定义录制。
struct QuickAddHotkeyRow: View {
    @AppStorage(QuickAddHotkey.key) private var choice: QuickAddHotkey = .ctrlOptN
    // 录制后写进 UserDefaults 的值：监听它们只是为了让自定义组合的文字跟着刷新
    @AppStorage(QuickAddHotkey.customCodeKey) private var customCode = -1
    @AppStorage(QuickAddHotkey.customModsKey) private var customMods = 0
    @AppStorage(QuickAddHotkey.customNameKey) private var customName = ""
    @ObservedObject private var panel = QuickAddPanelController.shared

    @State private var recording = false
    @State private var monitor: Any?
    @State private var hint: String?

    private var customLabel: String {
        _ = (customCode, customMods, customName)
        return QuickAddHotkey.savedCustom?.label ?? "点击录制"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SRow("全局万能输入", hint: "在任何 App 里按下，弹出悬浮输入框；回车保存后自动消失，Esc 关闭") {
                HStack(spacing: 10) {
                    if choice == .custom {
                        Button {
                            if recording { stopRecording() } else { startRecording() }
                        } label: {
                            Text(recording ? "按下新的组合键…（Esc 取消）" : customLabel)
                                .font(.system(size: 12, design: .monospaced).weight(.medium))
                        }
                        .buttonStyle(.bordered).controlSize(.small)
                        .tint(recording ? Color.accentColor : nil)
                    }
                    SPick(selection: $choice, options: QuickAddHotkey.allCases.map { ($0, $0.label) })
                }
            }

            if let msg = hint ?? panel.registerError {
                Label(msg, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11.5)).foregroundStyle(Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onChange(of: choice) { _, new in
            hint = nil
            if new == .custom {
                if QuickAddHotkey.savedCustom == nil { startRecording() }
            } else {
                stopRecording()
            }
        }
        .onDisappear { stopRecording() }
    }

    // MARK: - 录制

    private func startRecording() {
        stopRecording()
        hint = nil
        recording = true
        panel.suspendHotkey()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            handle(e)
            return nil
        }
    }

    private func stopRecording() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        if recording {
            recording = false
            panel.resumeHotkey()
        }
    }

    private func handle(_ e: NSEvent) {
        let flags = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // 单按 Esc：取消录制
        if e.keyCode == 53, flags.isEmpty {
            stopRecording()
            return
        }
        let combo = HotkeyCombo(
            code: UInt32(e.keyCode),
            mods: HotkeyCombo.carbonMods(flags),
            name: HotkeyCombo.keyName(code: e.keyCode, chars: e.charactersIgnoringModifiers)
        )
        // 不能用的组合：提示原因，继续等下一次按键
        if let why = combo.problem {
            hint = why
            return
        }
        QuickAddHotkey.saveCustom(combo)
        hint = nil
        stopRecording()
    }
}
