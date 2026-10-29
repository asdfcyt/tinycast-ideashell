import AppKit
import SwiftUI

/// 屏幕顶部的菜单栏（拾忆 / 文件 / 编辑 / 显示 / 语音 / 窗口 / 帮助）：按 macOS 的惯例放常用操作和快捷键
struct AppCommands: Commands {
    @ObservedObject var model: AppModel
    @ObservedObject private var voice = VoiceController.shared
    @ObservedObject private var keys = AppShortcutStore.shared
    @ObservedObject private var shelf = StickyShelf.shared

    private var sections: [AppSection] { AppSection.allCases.filter { $0 != .settings } }

    var body: some Commands {
        // 拾忆菜单：设置…
        CommandGroup(replacing: .appSettings) {
            Button("设置…") { SettingsWindow.show() }
                .appShortcut(keys.shortcut(.settings))
        }

        // 文件：新建 / 刷新
        CommandGroup(replacing: .newItem) {
            Button("万能输入…") {
                MainWindow.show()
                model.openQuickAddHere()
            }
            .appShortcut(keys.shortcut(.quickAdd))
            Divider()
            Button("记笔记…") { MainWindow.show(); model.openQuickAdd(kind: .note) }
                .appShortcut(keys.shortcut(.note))
            Button("记待办…") { MainWindow.show(); model.openQuickAdd(kind: .todo) }
                .appShortcut(keys.shortcut(.todo))
            Button("记日记…") { MainWindow.show(); model.openQuickAdd(kind: .daily) }
                .appShortcut(keys.shortcut(.daily))
            Divider()
            Button("新建便签") { StickyController.shared.create() }
            Button("显示全部便签") { StickyController.shared.bringAllToFront() }
            Menu("已关闭的便签") {
                ForEach(shelf.closed.prefix(15)) { n in
                    Button(StickyShelf.preview(n)) { StickyController.shared.reopen(n.id) }
                }
                Divider()
                Button("清空已关闭的便签") { StickyController.shared.clearClosed() }
            }
            .disabled(shelf.closed.isEmpty)
            Divider()
            Button("语音输入") { voice.toggleFromMenu() }
                .disabled(voice.phase == .organizing)
            Divider()
            Button("刷新") { Task { await model.refreshAll() } }
                .appShortcut(keys.shortcut(.refresh))
        }

        // 显示：切换页面
        CommandGroup(before: .sidebar) {
            ForEach(sections) { s in
                Button(s.title) {
                    MainWindow.show()
                    model.section = s
                }
                .appShortcut(AppShortcutID.page(s).map { keys.shortcut($0) } ?? AppShortcut(key: "", mods: 0))
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
                .appShortcut(keys.shortcut(.mainWindow))
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
