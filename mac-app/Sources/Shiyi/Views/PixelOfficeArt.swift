import AppKit
import ImageIO
import SwiftUI

// 像素办公室的画面：背景、家具、猫咪动画都来自 Star-Office-UI（美术仅限学习 / 演示 / 非商用，见 Resources/Office/NOTICE.txt）。
// 坐标一律用原作的 1280×720 画布，画的时候再整体缩放。
// 每个 Agent 是一只猫：有活就坐到自己的工位上敲键盘；等你拍板，猫头上冒问号；空闲在沙发里打盹；没跑成，去右上角的机房冒问号 / 响警报。

// MARK: - 素材

enum OfficeAssets {
    static var dir: URL? = Bundle.main.resourceURL?.appendingPathComponent("Office")
    private static var images: [String: CGImage] = [:]
    private static var frames: [String: CGImage] = [:]
    private static var fontReady = false

    static func image(_ name: String) -> CGImage? {
        if let c = images[name] { return c }
        guard let url = dir?.appendingPathComponent(name),
              let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        images[name] = img
        return img
    }

    /// 精灵表里的一帧
    static func frame(_ name: String, cellW: Int, cellH: Int, cols: Int, index: Int) -> CGImage? {
        let key = "\(name)#\(index)"
        if let c = frames[key] { return c }
        guard let sheet = image(name) else { return nil }
        let rect = CGRect(x: (index % cols) * cellW, y: (index / cols) * cellH, width: cellW, height: cellH)
        guard let f = sheet.cropping(to: rect) else { return nil }
        frames[key] = f
        return f
    }

    private static var tintedCache: [String: CGImage] = [:]

    /// 精灵表里的一帧，按猫的品种换毛色（橘猫就是原图）
    static func frame(_ name: String, cellW: Int, cellH: Int, cols: Int, index: Int, breed: OfficeBreed) -> CGImage? {
        guard let f = frame(name, cellW: cellW, cellH: cellH, cols: cols, index: index) else { return nil }
        if breed.original { return f }
        let key = "\(name)#\(index)@\(breed.name)"
        if let c = tintedCache[key] { return c }
        let out = recolor(f, breed) ?? f
        tintedCache[key] = out
        return out
    }

    /// 只改「橘色毛」的像素：色相在橘黄一带、够鲜、够亮；红色龙虾钳、褐色椅子、白肚皮都不动
    private static func recolor(_ src: CGImage, _ b: OfficeBreed) -> CGImage? {
        let w = src.width, h = src.height
        let cs = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let drew: Bool = px.withUnsafeMutableBytes { buf in
            guard let c = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: cs, bitmapInfo: info) else { return false }
            c.draw(src, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drew else { return nil }
        for i in 0..<(w * h) {
            let o = i * 4
            let a = Double(px[o + 3])
            if a < 1 { continue }
            let r = min(1, Double(px[o]) / a), g = min(1, Double(px[o + 1]) / a), bl = min(1, Double(px[o + 2]) / a)
            let mx = max(r, g, bl), mn = min(r, g, bl)
            let d = mx - mn
            guard mx > 0.62, d > 0.01 else { continue }
            let sat = d / mx
            guard sat > 0.45 else { continue }
            var hue: Double
            if mx == r { hue = 60 * ((g - bl) / d) } else if mx == g { hue = 60 * ((bl - r) / d + 2) } else { hue = 60 * ((r - g) / d + 4) }
            if hue < 0 { hue += 360 }
            guard hue >= 6, hue <= 56 else { continue }
            let nh = b.hue ?? hue
            let ns = min(1, sat * b.sat)
            let nv = min(1, max(0, mx * b.mul + b.add))
            // HSV → RGB
            let c = nv * ns
            let hp = nh / 60
            let x = c * (1 - abs(hp.truncatingRemainder(dividingBy: 2) - 1))
            var (nr, ng, nb) = (0.0, 0.0, 0.0)
            switch Int(hp) % 6 {
            case 0: (nr, ng, nb) = (c, x, 0)
            case 1: (nr, ng, nb) = (x, c, 0)
            case 2: (nr, ng, nb) = (0, c, x)
            case 3: (nr, ng, nb) = (0, x, c)
            case 4: (nr, ng, nb) = (x, 0, c)
            default: (nr, ng, nb) = (c, 0, x)
            }
            let m = nv - c
            px[o] = UInt8(min(255, (nr + m) * a))
            px[o + 1] = UInt8(min(255, (ng + m) * a))
            px[o + 2] = UInt8(min(255, (nb + m) * a))
        }
        return px.withUnsafeMutableBytes { buf in
            guard let c = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: cs, bitmapInfo: info) else { return nil }
            return c.makeImage()
        }
    }

