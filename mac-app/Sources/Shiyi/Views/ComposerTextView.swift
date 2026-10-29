import AppKit
import SwiftUI

/// 输入框里插入的一张图（保存到结审时按它在文字里的位置混排）
struct ComposerImage: Equatable, Identifiable, Sendable {
    let id = UUID()
    var name: String
    var data: Data

    /// 只比 id：每次敲字都要比较，不能逐字节比图片数据
    static func == (l: ComposerImage, r: ComposerImage) -> Bool { l.id == r.id }

    /// 文字里每张图占一个 U+FFFC（对象替换字符），第 n 个对应 images[n]
    static let marker = "\u{FFFC}"
    static func stripMarker(_ s: String) -> String { s.replacingOccurrences(of: marker, with: "") }
}

/// 输入框里的图片附件：缩略图显示，原图数据在 `payload` 里
final class ComposerAttachment: NSTextAttachment {
    var payload = ComposerImage(name: "", data: Data())
}

/// 多行输入框（代替 SwiftUI 的 TextEditor）。为的是：
/// 1. 焦点可靠：窗口一出现就把自己设成第一响应者，悬浮窗里也不用再点一下；
/// 2. 输入法友好：拼音 / 联想还没上屏的候选文字也会同步给 `text`，外面的占位提示在有候选文字时就会消失；
/// 3. 图文混排（`allowsImages`）：粘贴 / 拖入图片会在光标处插入缩略图，`text` 里对应一个 U+FFFC，`images` 按顺序给出原图。
struct ComposerTextView: NSViewRepresentable {
    @Environment(\.colorScheme) private var colorScheme
    @Binding var text: String
    /// 输入框里当前的图片（和 text 里的 U+FFFC 一一对应）
    var images: Binding<[ComposerImage]>?
    /// 内容实际排出来的高度（含图片缩略图）：外面按它定输入框高度，不再估算
    var contentHeight: Binding<CGFloat>?
    var allowsImages = false
    /// Markdown 边写边预览（便签用）：标题 / 粗体 / 列表等当场上样式，点方框勾选，回车续列表
    var markdown = false
    var fontSize: CGFloat = 16
    /// 窗口一出现就抢焦点（一个页面里有好几个输入框时关掉）
    var autoFocus = true
    /// 每次值变化就把焦点抢回输入框（点了示例 / 提交完继续写）
    var focusTick = 0
    /// 回车提交（Shift / Option + 回车换行）；输入法候选状态下的回车仍是上屏，不会触发
    var onSubmit: (() -> Void)?
    /// Tab / Shift+Tab（参数是否反向）：设置后不再往文字里插制表符，交给外面切换类型；输入法候选状态下不触发
    var onTab: ((Bool) -> Void)?
    /// 输入框为空时按删除键：返回 true 表示外面处理了（比如退出 Tab 选的类型），不再往下走
    var onBackspaceEmpty: (() -> Bool)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        // 明确用 TextKit 1：读 layoutManager 会让 TextKit 2 的文本框中途降级，正在输入的五笔 / 拼音候选会被提前上屏（打出「i测试」）
        let tv = ComposerNSTextView(usingTextLayoutManager: false)
        tv.delegate = context.coordinator
        tv.onTextChange = { [weak coordinator = context.coordinator, weak tv] in
            guard let coordinator, let tv else { return }
            coordinator.sync(from: tv)
        }
        tv.baseFont = .systemFont(ofSize: fontSize)
        tv.font = tv.baseFont
        tv.textColor = .labelColor
        tv.drawsBackground = false
        // 开启图文混排才用富文本（附件需要）；粘贴一律按纯文字处理，不会带进字体颜色
        tv.allowsImages = allowsImages
        tv.markdownStyle = markdown
        tv.grabsFocus = autoFocus
        tv.isRichText = allowsImages || markdown
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isAutomaticLinkDetectionEnabled = false
        tv.textContainerInset = NSSize(width: 0, height: 2)
        tv.textContainer?.lineFragmentPadding = 0
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
        tv.registerForDraggedTypes([.fileURL, .tiff, .png, .string])
        tv.string = text
        tv.applyBaseStyle()

