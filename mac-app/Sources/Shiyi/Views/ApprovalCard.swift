import AppKit
import SwiftUI

/// 调度台的展示面：审批请求（该你拍板的）排在前面，Agent 做完的验收卡排在后面。
/// - 灵动岛模式：嵌在岛里（`embedded`，一次一张，下面提示还有几条）
/// - 菜单栏模式：右上角悬浮卡片（最多 3 张）
struct AgentSurface: View {
    @ObservedObject private var center = ApprovalCenter.shared
    let embedded: Bool
    let limit: Int

    private enum Item: Identifiable {
        case approval(Approval)
        case done(AgentCompletion)
        var id: UUID {
            switch self {
            case let .approval(a): return a.id
            case let .done(c): return c.id
            }
        }
    }

    var body: some View {
        let items: [Item] = center.pending.map(Item.approval) + center.completions.map(Item.done)
        let shown = Array(items.prefix(limit))
        VStack(spacing: 10) {
            ForEach(shown) { item in
                switch item {
                case let .approval(a):
                    ApprovalCardView(a: a, first: a.id == center.pending.first?.id, embedded: embedded)
                case let .done(c):
                    CompletionCardView(c: c, embedded: embedded)
                }
            }
            if items.count > limit {
                Text("还有 \(items.count - limit) 条在排队，处理完这条就会出现")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .modifier(QueueChrome(embedded: embedded))
            }
        }
        .animation(.easeOut(duration: 0.18), value: shown.map(\.id))
    }
}

private struct QueueChrome: ViewModifier {
    let embedded: Bool
    func body(content: Content) -> some View {
        if embedded { content } else { content.glassCard(radius: 12) }
    }
}

/// 右上角悬浮卡片（菜单栏模式，或灵动岛不可用时）的内容
struct ApprovalStack: View {
    var body: some View {
        AgentSurface(embedded: false, limit: 3)
            .frame(width: ApprovalPanelController.width)
            .fixedSize(horizontal: false, vertical: true)
            .background(GeometryReader { g in Color.clear.preference(key: ApprovalHeightKey.self, value: g.size.height) })
            .onPreferenceChange(ApprovalHeightKey.self) { h in ApprovalPanelController.shared.setHeight(h) }
    }
}

private struct ApprovalHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct AgentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// 灵动岛里的「调度台」页：内容高度由 SwiftUI 量好，回传给岛控制器让面板跟着长高 / 缩短
struct IslandAgentView: View {
    @ObservedObject var state: IslandState

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            AgentSurface(embedded: true, limit: 1)
                .frame(width: state.expandedWidth - 24)
                .background(GeometryReader { g in Color.clear.preference(key: AgentHeightKey.self, value: g.size.height) })
        }
        .frame(width: state.expandedWidth - 24, height: state.shownAgentHeight)
        .padding(.top, state.topInset)
        .onPreferenceChange(AgentHeightKey.self) { h in
            guard h > 0 else { return }
            state.onAgentHeight?(h)
        }
    }
}

private extension View {
    /// 卡片外壳：悬浮时是玻璃卡片；嵌在岛里时是岛（黑底）上一块略亮的圆角底
    @ViewBuilder func cardChrome(embedded: Bool) -> some View {
        if embedded {
            padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.08)))
        } else {
            padding(12).frame(width: ApprovalPanelController.width).glassCard(radius: 16)
        }
    }
}

private struct CardPill: View {
    let label: String
    let tint: Color
    let prominent: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label).font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(prominent ? Color.white : tint)
                .padding(.horizontal, 12).frame(height: 26)
                .background(prominent ? tint : tint.opacity(0.14), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// 两个并排的次要按钮：等宽、同高
private struct WideButton: View {
    let label: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 10.5, weight: .semibold))
                Text(label).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity).frame(height: 28)
            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct MinimizeButton: View {
    var body: some View {
        Button { IslandController.shared.collapse() } label: {
            Image(systemName: "chevron.up").font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary).frame(width: 22, height: 22)
                .background(Color.primary.opacity(0.08), in: Circle())
        }
        .buttonStyle(.plain)
        .help("先收起（Esc），之后还能在刘海处点开")
    }
}

