import AppKit
import SwiftUI

/*
 * 成果小票（复刻安卓端 `ResultTicket` / `CelebrationCard`）：
 * 完成一个番茄后，「专注终端」亮起琥珀色点阵屏，从出纸口「打印」出一张奶白小票——时长、任务、期间的记录、今日累计、条形码和印章。
 * 灵动岛模式下，终端就是灵动岛本身（见 IslandExtras 的实时活动）；其它情况下用 `TicketTerminalView` 自带一个。
 */

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}

enum TicketPalette {
    static let paper1 = Color(hex: 0xFCF9F1)
    static let paper2 = Color(hex: 0xF6F1E4)
    static let ink = Color(hex: 0x1F1610)
    static let mute = Color(hex: 0x6A5E53)
    static let line = Color(hex: 0xDDD2C0)
    static let deep = Color(hex: 0xB2441B)
    static let greenInk = Color(hex: 0x1F6A40)
    static let num = Color(hex: 0xB8650A)
    static let recBg = Color(hex: 0xF2ECDF)
    // 终端
    static let termTop = Color(hex: 0x1F1915)
    static let termBottom = Color(hex: 0x0E0B09)
    static let termEdge = Color(hex: 0x2C241D)
    static let led = Color(hex: 0xFFB14A)
    static let termGreen = Color(hex: 0x6FDC9A)
    static let termMute = Color(hex: 0xA39382)
}

// MARK: - 点阵屏文字

/// 点阵屏：先画琥珀色的字，再只留下一颗颗发光的点（和安卓端一样的做法）
struct DotMatrixText: View {
    let text: String
    var size: CGFloat = 28

    var body: some View {
        let step = max(size * 0.11, 2.2)
        let r = step * 0.34
        ZStack {
            // 底下一层柔光
            label.opacity(0.5).blur(radius: size * 0.28)
            label.mask {
                Canvas { ctx, sz in
                    var y = step / 2
                    while y < sz.height {
                        var x = step / 2
                        while x < sz.width {
                            ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)), with: .color(.white))
                            x += step
                        }
                        y += step
                    }
                }
            }
        }
        .fixedSize()
    }

    private var label: some View {
        Text(text)
            .font(.system(size: size, weight: .black, design: .monospaced))
            .tracking(size * 0.06)
            .foregroundStyle(TicketPalette.led)
    }

    /// 点阵屏上显示的时长：25 → 25:00；超过 99 分钟显示 120′
    static func clock(_ minutes: Int) -> String {
        switch minutes {
        case 1 ... 99: return String(format: "%02d:00", minutes)
        case let m where m > 99: return "\(m)′"
        default: return "00:00"
        }
    }
}

// MARK: - 终端（岛之外使用）

/// 深色小面板：琥珀色点阵屏 + 状态 + 出纸口。灵动岛模式下由岛本身扮演终端，不用它
struct TicketTerminalView: View {
    let c: Celebration
    var onClose: () -> Void = {}

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("拾忆 × 专注终端").font(.system(size: 10.5, weight: .semibold, design: .monospaced)).foregroundStyle(TicketPalette.termMute)
                Spacer(minLength: 0)
                Circle().fill(TicketPalette.termGreen).frame(width: 6, height: 6)
                Text(c.statusText).font(.system(size: 12, weight: .bold)).foregroundStyle(TicketPalette.termGreen)
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 8.5, weight: .bold)).foregroundStyle(TicketPalette.termMute)
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain).help("收起小票")
            }
            DotMatrixText(text: DotMatrixText.clock(c.minutes), size: 32).padding(.top, 8)
            PaperSlot().padding(.top, 9).padding(.horizontal, 6)
        }
        .padding(.horizontal, 16).padding(.top, 11).padding(.bottom, 10)
        .background(shape.fill(LinearGradient(colors: [TicketPalette.termTop, TicketPalette.termBottom], startPoint: .top, endPoint: .bottom)))
        .overlay(shape.strokeBorder(TicketPalette.termEdge, lineWidth: 1))
    }
}

/// 出纸口
struct PaperSlot: View {
    var body: some View {
        Capsule().fill(Color(hex: 0x030202))
            .overlay(Capsule().strokeBorder(Color(hex: 0x3A3028), lineWidth: 0.5))
            .frame(height: 6)
    }
}

