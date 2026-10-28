import AppKit
import SwiftUI

/// 设置页「应用内快捷键」里的一行：点一下快捷键，直接按下想要的组合就改好；改过的行右边有个还原图标。
struct AppShortcutRow: View {
    let id: AppShortcutID
    @ObservedObject private var store = AppShortcutStore.shared
    @State private var monitor: Any?
    @State private var hint: String?

    private var recording: Bool { store.recordingID == id }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SRow(id.title) {
                HStack(spacing: 8) {
                    if store.isCustom(id) {
                        SIconButton(symbol: "arrow.counterclockwise", help: "还原为 \(id.defaultShortcut.label)") {
                            store.reset(id)
                            hint = nil
                        }
                    }
                    Button {
                        store.recordingID = recording ? nil : id
                    } label: {
                        Text(recording ? "按下新的快捷键…（Esc 取消）" : store.shortcut(id).label)
                            .font(.system(size: 12, design: .monospaced).weight(.medium))
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                    .tint(recording ? Color.accentColor : nil)
                }
            }

            if recording, let hint {
                Label(hint, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11.5)).foregroundStyle(Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onChange(of: store.recordingID) { _, new in
            hint = nil
            if new == id { startMonitor() } else { stopMonitor() }
        }
        .onDisappear {
            stopMonitor()
            if store.recordingID == id { store.recordingID = nil }
        }
    }

    private func startMonitor() {
        stopMonitor()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            handle(e)
            return nil
        }
    }

    private func stopMonitor() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }

    private func handle(_ e: NSEvent) {
        let flags = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if e.keyCode == 53, flags.isEmpty {
            store.recordingID = nil
            return
        }
        guard let s = AppShortcut.from(e) else {
            hint = "这个键不能用作快捷键"
            return
        }
        if let why = store.problem(s, for: id) {
            hint = why
            return
        }
        store.set(id, s)
        store.recordingID = nil
    }
}
