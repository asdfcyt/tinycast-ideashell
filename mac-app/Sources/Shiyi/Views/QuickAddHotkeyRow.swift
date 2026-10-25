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
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "keyboard")
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(Brand.orange)
                    .frame(width: 30, height: 30)
                    .background(Brand.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text("全局万能输入")
                    Text("在任何 App 里按下，弹出悬浮输入框；回车保存后自动消失，Esc 关闭")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Picker("", selection: $choice) {
                    ForEach(QuickAddHotkey.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden().frame(width: 130)
            }

            if choice == .custom {
                HStack(spacing: 10) {
                    Spacer(minLength: 0)
                    Button {
                        if recording { stopRecording() } else { startRecording() }
                    } label: {
                        Text(recording ? "按下新的组合键…（Esc 取消）" : customLabel)
                            .font(.callout.monospaced().weight(.medium))
                            .frame(minWidth: 170)
                    }
                    .buttonStyle(.bordered)
                    .tint(recording ? Brand.orange : nil)
                }
            }

            if let msg = hint ?? panel.registerError {
                Label(msg, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(Color.orange)
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