// MARK: - 小票

/// 两侧带一排半圆缺口的纸
private struct TicketShape: Shape {
    func path(in r: CGRect) -> Path {
        let base = Path(roundedRect: r, cornerRadius: 12, style: .continuous)
        var holes = Path()
        var cy = r.minY + 7
        while cy < r.maxY {
            holes.addEllipse(in: CGRect(x: r.minX - 4.5, y: cy - 4.5, width: 9, height: 9))
            holes.addEllipse(in: CGRect(x: r.maxX - 4.5, y: cy - 4.5, width: 9, height: 9))
            cy += 14
        }
        return base.subtracting(holes)
    }
}

struct ResultTicketView: View {
    let c: Celebration
    var width: CGFloat = 300

    private typealias P = TicketPalette

    private var records: [Celebration.Entry] { Array(c.records.suffix(3)) }
    private var firstIndex: Int { c.records.count - records.count }

    private var meta: String {
        [
            c.round > 0 ? "第 \(c.round) 个番茄" : nil,
            "记录 \(c.records.count) 条",
            c.todayMin > 0 ? "今日累计 \(Self.fmt(max(c.todayMin, c.minutes)))" : nil,
        ].compactMap { $0 }.joined(separator: "   ")
    }

    static func fmt(_ m: Int) -> String { m >= 60 ? "\(m / 60) 时 \(m % 60) 分" : "\(m) 分" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            mainBlock.padding(.top, 12)
            DashedLine().padding(.top, 10)
            if !records.isEmpty { recordsBlock.padding(.top, 10) }
            Text(c.cheer)
                .font(.system(size: 11.5)).foregroundStyle(P.mute).lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10).padding(.trailing, 70)
            footer.padding(.top, 12)
        }
        .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 16)
        .frame(width: width, alignment: .leading)
        .background(TicketShape().fill(LinearGradient(colors: [P.paper1, P.paper2], startPoint: .top, endPoint: .bottom)))
        .overlay(alignment: .bottomTrailing) { stamp.padding(.trailing, 16).padding(.bottom, 14) }
        .environment(\.colorScheme, .light)
    }

    private var header: some View {
        HStack {
            Text("拾忆 · 专注小票").font(.system(size: 13, weight: .bold, design: .monospaced)).foregroundStyle(P.ink)
            Spacer(minLength: 8)
            HStack(spacing: 5) {
                Circle().fill(P.greenInk).frame(width: 6, height: 6)
                Text(c.statusText).font(.system(size: 12, weight: .bold)).foregroundStyle(P.greenInk)
            }
        }
    }

    private var mainBlock: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(spacing: 0) {
                Text(c.minutes > 0 ? "\(c.minutes)" : "—")
                    .font(.system(size: 50, weight: .heavy, design: .rounded)).monospacedDigit()
                    .foregroundStyle(P.num).minimumScaleFactor(0.6).lineLimit(1)
                Text("分钟").font(.system(size: 11)).foregroundStyle(P.mute)
            }
            .fixedSize()
            VStack(alignment: .leading, spacing: 6) {
                Text(c.title.isEmpty ? "自由专注" : c.title)
                    .font(.system(size: 15, weight: .bold)).foregroundStyle(P.ink)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Text(meta).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(P.mute)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private var recordsBlock: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                DashedLine()
                Text("期间记录 · \(c.records.count)").font(.system(size: 10.5, weight: .bold, design: .monospaced)).foregroundStyle(P.mute).fixedSize()
                DashedLine()
            }
            ForEach(Array(records.enumerated()), id: \.offset) { i, e in
                HStack(spacing: 8) {
                    Text(String(format: "%02d", firstIndex + i + 1))
                        .font(.system(size: 10.5, weight: .bold, design: .monospaced)).foregroundStyle(P.num)
                    Text(e.text.replacingOccurrences(of: "\n", with: " "))
                        .font(.system(size: 12)).foregroundStyle(P.ink).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(e.tag).font(.system(size: 9.5, design: .monospaced)).foregroundStyle(P.mute)
                }
                .padding(.vertical, 5)
                if i < records.count - 1 { DottedLine() }
            }
        }
    }

    private var footer: some View {
        let stamp = Self.stampFormatter.string(from: c.postedAt)
        return VStack(alignment: .leading, spacing: 5) {
            Barcode(seed: c.serial).frame(width: 150, height: 26)
            Text("◆ \(c.whatText) · \(stamp) · \(c.serial) ◆")
                .font(.system(size: 8.5, weight: .bold, design: .monospaced)).foregroundStyle(P.mute)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .padding(.trailing, 64)
    }

    private var stamp: some View {
        let md = Self.dayFormatter.string(from: c.postedAt)
        return ZStack {
            Circle().strokeBorder(P.deep.opacity(0.92), lineWidth: 2.5).frame(width: 50, height: 50)
            Circle().strokeBorder(P.deep.opacity(0.92), style: StrokeStyle(lineWidth: 1, dash: [2.5, 2])).frame(width: 43, height: 43)
            VStack(spacing: 1) {
                Text(c.statusText).font(.system(size: 12, weight: .bold))
                Text(md).font(.system(size: 9, weight: .bold))
            }
            .foregroundStyle(P.deep.opacity(0.92))
        }
        .rotationEffect(.degrees(-12))
    }

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm"; return f
    }()
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "M·d"; return f
    }()
}