    static func registerFont() {
        if fontReady { return }
        fontReady = true
        if let url = dir?.appendingPathComponent("ArkPixel.ttf") {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    static func pixelFont(_ size: CGFloat) -> Font {
        registerFont()
        return Font.custom("Ark-Pixel-12px-P-zh_cn-Regular", size: size)
    }
}

/// 猫的品种：动作都是同一只猫，只是毛色不同，用来区分 Agent
struct OfficeBreed {
    let name: String
    let hue: Double?
    let sat: Double
    let mul: Double
    let add: Double
    let motto: String

    var original: Bool { hue == nil && sat == 1 && mul == 1 && add == 0 }

    static let all: [OfficeBreed] = [
        OfficeBreed(name: "橘猫", hue: nil, sat: 1, mul: 1, add: 0, motto: "干饭干饭"),
        OfficeBreed(name: "黑猫", hue: nil, sat: 0.25, mul: 0.28, add: 0.02, motto: "我在暗中观察"),
        OfficeBreed(name: "白猫", hue: nil, sat: 0.08, mul: 0.35, add: 0.62, motto: "别弄脏我的毛"),
        OfficeBreed(name: "蓝灰猫", hue: nil, sat: 0.08, mul: 0.55, add: 0.1, motto: "稳如老猫"),
        OfficeBreed(name: "暹罗猫", hue: nil, sat: 0.25, mul: 0.55, add: 0.4, motto: "朕的活呢"),
        OfficeBreed(name: "巧克力猫", hue: 20, sat: 0.9, mul: 0.45, add: 0, motto: "想吃点心.."),
        OfficeBreed(name: "狸花猫", hue: 36, sat: 0.5, mul: 0.65, add: 0, motto: "巡逻中"),
    ]

    /// 常用 Agent 固定一个品种，其余按 id 稳定地分配
    static func of(_ id: String) -> OfficeBreed {
        let k = id.lowercased()
        if k.contains("workbuddy") { return all[0] }
        if k.contains("cursor") { return all[1] }
        if k.contains("claude") { return all[4] }
        if k.contains("opencode") { return all[3] }
        var h: UInt32 = 5381
        for u in k.unicodeScalars { h = h &* 33 &+ u.value }
        return all[Int(h % UInt32(all.count))]
    }
}

/// 一张精灵表：格子大小、列数、帧数、帧率
private struct Sheet {
    let file: String
    let w: Int
    let h: Int
    let cols: Int
    let count: Int
    let fps: Double

    func frame(_ t: Double, phase: Double = 0) -> CGImage? {
        let i = Int((t + phase) * fps) % count
        return OfficeAssets.frame(file, cellW: w, cellH: h, cols: cols, index: i)
    }

    func frame(_ t: Double, phase: Double = 0, breed: OfficeBreed) -> CGImage? {
        let i = Int((t + phase) * fps) % count
        return OfficeAssets.frame(file, cellW: w, cellH: h, cols: cols, index: i, breed: breed)
    }

    static let working = Sheet(file: "star-working-spritesheet-grid.webp", w: 300, h: 300, cols: 8, count: 38, fps: 12)
    static let idle = Sheet(file: "star-idle-v5.png", w: 256, h: 256, cols: 8, count: 48, fps: 8)
    static let confused = Sheet(file: "error-bug-spritesheet-grid.webp", w: 220, h: 220, cols: 8, count: 72, fps: 10)
    static let server = Sheet(file: "serverroom-spritesheet.webp", w: 180, h: 251, cols: 40, count: 40, fps: 6)
}

// MARK: - 站位

enum OfficeLayout {
    static let W = 1280.0
    static let H = 720.0

    enum Sprite { case work, ask, idle, alarm }

    struct Spot: Equatable {
        var sprite: Sprite
        var x: Double
        var y: Double
        /// 精灵的显示边长
        var size: Double
        /// 头顶（气泡）和脚下（名牌）
        var top: Double
        var tagY: Double
        var slot: Int
    }

    /// 桌子中心：左边房间四张，右下房间两张备用
    static let desks: [(x: Double, y: Double)] = [(135, 372), (300, 372), (135, 492), (300, 492), (975, 470)]
    static let deskScale = 0.48
    static let couches: [(x: Double, y: Double)] = [(600, 345), (745, 345), (600, 465), (745, 465)]
    static let couchSize = 160.0
    static let alarms: [(x: Double, y: Double)] = [(985, 270), (1085, 270), (1180, 280), (1030, 335), (1130, 335)]
    static let alarmSize = 190.0

    static func deskSpot(_ d: Int, _ sprite: Sprite) -> Spot {
        let p = desks[d % desks.count]
        let size = 300 * deskScale * 0.95
        let cy = p.y - 95 * deskScale
        return Spot(sprite: sprite, x: p.x, y: cy, size: size, top: cy - size * 0.36, tagY: p.y + 36, slot: d % desks.count)
    }

    static func assign(_ agents: [OfficeAgent]) -> [String: Spot] {
        var out: [String: Spot] = [:]
        var idle = 0
        var alarm = 0
        for (i, a) in agents.enumerated() {
            switch a.mood {
            case .working:
                out[a.id] = deskSpot(i, .work)
            case .waiting:
                out[a.id] = deskSpot(i, .ask)
            case .idle:
                let p = couches[idle % couches.count]
                let off = Double(idle / couches.count) * 26
                out[a.id] = Spot(sprite: .idle, x: p.x + off, y: p.y, size: couchSize, top: p.y - couchSize * 0.38, tagY: p.y + couchSize * 0.42, slot: idle)
                idle += 1
            case .error:
                let p = alarms[alarm % alarms.count]
                out[a.id] = Spot(sprite: .alarm, x: p.x, y: p.y, size: alarmSize, top: p.y - alarmSize * 0.34, tagY: p.y + alarmSize * 0.36, slot: alarm)
                alarm += 1
            }
        }
        return out
    }
}

/// 每只猫当前站的位置；换了地方（开工 / 收工 / 出错）时旧的淡出、新的淡入
final class OfficeStage {
    static let shared = OfficeStage()

    struct Track {
        var cur: OfficeLayout.Spot
        var prev: OfficeLayout.Spot?
        var changed: Date
    }

    var tracks: [String: Track] = [:]

    /// 被点了一下：跳一下、说句话
    struct Poke {
        var at: Date
        var n: Int
        var line: String
    }
    var pokes: [String: Poke] = [:]

    func poke(_ a: OfficeAgent, now: Date) {
        var n = 1
        if let o = pokes[a.id], now.timeIntervalSince(o.at) < 4 { n = o.n + 1 }
        pokes[a.id] = Poke(at: now, n: n, line: OfficeStage.line(a, n: n))
    }

    /// 0…：离地的像素（0.5 秒内一个弹跳）
    func jump(_ id: String, _ now: Date) -> Double {
        guard let p = pokes[id] else { return 0 }
        let dt = now.timeIntervalSince(p.at)
        guard dt >= 0, dt < 0.5 else { return 0 }
        return 24 * abs(sin(dt / 0.5 * Double.pi))
    }

    func line(_ id: String, _ now: Date) -> String? {
        guard let p = pokes[id], now.timeIntervalSince(p.at) < 2.6 else { return nil }
        return p.line
    }

    private static func line(_ a: OfficeAgent, n: Int) -> String {
        if n >= 5 { return "别戳啦！！" }
        let breed = OfficeBreed.of(a.id)
        var pool: [String]
        switch a.mood {
        case .idle: pool = [breed.motto, "zZ.. 让我睡会", "喵～ 有活吗", "呼噜噜.."]
        case .working: pool = ["喵！在干活呢", "别戳，在忙" + (a.say.map { "：" + $0 } ?? ""), "再戳我罢工", "键盘冒烟了"]
        case .waiting: pool = ["快来拍板嘛", "等你点头呢", "喵？批一下呀"]
        case .error: pool = ["呜.. 没跑成", "别看我，bug 干的", "能重跑吗"]
        }
        return pool[Int.random(in: 0..<pool.count)]
    }

    private var last: Date?
    static let fade = 0.5

    func step(_ now: Date, spots: [String: OfficeLayout.Spot]) {
        let gap = last.map { now.timeIntervalSince($0) } ?? 99
        last = now
        let snap = gap > 1.0
        tracks = tracks.filter { spots[$0.key] != nil }
        for (id, s) in spots {
            guard var t = tracks[id] else {
                tracks[id] = Track(cur: s, prev: nil, changed: now)
                continue
            }
            if t.cur != s {
                if snap {
                    t.prev = nil
                } else {
                    t.prev = t.cur
                    t.changed = now
                }
                t.cur = s
                tracks[id] = t
            }
        }
    }

    /// 0…1：新位置现身的程度
    func progress(_ t: Track, _ now: Date) -> Double {
        guard t.prev != nil else { return 1 }
        return min(1, max(0, now.timeIntervalSince(t.changed) / Self.fade))
    }
}

// MARK: - 画

private let ink = Color(red: 0x2B / 255, green: 0x1D / 255, blue: 0x12 / 255)
private let orange = Color(red: 0xE8 / 255, green: 0x79 / 255, blue: 0x4A / 255)

private enum OfficeArt {
    static func draw(ctx: GraphicsContext, size: CGSize, now: Date, agents: [OfficeAgent], stage: OfficeStage, selected: String?, hover: String?, board: OfficeBoard) {
        // 宽高各自缩放（竖向最多比横向多拉 12%，肉眼看不出）
        let kx = Double(size.width) / OfficeLayout.W
        let ky = Double(size.height) / OfficeLayout.H
        let t = now.timeIntervalSinceReferenceDate

        func pic(_ img: CGImage?, cx: Double, cy: Double, w: Double, h: Double, alpha: Double = 1) {
            guard let img, alpha > 0.01 else { return }
            var c = ctx
            c.opacity = alpha
            let rect = CGRect(x: (cx - w / 2) * kx, y: (cy - h / 2) * ky, width: w * kx, height: h * ky)
            c.draw(Image(decorative: img, scale: 1).interpolation(.high), in: rect)
        }

        // 背景和固定摆设
        pic(OfficeAssets.image("office_bg.webp"), cx: 640, cy: 360, w: 1280, h: 720)
        pic(Sheet.server.frame(t), cx: 1021, cy: 142, w: 180, h: 251)
        pic(OfficeAssets.frame("posters-spritesheet.webp", cellW: 160, cellH: 160, cols: 4, index: 9), cx: 252, cy: 66, w: 150, h: 150)
        pic(OfficeAssets.frame("plants-spritesheet.webp", cellW: 160, cellH: 160, cols: 4, index: 2), cx: 565, cy: 178, w: 130, h: 130)
        pic(OfficeAssets.frame("plants-spritesheet.webp", cellW: 160, cellH: 160, cols: 4, index: 9), cx: 977, cy: 496, w: 130, h: 130)
        pic(OfficeAssets.frame("cats-spritesheet.webp", cellW: 160, cellH: 160, cols: 4, index: 7), cx: 60, cy: 585, w: 130, h: 130)

        // 谁在哪儿：按纵向位置排前后
        struct Item {
            var a: OfficeAgent
            var cur: OfficeLayout.Spot
            var prev: OfficeLayout.Spot?
            var p: Double
        }
        var items: [Item] = []
        for a in agents {
            guard let tr = stage.tracks[a.id] else { continue }
            items.append(Item(a: a, cur: tr.cur, prev: tr.prev, p: stage.progress(tr, now)))
        }

        var deskOwner: [Int: Item] = [:]
        for it in items where it.cur.sprite == .work || it.cur.sprite == .ask { deskOwner[it.cur.slot] = it }
        var deskPrev: [Int: Item] = [:]
        for it in items {
            if let pv = it.prev, (pv.sprite == .work || pv.sprite == .ask), it.p < 1 { deskPrev[pv.slot] = it }
        }
        let usedCouch = Set(items.filter { $0.cur.sprite == .idle }.map(\.cur.slot))

        // 沙发：空着的画空沙发，有猫的位置换成那只猫自己的猫窝
        for (i, c) in OfficeLayout.couches.enumerated() where !usedCouch.contains(i) {
            pic(OfficeAssets.image("sofa-idle-v3.png"), cx: c.x, cy: c.y, w: OfficeLayout.couchSize, h: OfficeLayout.couchSize)
        }

        func catSprite(_ s: OfficeLayout.Spot, _ phase: Double, _ b: OfficeBreed) -> CGImage? {
            switch s.sprite {
            case .work: return Sheet.working.frame(t, phase: phase, breed: b)
            case .ask, .alarm: return Sheet.confused.frame(t, phase: phase, breed: b)
            case .idle: return Sheet.idle.frame(t, phase: phase, breed: b)
            }
        }

        func drawCat(_ it: Item) {
            var hs: UInt32 = 7
            for u in it.a.id.unicodeScalars { hs = hs &* 31 &+ u.value }
            let phase = Double(hs % 7) * 0.37
            let b = OfficeBreed.of(it.a.id)
            let jump = stage.jump(it.a.id, now)
            if let pv = it.prev, it.p < 1 {
                pic(catSprite(pv, phase, b), cx: pv.x, cy: pv.y, w: pv.size, h: pv.size, alpha: 1 - it.p)
            }
            let s = it.cur
            pic(catSprite(s, phase, b), cx: s.x, cy: s.y - jump, w: s.size, h: s.size, alpha: it.p)
        }

        // 在沙发里的猫、警报区的猫
        for it in items.sorted(by: { $0.cur.y < $1.cur.y }) where it.cur.sprite == .idle || it.cur.sprite == .alarm {
            drawCat(it)
        }

        // 桌子（猫坐在桌子后面）：从上往下画
        let deskCount = max(4, min(OfficeLayout.desks.count, (agents.count + 0)))
        for d in 0..<OfficeLayout.desks.count {
            if d >= 4 && d >= deskCount { continue }
            let p = OfficeLayout.desks[d]
            if let o = deskOwner[d] { drawCat(o) }
            else if let o = deskPrev[d], let pv = o.prev {
                pic(catSprite(pv, 0, OfficeBreed.of(o.a.id)), cx: pv.x, cy: pv.y, w: pv.size, h: pv.size, alpha: 1 - o.p)
            }
            let w = 276 * OfficeLayout.deskScale
            let h = 214 * OfficeLayout.deskScale
            pic(OfficeAssets.image("desk-v3.webp"), cx: p.x, cy: p.y, w: w, h: h)
        }

        // 名牌和气泡最后画
        for it in items {
            tag(ctx, k: CGPoint(x: kx, y: ky), it.a, it.cur, hot: selected == it.a.id || hover == it.a.id)
        }
        for it in items {
            guard it.p > 0.6 else { continue }
            if let line = stage.line(it.a.id, now) {
                var sp = it.cur
                sp.top -= stage.jump(it.a.id, now)
                bubble(ctx, k: CGPoint(x: kx, y: ky), line, sp, bg: .white, lift: 0)
                continue
            }
            switch it.a.mood {
            case .working: bubble(ctx, k: CGPoint(x: kx, y: ky), (it.a.say ?? "..."), it.cur, bg: .white, lift: lift(it.cur))
            case .waiting: bubble(ctx, k: CGPoint(x: kx, y: ky), "？" + (it.a.say ?? "等你拍板"), it.cur, bg: Color(red: 1, green: 0.91, blue: 0.66), lift: lift(it.cur))
            case .error: bubble(ctx, k: CGPoint(x: kx, y: ky), "！" + (it.a.say ?? "没跑成"), it.cur, bg: Color(red: 1, green: 0.83, blue: 0.81), lift: 0)
            case .idle: break
            }
        }
    }

    static func tag(_ ctx: GraphicsContext, k: CGPoint, _ a: OfficeAgent, _ s: OfficeLayout.Spot, hot: Bool) {
        let r = ctx.resolve(Text(a.name).font(OfficeAssets.pixelFont(12)).foregroundColor(.white))
        let sz = r.measure(in: CGSize(width: 400, height: 40))
        let dot = 8.0
        let w = sz.width + 10 + dot + 4
        let h = sz.height + 4
        let cx = s.x * k.x
        let cy = s.tagY * k.y
        let rect = CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
        ctx.fill(Path(rect.insetBy(dx: -1.5, dy: -1.5)), with: .color(hot ? orange : Color(red: 0.1, green: 0.07, blue: 0.04)))
        ctx.fill(Path(rect), with: .color(Color(red: 0.32, green: 0.22, blue: 0.14)))
        ctx.fill(Path(CGRect(x: rect.minX + 4, y: cy - dot / 2, width: dot, height: dot)), with: .color(a.color))
        ctx.draw(r, at: CGPoint(x: rect.minX + 4 + dot + 4 + sz.width / 2, y: cy), anchor: .center)
    }

    /// 相邻两张桌子的气泡错开高度，不叠在一起
    static func lift(_ s: OfficeLayout.Spot) -> Double { s.slot % 2 == 1 ? 30 : 0 }

    static func bubble(_ ctx: GraphicsContext, k: CGPoint, _ text: String, _ s: OfficeLayout.Spot, bg: Color, lift: Double) {
        let r = ctx.resolve(Text(text).font(OfficeAssets.pixelFont(12)).foregroundColor(ink))
        let sz = r.measure(in: CGSize(width: 600, height: 40))
        let w = sz.width + 14
        let h = sz.height + 8
        let cx = s.x * k.x
        let top = s.top * k.y
        let rect = CGRect(x: max(4, cx - w / 2), y: max(4, top - h - 8 - lift), width: w, height: h)
        ctx.fill(Path(rect.insetBy(dx: -2, dy: -2)), with: .color(Color(red: 0.23, green: 0.16, blue: 0.1)))
        ctx.fill(Path(rect), with: .color(bg))
        let tx = min(max(cx, rect.minX + 8), rect.maxX - 8)
        ctx.fill(Path(CGRect(x: tx - 4, y: rect.maxY + 1, width: 8, height: 6 + lift)), with: .color(Color(red: 0.23, green: 0.16, blue: 0.1)))
        ctx.fill(Path(CGRect(x: tx - 2, y: rect.maxY - 1, width: 4, height: 6 + lift)), with: .color(bg))
        ctx.draw(r, at: CGPoint(x: rect.midX, y: rect.midY), anchor: .center)
    }
}

// MARK: - 场景视图

struct PixelOfficeScene: View {
    var agents: [OfficeAgent]
    var board: OfficeBoard
    @Binding var selected: String?
    @State private var hover: String?
    private let stage = OfficeStage.shared

    private func tip(_ a: OfficeAgent) -> String {
        let breed = OfficeBreed.of(a.id).name
        return "\(a.name) · \(breed) · \(a.mood.label)"
    }

    var body: some View {
        GeometryReader { geo in
            let kx = geo.size.width / OfficeLayout.W
            let ky = geo.size.height / OfficeLayout.H
            let spots = OfficeLayout.assign(agents)
            TimelineView(.animation(minimumInterval: 1.0 / 12.0)) { tl in
                let _ = stage.step(tl.date, spots: spots)
                ZStack(alignment: .topLeading) {
                    Canvas { ctx, size in
                        OfficeArt.draw(ctx: ctx, size: size, now: tl.date, agents: agents, stage: stage, selected: selected, hover: hover, board: board)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { selected = nil }
                    ForEach(agents) { a in
                        if let s = spots[a.id] {
                            Color.clear
                                .contentShape(Rectangle())
                                .frame(width: s.size * 0.7 * kx, height: s.size * 0.9 * ky)
                                .position(x: s.x * kx, y: s.y * ky)
                                .onTapGesture {
                                    selected = a.id
                                    stage.poke(a, now: Date())
                                }
                                .onHover { inside in
                                    if inside { hover = a.id } else if hover == a.id { hover = nil }
                                }
                                .help(tip(a))
                        }
                    }
                }
            }
        }
        .clipped()
    }
}