// MARK: - 运行状态条（岛展开后，只在有 Agent 在跑时出现）

struct AgentRunStrip: View {
    @ObservedObject private var runs = AgentRunTracker.shared
    @ObservedObject private var center = ApprovalCenter.shared
    var body: some View {
        if !runs.runs.isEmpty {
            VStack(spacing: 0) {
                VStack(spacing: 6) {
                    ForEach(runs.runs) { r in
                        HStack(spacing: 8) {
                            row(r)
                            openButton(r)
                            if r.canStop { stopButton(r) }
                        }
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                Divider().padding(.horizontal, 12)
            }
        }
    }

    private func openButton(_ r: AgentRun) -> some View {
        Button { runs.open(r) } label: {
            Image(systemName: "arrow.up.forward.app").font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .background(Color.primary.opacity(0.1), in: Circle())
        }
        .buttonStyle(.plain)
        .help("打开 \(r.source.title) 的窗口")
    }

    private func stopButton(_ r: AgentRun) -> some View {
        Button { runs.stop(r) } label: {
            Group {
                if r.stopping {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "stop.fill").font(.system(size: 8.5, weight: .bold))
                }
            }
            .foregroundStyle(r.stopping ? Color.secondary : Color.red)
            .frame(width: 22, height: 22)
            .background(Color.primary.opacity(0.1), in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(r.stopping)
        .help(r.stopping ? "正在停止…" : "停止")
    }

    private func row(_ r: AgentRun) -> some View {
        let waiting = center.pending.contains { $0.source == r.source }
        return HStack(spacing: 9) {
            Image(systemName: r.source.icon).font(.system(size: 10.5, weight: .bold)).foregroundStyle(.white)
                .frame(width: 22, height: 22).background(r.source.color.gradient, in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(r.source.title).font(.system(size: 12, weight: .semibold))
                    Text("·").foregroundStyle(.tertiary)
                    Text(r.project).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                if waiting {
                    Text("等你批准").font(.system(size: 11)).foregroundStyle(Color.orange)
                } else {
                    Text(r.activity ?? "思考中…")
                        .font(.system(size: 11, design: r.activity == nil ? .default : .monospaced))
                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                }
            }
            Spacer(minLength: 6)
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                let s = max(Int(ctx.date.timeIntervalSince(r.started)), 0)
                Text(String(format: "%d:%02d", s / 60, s % 60))
                    .font(.system(size: 11, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

// MARK: - 审批卡

struct ApprovalCardView: View {
    let a: Approval
    let first: Bool
    var embedded = false
    @State private var commenting = false
    @State private var comment = ""
    @State private var expanded = false

    private var center: ApprovalCenter { ApprovalCenter.shared }
    private var canRememberAllow: Bool { a.ruleKey != nil && a.risk != .high }
    private var canRememberDeny: Bool { a.ruleKey != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: a.source.icon).font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 26, height: 26).background(a.source.color.gradient, in: Circle())
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(a.source.title).font(.system(size: 13.5, weight: .semibold))
                        Text("·").foregroundStyle(.tertiary)
                        Text(a.project).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Text("需要你确认 · " + a.kind.label).font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 6)
                if a.risk != .low { TagChip(text: a.risk.label, tint: a.risk.tint) }
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text("\(max(Int(a.deadline.timeIntervalSince(ctx.date).rounded(.up)), 0))s")
                        .font(.caption2).monospacedDigit().foregroundStyle(.tertiary)
                }
                if embedded { MinimizeButton() }
            }

            if a.kind == .mcp {
                Text(a.heading).font(.system(size: 12, weight: .semibold))
            }
            Text(a.detail)
                .font(.system(size: 11.5, design: .monospaced))
                .lineLimit(expanded ? 40 : (embedded ? 10 : 6))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .onTapGesture { expanded.toggle() }
                .help(expanded ? "点击收起" : "点击展开全部")

            if !a.reasons.isEmpty {
                Label(a.reasons.joined(separator: " · "), systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11)).foregroundStyle(a.risk.tint)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if commenting {
                HStack(spacing: 6) {
                    TextField("拒绝理由（会原样告诉 Agent）", text: $comment)
                        .textFieldStyle(.roundedBorder).font(.system(size: 12))
                        .onSubmit { center.deny(a.id, comment: comment) }
                    CardPill(label: "拒绝", tint: .red, prominent: true) { center.deny(a.id, comment: comment) }
                }
            }

            HStack(spacing: 7) {
                CardPill(label: "允许" + (first ? "  ⌃⌥Y" : ""), tint: .green, prominent: true) { center.allow(a.id) }
                CardPill(label: "拒绝" + (first ? "  ⌃⌥N" : ""), tint: .red, prominent: false) { center.deny(a.id) }
                CardPill(label: commenting ? "收起理由" : "写理由", tint: .gray, prominent: false) { withAnimation(.easeOut(duration: 0.15)) { commenting.toggle() } }
                Spacer(minLength: 0)
                if canRememberAllow || canRememberDeny {
                    Menu {
                        if canRememberAllow { Button("允许，且以后同类操作都允许") { center.allowAlways(a.id) } }
                        if canRememberDeny { Button("拒绝，且以后同类操作都拒绝") { center.denyAlways(a.id) } }
                    } label: {
                        Image(systemName: "ellipsis").font(.system(size: 12, weight: .bold)).frame(width: 24, height: 24)
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                }
            }
        }
        .cardChrome(embedded: embedded)
    }
}

// MARK: - 验收卡（Agent 做完了）

/// Agent 做完一轮：看它最后说了什么，一键 / 一句话让它接着干，或者点「知道了」放它走。
/// 对方（Cursor / WorkBuddy）在这段时间里一直等着你，超时就当没事发生。
/// 嵌在灵动岛里时左右两栏：左 2/3 是 Markdown 渲染的回复，右 1/3 是操作；悬浮卡片（窄）仍然上下排。
struct CompletionCardView: View {
    let c: AgentCompletion
    var embedded = false
    @State private var text = ""
    @State private var expanded = false
    @State private var mdHeight: CGFloat = 160
    @State private var hovering = false

    private var center: ApprovalCenter { ApprovalCenter.shared }
    private var statusText: String { c.failed ? "出错了" : (c.asksQuestion ? "在等你回复" : "已完成") }
    private var statusTint: Color { c.failed ? .red : (c.asksQuestion ? .orange : .green) }

    var body: some View {
        content
            // 鼠标在卡片上 / 输入框里有字：对方的等待时间顺延，别让卡片在你读的时候消失
            .onHover { h in hovering = h; updatePin() }
            .onChange(of: text) { _, _ in updatePin() }
    }

    private func updatePin() { center.pinCompletion(c.id, hovering || !text.isEmpty) }

    @ViewBuilder private var content: some View {
        if embedded {
            HStack(alignment: .top, spacing: 12) {
                left.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).layoutPriority(2)
                right
                    .padding(10)
                    .frame(width: Self.rightWidth, alignment: .topLeading)
                    .frame(maxHeight: .infinity, alignment: .topLeading)
                    .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .cardChrome(embedded: true)
        } else {
            VStack(alignment: .leading, spacing: 9) {
                header
                conclusion
                Text(Self.plain(c.summary))
                    .font(.system(size: 12.5))
                    .foregroundStyle(c.summary.isEmpty ? .tertiary : .primary)
                    .lineSpacing(2)
                    .lineLimit(expanded ? 80 : 14)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .onTapGesture { expanded.toggle() }
                    .help(expanded ? "点击收起" : "点击展开全部")
                actions
            }
            .cardChrome(embedded: false)
        }
    }

    /// 右栏宽度：岛 760 宽时约占 1/3
    static let rightWidth: CGFloat = 250

    // MARK: 左栏：Markdown 回复

    private var left: some View {
        VStack(alignment: .leading, spacing: 8) {
            conclusion
            ScrollView(.vertical, showsIndicators: true) {
                Group {
                    if c.summary.isEmpty {
                        Text("（没有拿到 Agent 的回复内容）").foregroundStyle(.tertiary)
                    } else {
                        MarkdownView(text: c.summary).font(.system(size: 12.5))
                    }
                }
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(GeometryReader { g in Color.clear.preference(key: MDHeightKey.self, value: g.size.height) })
            }
            .frame(height: min(max(mdHeight, 230), 430))
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .onPreferenceChange(MDHeightKey.self) { h in if h > 0, abs(h - mdHeight) > 1 { mdHeight = h } }
        }
    }

    // MARK: 右栏：状态 + 操作

    private var right: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            meta
            ForEach(c.options) { o in optionButton(o) }
            if c.detached {
                Text("\(c.source.title) 已继续往下走，点指令会复制到剪贴板并带你回去粘贴")
                    .font(.system(size: 10.5)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            composer
            HStack(spacing: 6) {
                WideButton(label: "知道了", symbol: "checkmark") { center.dismissCompletion(c.id) }
                WideButton(label: "打开 \(c.source.title)", symbol: "arrow.up.forward.app", action: open)
            }
        }
    }

    /// 输入区：一个带发送键的圆角输入框（回车发送），比「输入框 + 一排按钮」干净
    private var composer: some View {
        let empty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return HStack(alignment: .bottom, spacing: 6) {
            TextField(c.detached ? "写一句，复制后回去粘贴…" : "接着说点什么…", text: $text, axis: .vertical)
                .textFieldStyle(.plain).font(.system(size: 12.5)).lineLimit(1 ... 4)
                .onSubmit(send)
                .padding(.vertical, 5)
            Button(action: send) {
                Image(systemName: c.detached ? "doc.on.doc.fill" : "arrow.up.circle.fill")
                    .font(.system(size: c.detached ? 15 : 22))
                    .foregroundStyle(empty ? c.source.color.opacity(0.35) : c.source.color)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain).disabled(empty)
            .help(c.detached ? "复制到剪贴板并打开 \(c.source.title)" : "发送给 \(c.source.title)")
        }
        .padding(.leading, 10).padding(.trailing, 5).padding(.vertical, 3)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.08)))
    }