private struct DashedLine: View {
    var body: some View {
        Rectangle().fill(.clear).frame(height: 1)
            .overlay {
                GeometryReader { g in
                    Path { p in p.move(to: .zero); p.addLine(to: CGPoint(x: g.size.width, y: 0)) }
                        .stroke(TicketPalette.line, style: StrokeStyle(lineWidth: 1.2, dash: [3, 3]))
                }
            }
    }
}

private struct DottedLine: View {
    var body: some View {
        Rectangle().fill(.clear).frame(height: 1)
            .overlay {
                GeometryReader { g in
                    Path { p in p.move(to: .zero); p.addLine(to: CGPoint(x: g.size.width, y: 0)) }
                        .stroke(TicketPalette.line, style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [0.1, 3.2]))
                }
            }
    }
}

/// 条形码：按流水号生成固定的粗细条（同一张小票每次画出来一样）
struct Barcode: View {
    let seed: String

    var body: some View {
        Canvas { ctx, size in
            var s = seed.unicodeScalars.reduce(7) { ($0 &* 31 &+ Int($1.value)) % 233_280 }
            func rnd() -> Double {
                s = (s * 9301 + 49297) % 233_280
                return Double(s) / 233_280
            }
            var x: CGFloat = 0
            while x < size.width {
                let k = CGFloat(1 + Int(rnd() * 3))
                let g = CGFloat(1 + Int(rnd() * 2.4))
                ctx.fill(Path(CGRect(x: x, y: 0, width: k, height: size.height)), with: .color(TicketPalette.ink))
                x += k + g
            }
        }
    }
}

// MARK: - 导出

@MainActor
enum TicketExporter {
    /// 深色渐变底上一张小票（保存 / 复制用）
    static func image(for c: Celebration) -> NSImage? {
        let content = ZStack {
            LinearGradient(colors: [Color(hex: 0x1A1410), Color(hex: 0x0B0908)], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [Color(hex: 0x55331F, opacity: 0.8), .clear], center: .center, startRadius: 0, endRadius: 260)
            ResultTicketView(c: c).shadow(color: .black.opacity(0.55), radius: 18, y: 10).padding(.vertical, 34)
        }
        .frame(width: 390)
        let r = ImageRenderer(content: content)
        r.scale = 3
        return r.nsImage
    }

    /// 存到「图片/拾忆」；返回文件地址
    static func save(_ c: Celebration) -> URL? {
        guard let img = image(for: c), let tiff = img.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return nil }
        let dir = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0].appendingPathComponent("拾忆", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd_HHmmss"
        let url = dir.appendingPathComponent("拾忆成果_" + f.string(from: c.postedAt) + ".png")
        do { try png.write(to: url); return url } catch { return nil }
    }

    static func copy(_ c: Celebration) -> Bool {
        guard let img = image(for: c) else { return false }
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.writeObjects([img])
    }
}
