import AppKit
import SwiftUI

/// 多行输入框（代替 SwiftUI 的 TextEditor）。为的是：
/// 1. 焦点可靠：窗口一出现就把自己设成第一响应者，悬浮窗里也不用再点一下；
/// 2. 输入法友好：拼音 / 联想还没上屏的候选文字也会同步给 `text`，外面的占位提示在有候选文字时就会消失。
struct ComposerTextView: NSViewRepresentable {
    @Environment(\.colorScheme) private var colorScheme
    @Binding var text: String
    var fontSize: CGFloat = 16
    /// 每次值变化就把焦点抢回输入框（点了示例 / 提交完继续写）
    var focusTick = 0
    /// 回车提交（Shift / Option + 回车换行）；输入法候选状态下的回车仍是上屏，不会触发
    var onSubmit: (() -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let tv = ComposerNSTextView()
        tv.delegate = context.coordinator
        tv.onTextChange = { [weak coordinator = context.coordinator, weak tv] in
            guard let coordinator, let tv else { return }
            coordinator.sync(from: tv)
        }
        tv.font = .systemFont(ofSize: fontSize)
        tv.textColor = .labelColor
        tv.drawsBackground = false
        tv.isRichText = false
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
        tv.string = text

        let sv = NSScrollView()
        sv.drawsBackground = false
        sv.hasVerticalScroller = true
        sv.autohidesScrollers = true
        sv.scrollerStyle = .overlay
        sv.borderType = .noBorder
        sv.documentView = tv
        context.coordinator.focusTick = focusTick
        return sv
    }

    func updateNSView(_ sv: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = sv.documentView as? ComposerNSTextView else { return }
        if tv.string != text, !tv.hasMarkedText() {
            tv.string = text
            tv.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
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
        init(_ parent: ComposerTextView) { self.parent = parent }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)), let submit = parent.onSubmit else { return false }
            let flags = NSApp.currentEvent?.modifierFlags ?? []
            if flags.contains(.shift) || flags.contains(.option) { return false }
            submit()
            return true
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            sync(from: tv)
        }

        func sync(from tv: NSTextView) {
            if parent.text != tv.string { parent.text = tv.string }
        }
    }
}

/// 窗口刚出现时抢焦点
final class ComposerNSTextView: NSTextView {
    /// 文字变了（包括输入法还没上屏的候选文字：这时系统不一定会发 textDidChange，自己补）
    var onTextChange: (() -> Void)?

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        onTextChange?()
    }

    override func unmarkText() {
        super.unmarkText()
        onTextChange?()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        // 窗口刚出现时第一响应者还没定：下一轮再设，设了之后窗口一变成 key 就能直接打字
        DispatchQueue.main.async { [weak self] in
            guard let self, let w = self.window else { return }
            w.makeFirstResponder(self)
        }
    }
}
