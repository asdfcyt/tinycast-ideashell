import AppKit
import SwiftUI

/// 设置页「全局快捷键」里的一行：几个预设 + 自定义录制。万能输入 / 灵动岛 / 语音输入共用。
struct GlobalHotkeyRow<Choice: Hashable>: View {
    let title: String
    var hint: String?
    @Binding var choice: Choice
    let options: [(Choice, String)]
    let customChoice: Choice
    let owner: HotkeyOwner
    let saved: () -> HotkeyCombo?
    let save: (HotkeyCombo) -> Void
    let suspend: () -> Void
    let resume: () -> Void
    var registerError: String?

    @State private var recording = false
    @State private var monitor: Any?
    @State private var hint2: String?
    /// 录制后写进 UserDefaults：收到变化通知就刷新自定义组合的文字
    @State private var tick = 0

    private var customLabel: String {
        _ = tick
        return saved()?.label ?? "点击录制"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SRow(title, hint: hint) {
                HStack(spacing: 10) {
                    if choice == customChoice {
                        Button {
                            if recording { stopRecording() } else { startRecording() }
                        } label: {
                            Text(recording ? "按下新的组合键…（Esc 取消）" : customLabel)
                                .font(.system(size: 12, design: .monospaced).weight(.medium))
                        }
                        .buttonStyle(.bordered).controlSize(.small)
                        .tint(recording ? Color.accentColor : nil)
                    }
                    SPick(selection: $choice, options: options)
                }
            }

            if let msg = hint2 ?? registerError {
                Label(msg, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11.5)).foregroundStyle(Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onChange(of: choice) { _, new in
            hint2 = nil
            if new == customChoice {
                if saved() == nil { startRecording() }
            } else {
                stopRecording()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in tick += 1 }
        .onDisappear { stopRecording() }
    }

    // MARK: - 录制

    private func startRecording() {
        stopRecording()
        hint2 = nil
        recording = true
        suspend()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            handle(e)
            return nil
        }
    }

    private func stopRecording() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        if recording {
            recording = false
            resume()
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
        if let why = combo.problem(for: owner) {
            hint2 = why
            return
        }
        save(combo)
        hint2 = nil
        stopRecording()
    }
}

/// 全局万能输入
struct QuickAddHotkeyRow: View {
    @AppStorage(QuickAddHotkey.key) private var choice: QuickAddHotkey = .ctrlOptN
    @ObservedObject private var panel = QuickAddPanelController.shared

    var body: some View {
        GlobalHotkeyRow(
            title: "万能输入", choice: $choice,
            options: QuickAddHotkey.allCases.map { ($0, $0.label) }, customChoice: .custom, owner: .quickAdd,
            saved: { QuickAddHotkey.savedCustom }, save: QuickAddHotkey.saveCustom,
            suspend: { panel.suspendHotkey() }, resume: { panel.resumeHotkey() },
            registerError: panel.registerError
        )
    }
}

/// 灵动岛展开
struct IslandHotkeyRow: View {
    @AppStorage(DisplayMode.hotkeyKey) private var choice: IslandHotkey = .optSpace

    var body: some View {
        GlobalHotkeyRow(
            title: "灵动岛", choice: $choice,
            options: IslandHotkey.allCases.map { ($0, $0.label) }, customChoice: .custom, owner: .island,
            saved: { IslandHotkey.savedCustom }, save: IslandHotkey.saveCustom,
            suspend: { IslandController.shared.suspendHotkey() }, resume: { IslandController.shared.resumeHotkey() }
        )
    }
}
