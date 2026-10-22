// 生成 AppIcon.icns：图形取自安卓端 ic_launcher_foreground.xml（108×108 视口），白底，套 macOS 图标模板
// 用法：见 build.sh（只在 Resources/AppIcon.icns 不存在时调用）
import AppKit

let size: CGFloat = 1024

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func render() -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    // 图标主体：824 圆角方块，居中，带投影
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.28).cgColor)
    color(0xFFFFFF).setFill()
    bodyPath.fill()
    ctx.restoreGState()

    // 轻微的纸面渐变
    ctx.saveGState()
    bodyPath.addClip()
    let g = NSGradient(colors: [color(0xFFFFFF), color(0xF6F1EA)])!
    g.draw(in: body, angle: -90)
    ctx.restoreGState()

    // 把 108 视口映射到画布：缩放 s，内容中心 (53,53) 对齐画布中心
    let s: CGFloat = 10.2
    func pt(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: 512 + (x - 54) * s, y: 512 - (y - 54) * s) }
    func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
        NSRect(x: pt(x, y + h).x, y: pt(x, y + h).y, width: w * s, height: h * s)
    }

    // 轴线
    color(0xE4D9CB).setFill()
    NSBezierPath(rect: rect(33.5, 40.5, 3, 7.5)).fill()
    NSBezierPath(rect: rect(33.5, 60, 3, 8.5)).fill()

    // 圆（黄）
    color(0xF4B63F).setFill()
    NSBezierPath(ovalIn: rect(28.5, 27.5, 13, 13)).fill()

    // 空心圆角方块（橙）
    color(0xEE7C3E).setFill()
    NSBezierPath(roundedRect: rect(29, 48, 12, 12), xRadius: 3 * s, yRadius: 3 * s).fill()
    NSGraphicsContext.current!.compositingOperation = .clear
    NSBezierPath(roundedRect: rect(32, 51, 6, 6), xRadius: 1 * s, yRadius: 1 * s).fill()
    NSGraphicsContext.current!.compositingOperation = .sourceOver
    // 挖空处补回纸面色
    color(0xFAF7F2).setFill()
    NSBezierPath(roundedRect: rect(32, 51, 6, 6), xRadius: 1 * s, yRadius: 1 * s).fill()

    // 三角（焦糖棕）
    color(0xA8612F).setFill()
    let tri = NSBezierPath()
    tri.move(to: pt(35, 68.5)); tri.line(to: pt(41, 79)); tri.line(to: pt(29, 79)); tri.close()
    tri.fill()

    // 内容行（胶囊）：由长到短，由深到淡
    func pill(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ c: UInt32) {
        color(c).setFill()
        NSBezierPath(roundedRect: rect(x, y, w, 6), xRadius: 3 * s, yRadius: 3 * s).fill()
    }
    pill(50, 31, 27, 0x2A2118)
    pill(50, 51, 19, 0x7A6A5C)
    pill(50, 71, 11, 0xB9AB9C)

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let rep = render()
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png"
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
