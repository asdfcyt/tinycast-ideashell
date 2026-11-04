import AppKit

/// 选文件夹：统一的入口。
/// - 允许在对话框里「新建文件夹」（NSOpenPanel 默认不允许）；
/// - 从菜单项里点出来时，菜单还没收完就弹模态框，偶尔会没反应：等菜单收起来的下一拍再弹。
@MainActor
enum FolderPicker {
    /// 正在选：悬浮输入窗据此不要因为失焦而收起
    private(set) static var active = false

    static func pick(title: String, start: String? = nil, completion: @escaping (String?) -> Void) {
        active = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            let p = NSOpenPanel()
            p.title = title
            p.prompt = "选择"
            p.canChooseFiles = false
            p.canChooseDirectories = true
            p.canCreateDirectories = true
            p.allowsMultipleSelection = false
            if let s = start, !s.isEmpty { p.directoryURL = URL(fileURLWithPath: s) }
            if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
            NSApp.activate(ignoringOtherApps: true)
            let ok = p.runModal() == .OK
            active = false
            completion(ok ? p.url?.path : nil)
        }
    }
}