    /// 这一轮的小信息：用时 / 回复字数 / 所在目录
    private var meta: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                if let d = c.duration {
                    Label(Self.durationText(d), systemImage: "clock").labelStyle(.titleAndIcon)
                }
                if !c.summary.isEmpty {
                    Label("\(c.summary.count) 字", systemImage: "text.alignleft")
                }
            }
            .font(.system(size: 11)).foregroundStyle(.secondary)
            if !c.cwd.isEmpty {
                Text((c.cwd as NSString).abbreviatingWithTildeInPath)
                    .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.head)
            }
        }
    }

    private static func durationText(_ s: TimeInterval) -> String {
        let n = Int(s)
        return n >= 60 ? "\(n / 60) 分 \(n % 60) 秒" : "\(n) 秒"
    }

    private func optionButton(_ o: AgentCompletion.Option) -> some View {
        Button { center.followUp(c.id, text: o.instruction) } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.turn.down.right").font(.system(size: 10, weight: .bold)).foregroundStyle(c.source.color)
                    Text(o.label).font(.system(size: 12, weight: .semibold))
                }
                Text(o.instruction).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.leading)
            }
            .padding(.horizontal, 9).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(c.source.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(o.instruction)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: c.source.icon).font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                .frame(width: 26, height: 26).background(c.source.color.gradient, in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(c.source.title).font(.system(size: 13.5, weight: .semibold))
                    if !embedded {
                        Text("·").foregroundStyle(.tertiary)
                        Text(c.project).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
                if embedded {
                    Text(c.project).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                HStack(spacing: 6) {
                    Text(statusText).font(.system(size: 11.5, weight: .medium)).foregroundStyle(statusTint)
                    if c.detached {
                        Text("不再等待").font(.caption2).foregroundStyle(.tertiary)
                    } else if !c.viaDispatch {
                        TimelineView(.periodic(from: .now, by: 1)) { ctx in
                            Text("等你 \(max(Int(c.deadline.timeIntervalSince(ctx.date).rounded(.up)), 0))s")
                                .font(.caption2).monospacedDigit().foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            Spacer(minLength: 4)
            if embedded { MinimizeButton() }
        }
    }

    @ViewBuilder private var conclusion: some View {
        if let k = c.conclusion {
            Label(k, systemImage: "sparkles")
                .font(.system(size: 12, weight: .medium)).foregroundStyle(Brand.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 窄卡片（悬浮）的操作区
    private var actions: some View {
        VStack(alignment: .leading, spacing: 8) {
            do {
                VStack(spacing: 5) {
                    ForEach(c.options) { o in
                        Button { center.followUp(c.id, text: o.instruction) } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.turn.down.right").font(.system(size: 10, weight: .bold)).foregroundStyle(c.source.color)
                                Text(o.label).font(.system(size: 12, weight: .semibold))
                                Text(o.instruction).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 9).frame(height: 28)
                            .background(c.source.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(o.instruction)
                    }
                }
                HStack(spacing: 6) {
                    TextField("接着说点什么，回车发给 \(c.source.title)", text: $text)
                        .textFieldStyle(.roundedBorder).font(.system(size: 12))
                        .onSubmit(send)
                    CardPill(label: "发送", tint: c.source.color, prominent: true, action: send)
                }
            }
            HStack(spacing: 7) {
                CardPill(label: "知道了", tint: .gray, prominent: false) { center.dismissCompletion(c.id) }
                CardPill(label: "打开 \(c.source.title)", tint: .gray, prominent: false, action: open)
            }
        }
    }

    private func send() { center.followUp(c.id, text: text) }

    private func open() {
        center.openSource(c.source)
        center.dismissCompletion(c.id)
    }

    /// 窄卡片里用的：行内 Markdown（`代码`、**加粗**）渲染，块级符号保留原样
    private static func plain(_ s: String) -> AttributedString {
        if s.isEmpty { return AttributedString("（没有拿到 Agent 的回复内容）") }
        let opt = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: s, options: opt)) ?? AttributedString(s)
    }
}

private struct MDHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// 可以点输入理由，但不抢其他 App 的焦点（nonactivatingPanel）
private final class ApprovalPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// 卡片叠在鼠标所在屏幕的右上角（菜单栏下面），顶边不动，内容高度变了向下长
@MainActor
final class ApprovalPanelController {
    static let shared = ApprovalPanelController()
    static let width: CGFloat = 440
    private var panel: NSPanel?
    private var host: NSHostingView<ApprovalStack>?
    private var top: CGFloat = 0

    func sync(count: Int) {
        if count == 0 { hide() } else { show() }
    }

    private func show() {
        if let p = panel { p.orderFrontRegardless(); return }
        let host = NSHostingView(rootView: ApprovalStack())
        host.sizingOptions = []
        host.safeAreaRegions = []
        let size = NSSize(width: Self.width, height: 260)
        host.frame = NSRect(origin: .zero, size: size)

        let p = ApprovalPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
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
        top = vf.maxY - 10
        p.setFrame(NSRect(x: vf.maxX - size.width - 14, y: top - size.height, width: size.width, height: size.height), display: false)
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            p.animator().alphaValue = 1
        }
        panel = p
    }

    func setHeight(_ h: CGFloat) {
        guard let p = panel, h > 20 else { return }
        var f = p.frame
        guard abs(f.height - h) > 0.5 else { return }
        f.size.height = h
        f.origin.y = top - h
        p.setFrame(f, display: true)
        host?.frame = NSRect(origin: .zero, size: f.size)
    }

    private func hide() {
        guard let p = panel else { return }
        panel = nil
        host = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            p.animator().alphaValue = 0
        }, completionHandler: { p.orderOut(nil); p.contentView = nil })
    }
}