        let sv = NSScrollView()
        sv.drawsBackground = false
        sv.hasVerticalScroller = true
        sv.autohidesScrollers = true
        sv.scrollerStyle = .overlay
        sv.borderType = .noBorder
        sv.documentView = tv
        context.coordinator.focusTick = focusTick
        // 一出来、以及宽度变了（换行位置变了）就量一次内容高度：外面按它定框高，不然已有内容的输入框只显示头两行
        if contentHeight != nil {
            sv.postsFrameChangedNotifications = true
            context.coordinator.frameObserver = NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification, object: sv, queue: .main
            ) { [weak coordinator = context.coordinator, weak tv] _ in
                MainActor.assumeIsolated {
                    guard let coordinator, let tv else { return }
                    coordinator.sync(from: tv)
                }
            }
            DispatchQueue.main.async { [weak coordinator = context.coordinator, weak tv] in
                guard let coordinator, let tv else { return }
                coordinator.sync(from: tv)
            }
        }
        return sv
    }

    func updateNSView(_ sv: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = sv.documentView as? ComposerNSTextView else { return }
        if tv.allowsImages != allowsImages {
            tv.allowsImages = allowsImages
            tv.isRichText = allowsImages || markdown
        }
        if tv.string != text, !tv.hasMarkedText() {
            tv.string = text
            tv.applyBaseStyle()
            tv.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            // 外部直接改了文字（清空 / 点示例）：图片列表跟着重算，别在视图更新里改状态
            DispatchQueue.main.async { [weak coordinator = context.coordinator, weak tv] in
                guard let coordinator, let tv else { return }
                coordinator.sync(from: tv)
            }
        }
        let want = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
        if tv.appearance?.name != want?.name { tv.appearance = want }
        if context.coordinator.focusTick != focusTick {
            context.coordinator.focusTick = focusTick
            DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextView
        var focusTick = 0
        var frameObserver: NSObjectProtocol?
        deinit { if let o = frameObserver { NotificationCenter.default.removeObserver(o) } }
        init(_ parent: ComposerTextView) { self.parent = parent }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if let tab = parent.onTab {
                if selector == #selector(NSResponder.insertTab(_:)) { tab(false); return true }
                if selector == #selector(NSResponder.insertBacktab(_:)) { tab(true); return true }
            }
            if selector == #selector(NSResponder.deleteBackward(_:)), let back = parent.onBackspaceEmpty,
               textView.string.isEmpty, !textView.hasMarkedText(), back() { return true }
            if selector == #selector(NSResponder.insertNewline(_:)), parent.markdown,
               let tv = textView as? ComposerNSTextView, tv.continueList() { return true }
            guard selector == #selector(NSResponder.insertNewline(_:)), let submit = parent.onSubmit else { return false }
            let flags = NSApp.currentEvent?.modifierFlags ?? []
            if flags.contains(.shift) || flags.contains(.option) { return false }
            submit()
            return true
        }

        /// 光标挪到别的行：便签里这一行的 Markdown 符号显示出来，原来那行隐藏
        func textViewDidChangeSelection(_ notification: Notification) {
            guard let tv = notification.object as? ComposerNSTextView, tv.markdownStyle else { return }
            tv.restyle()
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            sync(from: tv)
        }

        func sync(from tv: NSTextView) {
            if let c = tv as? ComposerNSTextView, c.markdownStyle { c.restyle() }
            if parent.text != tv.string { parent.text = tv.string }
            if let h = parent.contentHeight {
                DispatchQueue.main.async { [weak tv] in
                    guard let tv, let lm = tv.layoutManager, let tc = tv.textContainer else { return }
                    lm.ensureLayout(for: tc)
                    let v = ceil(lm.usedRect(for: tc).height + tv.textContainerInset.height * 2)
                    if abs(h.wrappedValue - v) > 0.5 { h.wrappedValue = v }
                }
            }
            guard let binding = parent.images, let storage = tv.textStorage else { return }
            var out: [ComposerImage] = []
            storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { v, _, _ in
                if let a = v as? ComposerAttachment { out.append(a.payload) }
            }
            if out != binding.wrappedValue { binding.wrappedValue = out }
        }
    }
}

