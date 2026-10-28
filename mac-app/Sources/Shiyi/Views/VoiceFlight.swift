import AppKit
import SwiftUI

/// 语音卡片 ↔ 万能输入框的「开合」动画，参考 iPhone 灵动岛：
/// 卡片带一点回弹收成一颗小胶囊 → 沿弧线飞到目标位置 → 胶囊展开成目标卡片（目标窗口同时淡入）→ 光晕一闪。
/// 纯装饰：开一个盖住两张卡片的透明窗口（大小不变），用 Core Animation 在 GPU 上一次性播完，放完就关，不拦截鼠标。
@MainActor
enum VoiceFlight {
    private static var panel: NSPanel?
    private static var token = 0

    /// 总时长（秒）与「落下」发生的时刻占比；onLand 在胶囊开始展开时调用（让目标窗口淡入）
    private static let duration: CFTimeInterval = 1.0
    private static let landAt = 0.64

    /// from / to 是两个卡片在屏幕上的位置（AppKit 坐标，左下角为原点）；缺一个或系统开了「减弱动态效果」就不放动画（直接 onLand）
    static func fly(from: NSRect?, to: NSRect?, onLand: (() -> Void)? = nil) {
        guard let from, let to, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            onLand?()
            return
        }
        token += 1
        let mine = token
        panel?.orderOut(nil)

        // 窗口固定盖住「起点 ∪ 终点」再外扩一圈（给光晕留位置），整个动画期间不改大小
        let region = from.union(to).insetBy(dx: -40, dy: -40)
        let p = NSPanel(contentRect: region, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.isReleasedWhenClosed = false
        p.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 5)
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let view = NSView(frame: NSRect(origin: .zero, size: region.size))
        view.wantsLayer = true
        view.layer = CALayer()
        p.contentView = view
        p.orderFrontRegardless()
        panel = p

        let scale = p.backingScaleFactor
        func local(_ r: NSRect) -> CGRect { r.offsetBy(dx: -region.minX, dy: -region.minY) }
        let f = local(from), t = local(to)
        let orange = NSColor(Brand.orange)

        // —— 胶囊：渐变底 + 波形图标 ——
        let pill = CGSize(width: 116, height: 36)
        let blob = CAGradientLayer()
        blob.colors = [orange.cgColor, NSColor.systemPink.withAlphaComponent(0.85).cgColor]
        blob.startPoint = CGPoint(x: 0, y: 1)
        blob.endPoint = CGPoint(x: 1, y: 0)
        blob.bounds = CGRect(origin: .zero, size: f.size)
        blob.position = CGPoint(x: f.midX, y: f.midY)
        blob.cornerRadius = min(f.height / 2, 22)
        blob.shadowColor = orange.cgColor
        blob.shadowOpacity = 0.5
        blob.shadowRadius = 9
        blob.shadowOffset = .zero
        blob.contentsScale = scale
        view.layer?.addSublayer(blob)

