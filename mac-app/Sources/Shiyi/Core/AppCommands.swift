import AppKit
import SwiftUI

/// 屏幕顶部的菜单栏（拾忆 / 文件 / 编辑 / 显示 / 语音 / 窗口 / 帮助）：按 macOS 的惯例放常用操作和快捷键
struct AppCommands: Commands {
    @ObservedObject var model: AppModel
    @ObservedObject private var voice = VoiceController.shared

    private var sections: [AppSection] { AppSection.allCases.filter { $0 != .settings } }

    var body: some Commands {
        // 拾忆菜单：设置…
        CommandGroup(replacing: .appSettings) {
            Button("设置…") { SettingsWindow.show() }
                .keyboardShortcut(",", modifiers: .command)
        }

        // 文件：新建 / 刷新
        CommandGroup(replacing: .newItem) {
            Button("万能输入…") {
                MainWindow.show()
                model.openQuickAddHere()
            }
            .keyboardShortcut("n", modifiers: .command)
            Divider()
            Button("记笔记…") { MainWindow.show(); model.openQuickAdd(kind: .note) }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("记待办…") { MainWindow.show(); model.openQuickAdd(kind: .todo) }
                .keyboardShortcut("t", modifiers: [.command, .shift])
            Button("记日记…") { MainWindow.show(); model.openQuickAdd(kind: .daily) }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            Divider()
            Button("语音输入") { voice.toggleFromMenu() }
                .disabled(voice.phase == .organizing)
            Divider()
            Button("刷新") { Task { await model.refreshAll() } }
                .keyboardShortcut("r", modifiers: .command)
        }

        // 显示：切换页面
        CommandGroup(before: .sidebar) {
            ForEach(Array(sections.enumerated()), id: \.element) { i, s in
                Button(s.title) {
                    MainWindow.show()
                    model.section = s
                }
                .keyboardShortcut(KeyEquivalent(Character(String(i + 1))), modifiers: .command)
            }
            Divider()
        }

        // 语音
        CommandMenu("语音") {
            Button(voice.menuTitle) { voice.toggleFromMenu() }
                .disabled(voice.phase == .organizing)
            Button("说话修改") { voice.refineByVoice() }
                .disabled(voice.phase != .preview)
            Button("取消当前语音输入") { voice.cancel() }
                .disabled(voice.phase == .idle)
            Divider()
            Button("识别历史…") {
                SettingsNav.shared.showVoiceHistory = true
                SettingsWindow.show(.voice)
            }
            Button("语音输入设置…") { SettingsWindow.show(.voice) }
            Button("猛犸麦克风按键…") { MicWindow.show() }
        }

        // 窗口
        CommandGroup(after: .windowArrangement) {
            Button("拾忆") { MainWindow.show() }
                .keyboardShortcut("0", modifiers: .command)
            Button("设置") { SettingsWindow.show() }
        }

        // 帮助
        CommandGroup(replacing: .help) {
            Button("语音输入设置与说明") { SettingsWindow.show(.voice) }
            Button("账号与 API 设置") { SettingsWindow.show(.account) }
            Divider()
            Button("在 Finder 中显示本机数据") { NSWorkspace.shared.activateFileViewerSelecting([LocalStore.dir]) }
        }
    }
}