/// 窗口刚出现时抢焦点；支持粘贴 / 拖入图片
final class ComposerNSTextView: NSTextView {
    /// 文字变了（包括输入法还没上屏的候选文字：这时系统不一定会发 textDidChange，自己补）
    var onTextChange: (() -> Void)?
    var allowsImages = false
    /// 便签：Markdown 边写边预览（样式见 MarkdownLiveStyle.swift）
    var markdownStyle = false
    var grabsFocus = true
    var baseFont: NSFont = .systemFont(ofSize: 16)

    static let maxImages = 9
    static let thumbMax = NSSize(width: 360, height: 160)

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        onTextChange?()
    }

    override func unmarkText() {
        super.unmarkText()
        onTextChange?()
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok, markdownStyle { restyle() }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok, markdownStyle { DispatchQueue.main.async { [weak self] in self?.restyle() } }
        return ok
    }

    override func mouseDown(with event: NSEvent) {
        if toggleTaskIfClicked(event) { return }
        super.mouseDown(with: event)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, grabsFocus else { return }
        // 窗口刚出现时第一响应者还没定：下一轮再设，设了之后窗口一变成 key 就能直接打字
        DispatchQueue.main.async { [weak self] in
            guard let self, let w = self.window else { return }
            w.makeFirstResponder(self)
        }
    }

    /// 整段文字回到基础字体 / 颜色（富文本模式下 `string =` 之后属性会丢）
    func applyBaseStyle() {
        if markdownStyle { restyle(); return }
        let attrs: [NSAttributedString.Key: Any] = [.font: baseFont, .foregroundColor: NSColor.labelColor]
        if let ts = textStorage, ts.length > 0 { ts.addAttributes(attrs, range: NSRange(location: 0, length: ts.length)) }
        typingAttributes = attrs
    }

    private var imageCount: Int {
        var n = 0
        textStorage?.enumerateAttribute(.attachment, in: NSRange(location: 0, length: textStorage?.length ?? 0)) { v, _, _ in
            if v is ComposerAttachment { n += 1 }
        }
        return n
    }

    // MARK: 插入图片

    private func attachmentString(_ data: Data, name: String) -> NSAttributedString? {
        guard let img = NSImage(data: data), img.size.width > 0, img.size.height > 0 else { return nil }
        let a = ComposerAttachment()
        a.payload = ComposerImage(name: name, data: data)
        a.image = img
        let scale = min(1, Self.thumbMax.width / img.size.width, Self.thumbMax.height / img.size.height)
        a.bounds = CGRect(x: 0, y: -4, width: (img.size.width * scale).rounded(), height: (img.size.height * scale).rounded())
        return NSAttributedString(attachment: a)
    }

    /// 在 [at] 处插入图片；返回是否插入了至少一张
    @discardableResult
    private func insertImages(_ list: [(name: String, data: Data)], at: Int? = nil) -> Bool {
        guard allowsImages, !list.isEmpty else { return false }
        var room = Self.maxImages - imageCount
        guard room > 0 else { NSSound.beep(); return false }
        let imgs = NSMutableAttributedString()
        for item in list where room > 0 {
            if let s = attachmentString(item.data, name: item.name) {
                // 多张图各占一行
                if imgs.length > 0 { imgs.append(NSAttributedString(string: "\n", attributes: [.font: baseFont, .foregroundColor: NSColor.labelColor])) }
                imgs.append(s); room -= 1
            }
        }
        guard imgs.length > 0 else { return false }
        let range = at.map { NSRange(location: min($0, (string as NSString).length), length: 0) } ?? selectedRange()
        // 智能换行：图片独占一行。前面有字就先换行；后面不是换行（或已到末尾）就补一个换行，光标落在图片下面继续写
        let ns = string as NSString
        let nl = NSAttributedString(string: "\n", attributes: [.font: baseFont, .foregroundColor: NSColor.labelColor])
        let out = NSMutableAttributedString()
        if range.location > 0, ns.character(at: range.location - 1) != 10 { out.append(nl) }
        out.append(imgs)
        let end = range.location + range.length
        if end >= ns.length || ns.character(at: end) != 10 { out.append(nl) }
        // 直接改 textStorage（insertText 对附件不稳）；shouldChangeText / didChangeText 保证撤销和代理回调
        guard let storage = textStorage, shouldChangeText(in: range, replacementString: out.string) else { return false }
        storage.replaceCharacters(in: range, with: out)
        didChangeText()
        setSelectedRange(NSRange(location: range.location + out.length, length: 0))
        typingAttributes = [.font: baseFont, .foregroundColor: NSColor.labelColor]
        onTextChange?()
        return true
    }

    private static func images(from pb: NSPasteboard) -> [(name: String, data: Data)] {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = f.string(from: Date())
        var out: [(String, Data)] = []
        // 复制的图片文件（访达里 ⌘C）
        let opts: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true, .urlReadingContentsConformToTypes: ["public.image"]]
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: opts) as? [URL] {
            for u in urls { if let d = try? Data(contentsOf: u) { out.append((u.lastPathComponent, d)) } }
        }
        if out.isEmpty {
            // 截图到剪贴板 / 从网页复制图片
            if let png = pb.data(forType: .png) { out.append(("图片-\(stamp).png", png)) }
            else if let tiff = pb.data(forType: .tiff), let rep = NSBitmapImageRep(data: tiff),
                    let png = rep.representation(using: .png, properties: [:]) { out.append(("图片-\(stamp).png", png)) }
        }
        return out
    }

    /// 只判断有没有图（拖动过程中会反复调用，不读文件内容）
    private static func hasImage(_ pb: NSPasteboard) -> Bool {
        let opts: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true, .urlReadingContentsConformToTypes: ["public.image"]]
        if pb.canReadObject(forClasses: [NSURL.self], options: opts) { return true }
        return pb.data(forType: .png) != nil || pb.data(forType: .tiff) != nil
    }

    /// 从网页 / 文档里复制的图文（带 html / rtf）：以文字为准。访达复制文件、截图工具复制图片这类
    /// （只有图片，或图片 + 文件名之类的纯文本）一律当图片。
    private static func isRichTextCopy(_ pb: NSPasteboard) -> Bool {
        guard pb.string(forType: .string)?.isEmpty == false else { return false }
        let types = pb.types ?? []
        return types.contains(.html) || types.contains(.rtf)
    }

    // MARK: 粘贴 / 拖放

    override func paste(_ sender: Any?) {
        let pb = NSPasteboard.general
        if allowsImages {
            let imgs = Self.images(from: pb)
            // 同时有文字和图片（例如从网页 / 文档里复制一段图文）：以文字为准，只有纯图片才插图
            if !imgs.isEmpty, !Self.isRichTextCopy(pb) {
                insertImages(imgs)
                return
            }
        }
        pasteAsPlainText(sender)
    }

    /// 悬浮输入窗不激活应用，菜单里的 ⌘V 不一定能到这里：自己接一下
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, handleMarkdownShortcut(event) { return true }
        if allowsImages, window?.firstResponder === self, event.type == .keyDown,
           event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "v" {
            paste(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func pasteAsPlainText(_ sender: Any?) {
        guard let s = NSPasteboard.general.string(forType: .string) else { return }
        insertText(ComposerImage.stripMarker(s), replacementRange: selectedRange())
        onTextChange?()
    }

    override func pasteAsRichText(_ sender: Any?) { pasteAsPlainText(sender) }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if allowsImages, Self.hasImage(sender.draggingPasteboard) { return .copy }
        return super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if allowsImages, Self.hasImage(sender.draggingPasteboard) { return .copy }
        return super.draggingUpdated(sender)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if allowsImages, Self.hasImage(sender.draggingPasteboard) { return true }
        return super.prepareForDragOperation(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        if allowsImages {
            let imgs = Self.images(from: pb)
            if !imgs.isEmpty {
                let p = convert(sender.draggingLocation, from: nil)
                let at = characterIndexForInsertion(at: p)
                return insertImages(imgs, at: at == NSNotFound ? nil : at)
            }
        }
        // 其他文件拖进来不处理（默认会插一个文件图标附件）；纯文字走默认
        if pb.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) { return false }
        if let s = pb.string(forType: .string) {
            let p = convert(sender.draggingLocation, from: nil)
            let at = characterIndexForInsertion(at: p)
            insertText(ComposerImage.stripMarker(s), replacementRange: NSRange(location: at == NSNotFound ? selectedRange().location : at, length: 0))
            onTextChange?()
            return true
        }
        return false
    }
}