        let icon = CALayer()
        if let img = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 15, weight: .bold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))),
           let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            icon.contents = cg
            icon.contentsGravity = .center
            icon.contentsScale = scale
        }
        icon.frame = CGRect(x: (pill.width - 28) / 2, y: (pill.height - 28) / 2, width: 28, height: 28)
        icon.opacity = 0
        blob.addSublayer(icon)

        // —— 光晕：沿目标卡片外沿扩散 ——
        let ring = CAShapeLayer()
        ring.bounds = CGRect(origin: .zero, size: t.size)
        ring.position = CGPoint(x: t.midX, y: t.midY)
        ring.path = CGPath(roundedRect: CGRect(origin: .zero, size: t.size), cornerWidth: 20, cornerHeight: 20, transform: nil)
        ring.fillColor = nil
        ring.strokeColor = orange.withAlphaComponent(0.9).cgColor
        ring.lineWidth = 2.5
        ring.shadowColor = orange.cgColor
        ring.shadowOpacity = 0.6
        ring.shadowRadius = 10
        ring.shadowOffset = .zero
        ring.opacity = 0
        view.layer?.addSublayer(ring)

        // —— 位置：先原地收缩，再沿弧线飞到落点（目标卡片上缘中间），最后随展开挪到目标卡片中心 ——
        let start = CGPoint(x: f.midX, y: f.midY)
        let land = CGPoint(x: t.midX, y: t.maxY - 30)
        let end = CGPoint(x: t.midX, y: t.midY)
        let bend: CGFloat = land.x >= start.x ? -1 : 1
        let ctrl = CGPoint(x: (start.x + land.x) / 2 + bend * 90, y: (start.y + land.y) / 2)
        func bezier(_ u: CGFloat) -> CGPoint {
            let v = 1 - u
            return CGPoint(x: v * v * start.x + 2 * v * u * ctrl.x + u * u * land.x,
                           y: v * v * start.y + 2 * v * u * ctrl.y + u * u * land.y)
        }
        func ease(_ x: CGFloat) -> CGFloat { x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2 }   // easeInOutCubic
        let travelStart = 0.2, travelEnd = landAt
        var posValues: [CGPoint] = [start, start]
        var posTimes: [NSNumber] = [0, NSNumber(value: travelStart)]
        let steps = 10
        for i in 1 ... steps {
            let x = CGFloat(i) / CGFloat(steps)
            posValues.append(bezier(ease(x)))
            posTimes.append(NSNumber(value: travelStart + (travelEnd - travelStart) * Double(x)))
        }
        posValues.append(end)
        posTimes.append(1)

        let d = duration
        let now = CACurrentMediaTime()

        let move = CAKeyframeAnimation(keyPath: "position")
        move.values = posValues.map { NSValue(point: $0) }
        move.keyTimes = posTimes
        move.calculationMode = .cubic

        // 带回弹的曲线：收缩 / 展开都有一点过冲，像灵动岛的弹性
        let springy = CAMediaTimingFunction(controlPoints: 0.34, 1.45, 0.64, 1)
        let shrinkEnd = 0.26
        let sizeTimes: [NSNumber] = [0, NSNumber(value: shrinkEnd), NSNumber(value: landAt), 1]
        let bounds = CAKeyframeAnimation(keyPath: "bounds")
        bounds.values = [CGRect(origin: .zero, size: f.size), CGRect(origin: .zero, size: pill),
                         CGRect(origin: .zero, size: pill), CGRect(origin: .zero, size: t.size)].map { NSValue(rect: $0) }
        bounds.keyTimes = sizeTimes
        bounds.timingFunctions = [springy, CAMediaTimingFunction(name: .linear), springy]

        let radius = CAKeyframeAnimation(keyPath: "cornerRadius")
        radius.values = [min(f.height / 2, 22), pill.height / 2, pill.height / 2, 20]
        radius.keyTimes = sizeTimes
        radius.timingFunctions = [springy, CAMediaTimingFunction(name: .linear), springy]

        // 开头与淡出的卡片交叉渐变；展开时渐隐，露出淡入的目标卡片
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 0.95, 0.95, 0.5, 0]
        fade.keyTimes = [0, 0.1, NSNumber(value: landAt), 0.82, 1]

        let group = CAAnimationGroup()
        group.animations = [move, bounds, radius, fade]
        group.duration = d
        group.beginTime = now
        group.fillMode = .forwards
        group.isRemovedOnCompletion = false
        blob.position = end
        blob.bounds = CGRect(origin: .zero, size: t.size)
        blob.opacity = 0
        blob.add(group, forKey: "fly")

        // 图标：收成胶囊后出现，展开前消失
        let iconFade = CAKeyframeAnimation(keyPath: "opacity")
        iconFade.values = [0, 0, 1, 1, 0, 0]
        iconFade.keyTimes = [0, 0.14, NSNumber(value: shrinkEnd), NSNumber(value: landAt - 0.04), NSNumber(value: landAt + 0.06), 1]
        iconFade.duration = d
        iconFade.beginTime = now
        iconFade.fillMode = .both
        icon.opacity = 0
        icon.add(iconFade, forKey: "icon")
        // 图标始终居中在胶囊里（胶囊尺寸变化时跟着）
        icon.position = CGPoint(x: pill.width / 2, y: pill.height / 2)
        let iconPos = CAKeyframeAnimation(keyPath: "position")
        iconPos.values = [CGPoint(x: f.width / 2, y: f.height / 2), CGPoint(x: pill.width / 2, y: pill.height / 2),
                          CGPoint(x: pill.width / 2, y: pill.height / 2), CGPoint(x: t.width / 2, y: t.height / 2)].map { NSValue(point: $0) }
        iconPos.keyTimes = sizeTimes
        iconPos.timingFunctions = [springy, CAMediaTimingFunction(name: .linear), springy]
        iconPos.duration = d
        iconPos.beginTime = now
        iconPos.fillMode = .both
        icon.add(iconPos, forKey: "iconPos")

        // 光晕：展开的同时亮起，沿卡片外沿扩散后淡出
        let ringStart = d * landAt
        let ringScale = CABasicAnimation(keyPath: "transform.scale")
        ringScale.fromValue = 0.96
        ringScale.toValue = 1.035
        let ringFade = CAKeyframeAnimation(keyPath: "opacity")
        ringFade.values = [0, 1, 0]
        ringFade.keyTimes = [0, 0.3, 1]
        let ringGroup = CAAnimationGroup()
        ringGroup.animations = [ringScale, ringFade]
        ringGroup.beginTime = now + ringStart
        ringGroup.duration = d - ringStart + 0.25
        ringGroup.timingFunction = CAMediaTimingFunction(name: .easeOut)
        ringGroup.fillMode = .both
        ring.add(ringGroup, forKey: "ring")

        // 落下：目标窗口开始淡入
        DispatchQueue.main.asyncAfter(deadline: .now() + d * landAt) {
            guard mine == token else { return }
            onLand?()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + d + 0.3) {
            guard mine == token else { return }
            p.orderOut(nil)
            if panel === p { panel = nil }
        }
    }
}
