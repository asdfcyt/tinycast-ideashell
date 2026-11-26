import AppKit
import SwiftUI

/*
 * 财新周刊、三联的「图标」：用各自最新一期的真实封面缩成小图（圆角 + 细描边）。
 * 封面存在本机，下次启动立刻就有；还没取到时退回原来的 SF Symbol。
 */
@MainActor
final class MagazineIcons: ObservableObject {
    static let shared = MagazineIcons()

    /// key: "caixin" / "lifeweek"
    @Published private(set) var images: [String: NSImage] = [:]
    private var loaded: [String: URL] = [:]

    private init() {
        for k in ["caixin", "lifeweek"] {
            if let d = try? Data(contentsOf: Self.file(k)), let img = Self.make(d) { images[k] = img }
        }
    }

    private static func file(_ key: String) -> URL { LocalStore.dir.appendingPathComponent("cover-\(key).img") }

    /// 目录载入后调用：封面换了（出了新一期）就重新下载
    func refresh() async {
        await WeeklyStore.shared.loadIfNeeded()
        await LifeweekStore.shared.loadIfNeeded()
        await fetch("caixin", WeeklyStore.shared.issues.first?.cover)
        await fetch("lifeweek", LifeweekStore.shared.issues.first?.cover)
    }

    private func fetch(_ key: String, _ url: URL?) async {
        guard let url, loaded[key] != url else { return }
        guard let (data, resp) = try? await URLSession.shared.data(from: url),
              (resp as? HTTPURLResponse)?.statusCode == 200, let img = Self.make(data) else { return }
        loaded[key] = url
        segCache = segCache.filter { !$0.key.hasPrefix(key + "|") }
        images[key] = img
        try? data.write(to: Self.file(key), options: .atomic)
    }

    // MARK: 标题栏分段控件用的图：统一画在 38×20 的透明底上，每一段（和选中的那一块）就一样宽，和「日 / 周 / 月 / 年」那种宽分段一致

    private static let segSize = NSSize(width: 38, height: 20)

    /// 某个来源在标题栏分段控件里的图：有封面用封面（彩色），否则用 SF Symbol（跟随系统着色）
    func segmentImage(key: String?, symbol: String) -> NSImage {
        // 每次都新画一张的话，标题栏的分段控件会当成「图变了」整体重建，选中的滑动动画就没了：同一张图只画一次
        let ck = (key ?? "") + "|" + symbol + "|" + (key.flatMap { images[$0] } != nil ? "cover" : "sym")
        if let hit = segCache[ck] { return hit }
        let made = drawSegment(key: key, symbol: symbol)
        segCache[ck] = made
        return made
    }

    private var segCache: [String: NSImage] = [:]

    private func drawSegment(key: String?, symbol: String) -> NSImage {
        if let key, let cover = images[key] {
            let target = NSSize(width: 13.5, height: 18)
            let img = NSImage(size: Self.segSize, flipped: false) { rect in
                cover.draw(in: NSRect(x: (rect.width - target.width) / 2, y: (rect.height - target.height) / 2, width: target.width, height: target.height))
                return true
            }
            img.isTemplate = false
            return img
        }
        let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        let sym = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
        let img = NSImage(size: Self.segSize, flipped: false) { rect in
            if let sym {
                let z = sym.size
                sym.draw(in: NSRect(x: (rect.width - z.width) / 2, y: (rect.height - z.height) / 2, width: z.width, height: z.height))
            }
            return true
        }
        img.isTemplate = true
        return img
    }

    /// 封面 → 3:4 的小图，圆角、细描边（一份图在标题栏和左栏都够清楚）
    private static func make(_ data: Data) -> NSImage? {
        guard let src = NSImage(data: data), src.size.width > 0, src.size.height > 0 else { return nil }
        let size = NSSize(width: 15, height: 20)
        let img = NSImage(size: size, flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 2.5, yRadius: 2.5)
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            // 按宽高比铺满（居中裁切）
            let s = max(rect.width / src.size.width, rect.height / src.size.height)
            let w = src.size.width * s, h = src.size.height * s
            src.draw(in: NSRect(x: (rect.width - w) / 2, y: (rect.height - h) / 2, width: w, height: h),
                     from: .zero, operation: .sourceOver, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
            NSColor.black.withAlphaComponent(0.18).setStroke()
            path.lineWidth = 0.6
            path.stroke()
            return true
        }
        img.isTemplate = false
        return img
    }
}

/// 来源图标：有封面（财新周刊 / 三联）就显示封面，没有就用 SF Symbol。`height` 是图标高度
struct SourceIcon: View {
    /// "caixin" / "lifeweek" / 其他
    let key: String
    let symbol: String
    var height: CGFloat = 16
    @ObservedObject private var icons = MagazineIcons.shared

    var body: some View {
        if let img = icons.images[key] {
            Image(nsImage: img).resizable().interpolation(.high)
                .aspectRatio(0.75, contentMode: .fit).frame(height: height)
        } else {
            Image(systemName: symbol).font(.system(size: height * 0.78))
        }
    }
}
