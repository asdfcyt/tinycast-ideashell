import AppKit
import Combine
import SwiftUI

/// 屏幕变黑白期间，右下角的小卡片：推荐一个休息动作 + 离开电脑的进度 + 换一个 / 提前退出（要口令或挑战）
struct SedentaryCard: View {
    @ObservedObject private var r = SedentaryReminder.shared

    var body: some View {
        let move = r.currentMove
        let need = Double(r.restIdleMin * 60)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                Image(systemName: "figure.stand").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 28, height: 28).background(Color.green.gradient, in: Circle())
                VStack(alignment: .leading, spacing: 1) {
                    Text("该起来活动了").font(.system(size: 14, weight: .semibold))
                    Text(r.previewing ? "预览" : "已连续使用 \(r.usedMinutes) 分钟").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            Divider().opacity(0.5)

            HStack(spacing: 8) {
                Image(systemName: move.icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.green)
                    .frame(width: 24, height: 24).background(Color.green.opacity(0.14), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                Text(move.title).font(.system(size: 13, weight: .semibold))
                TagChip(text: move.area, tint: .green)
                Spacer(minLength: 0)
                Text("\(move.seconds) 秒").font(.caption2).monospacedDigit().foregroundStyle(.tertiary)
            }
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(move.steps.enumerated()), id: \.offset) { i, s in
                    Text("\(i + 1). \(s)").font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: min(r.idle / need, 1)).tint(.green)
                Text("离开电脑 \(r.restIdleMin) 分钟，屏幕恢复彩色").font(.system(size: 10.5)).foregroundStyle(.tertiary)
            }

            HStack(spacing: 8) {
                pill("arrow.triangle.2.circlepath", "换一个", prominent: false) { r.nextMove() }
                Spacer(minLength: 0)
                if !r.previewing {
                    pill("lock", "提前退出…") { r.requestEarlyExit() }
                }
            }
        }
        .padding(14)
        .frame(width: 320)
        .glassCard(radius: 18)
        .fixedSize(horizontal: false, vertical: true)
        // 卡片内容高度变了（换动作、步骤行数不同）就量出来告诉面板，面板按这个高度调，底边不动
        .background(GeometryReader { g in Color.clear.preference(key: CardHeightKey.self, value: g.size.height) })
        .onPreferenceChange(CardHeightKey.self) { h in SedentaryCardController.shared.setHeight(h) }
    }

    private func pill(_ icon: String, _ label: String, prominent: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 10, weight: .bold))
                Text(label).font(.system(size: 11.5, weight: .semibold))
            }
            .foregroundStyle(prominent ? Color.white : Color.green)
            .padding(.horizontal, 12).frame(height: 26)
            .background(prominent ? Color.green : Color.green.opacity(0.14), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct CardHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private final class SedentaryPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// 把卡片放在鼠标所在屏幕的右下角；不抢焦点，不挡其他窗口以外的东西
@MainActor
final class SedentaryCardController {
    static let shared = SedentaryCardController()
    private var panel: NSPanel?
    private var host: NSHostingView<SedentaryCard>?
    private var bag = Set<AnyCancellable>()

    func show() {
        if let p = panel { p.orderFrontRegardless(); return }
        let host = NSHostingView(rootView: SedentaryCard())
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 600)
        let size = NSSize(width: 320, height: max(host.fittingSize.height, 120))
        host.sizingOptions = []
        host.safeAreaRegions = []
        host.frame = NSRect(origin: .zero, size: size)

        let p = SedentaryPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.animationBehavior = .none
        p.contentView = host
        self.host = host
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]
        let vf = screen.visibleFrame
        p.setFrame(NSRect(x: vf.maxX - size.width - 16, y: vf.minY + 16, width: size.width, height: size.height), display: false)
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.3
            p.animator().alphaValue = 1
        }
        panel = p
    }

    /// 内容高度变化时调整面板高度（底边不动，向上长）
    func setHeight(_ h: CGFloat) {
        guard let p = panel, h > 20 else { return }
        var f = p.frame
        guard abs(f.height - h) > 0.5 else { return }
        f.size.height = h
        p.setFrame(f, display: true)
        host?.frame = NSRect(origin: .zero, size: f.size)
    }

    func hide() {
        guard let p = panel else { return }
        panel = nil
        host = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            p.animator().alphaValue = 0
        }, completionHandler: { p.orderOut(nil); p.contentView = nil })
    }
}
