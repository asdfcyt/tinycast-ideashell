import AppKit

/*
 * 便签里的图片：结审证据 / 法规的正文里，图片是一行引用 `![截图 1][img1]`。
 * 光标不在这一行时，把这行文字折叠掉，在原位置直接画出图片；光标进入这一行（或点一下图片）就展开成原文。
 * 文字本身一个字都没改，保存 / 写回拿到的还是原来的引用。
 */

/// 一张渲染好的图片：line 是引用行的范围（不含换行）
struct LiveImage {
    var line: NSRange
    var image: NSImage
    var size: NSSize
}

extension ComposerNSTextView {
    static let imageLine = try! NSRegularExpression(pattern: "^[ \\t]*!\\[[^\\]]*\\]\\[(img\\d+)\\][ \\t]*$", options: [])
    /// 图片下面留的空隙
    static let imageGap: CGFloat = 8
    private static let imageMaxHeight: CGFloat = 280

    /// 这行是不是图片引用：是就返回 imgN
    func imageKey(of text: String) -> String? {
        let ns = text as NSString
        guard let m = Self.imageLine.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return ns.substring(with: m.range(at: 1))
    }

    /// 图片在便签里的显示尺寸：不超过一行的宽度，也不会太高
    func imageDisplaySize(_ img: NSImage) -> NSSize {
        let w0 = max((textContainer?.size.width ?? 300) - 2, 60)
        let s = img.size
        guard s.width > 0, s.height > 0 else { return NSSize(width: 40, height: 40) }
        let k = min(1, w0 / s.width, Self.imageMaxHeight / s.height)
        return NSSize(width: (s.width * k).rounded(), height: (s.height * k).rounded())
    }

    /// 外面给的图片变了就重新上样式（按 key + 对象身份比，不比像素）
    @discardableResult
    func setLineImages(_ new: [String: NSImage]) -> Bool {
        let same = new.count == lineImages.count && new.allSatisfy { lineImages[$0.key] === $0.value }
        guard !same else { return false }
        lineImages = new
        if markdownStyle { restyle() }
        return true
    }

    private func imageOrigin(_ li: LiveImage) -> NSPoint? {
        guard let lm = layoutManager, li.line.location < (string as NSString).length else { return nil }
        let g = lm.glyphIndexForCharacter(at: li.line.location)
        let r = lm.lineFragmentRect(forGlyphAt: g, effectiveRange: nil)
        let o = textContainerOrigin
        return NSPoint(x: o.x + r.minX, y: o.y + r.minY)
    }

    func drawLiveImages(_ dirty: NSRect) {
        guard markdownStyle, !liveImages.isEmpty else { return }
        for li in liveImages {
            guard let o = imageOrigin(li) else { continue }
            let rect = NSRect(x: o.x, y: o.y, width: li.size.width, height: li.size.height)
            guard rect.intersects(dirty) else { continue }
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).addClip()
            li.image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
            NSGraphicsContext.restoreGraphicsState()
            NSColor.black.withAlphaComponent(0.12).setStroke()
            let edge = NSBezierPath(roundedRect: rect.insetBy(dx: 0.25, dy: 0.25), xRadius: 6, yRadius: 6)
            edge.lineWidth = 0.5
            edge.stroke()
        }
    }

    /// 点在渲染好的图片上：光标放到这行末尾（图片随即展开成引用文字）。返回是否处理了
    func expandImageIfClicked(_ event: NSEvent) -> Bool {
        guard markdownStyle, !liveImages.isEmpty, !hasMarkedText() else { return false }
        let p = convert(event.locationInWindow, from: nil)
        for li in liveImages {
            guard let o = imageOrigin(li) else { continue }
            let rect = NSRect(x: o.x, y: o.y, width: li.size.width, height: li.size.height)
            guard rect.contains(p) else { continue }
            window?.makeFirstResponder(self)
            setSelectedRange(NSRange(location: li.line.location + li.line.length, length: 0))
            return true
        }
        return false
    }
}
