import AppKit
import SwiftUI

/// 「最近」里的一条：点一下用快速预览打开
struct RecentRow: View {
    let icon: String
    let tint: Color
    let text: String
    let time: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                // 不同图标宽度不一样（气泡比文档宽），固定宽度让后面的文字左边对齐
                Image(systemName: icon).font(.system(size: 10.5)).foregroundStyle(tint).frame(width: 15)
                Text(text).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 4)
                if !time.isEmpty { Text(time).font(.system(size: 10.5)).foregroundStyle(.tertiary) }
            }
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Color.primary.opacity(hovering ? 0.06 : 0), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, -6)
        .onHover { hovering = $0 }
        .help("点一下预览")
    }
}

/// 统计里的一格数字：可以点，悬停时有底色，弹窗打开时保持高亮
struct PeekTile: View {
    let label: String
    let value: String
    let color: Color
    let active: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 1) {
                Text(value).font(.system(size: 18, weight: .bold)).monospacedDigit().foregroundStyle(color)
                Text(label).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
            }
            .padding(.vertical, 4).padding(.horizontal, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(active ? 0.09 : hovering ? 0.05 : 0), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.1), value: hovering)
        .help("点一下看看是哪些")
    }
}

/// 预览弹窗：这一类里具体有哪些，点一条直接打开
struct PeekListView: View {
    let kind: AuditProjectCard.Peek
    let entries: [AuditProjectCard.PeekEntry]
    /// 只先显示前几条，其余折叠成「显示更早的 n 条」；nil = 全部显示
    var headCount: Int? = nil
    var actions: [AuditProjectCard.PeekAction] = []
    let close: () -> Void
    @State private var hoverId: String?
    @State private var expanded = false
    private var shown: [AuditProjectCard.PeekEntry] {
        guard let h = headCount, !expanded, entries.count > h else { return entries }
        return Array(entries.prefix(h))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: kind.icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(Brand.orange)
                Text(kind.title).font(.system(size: 13, weight: .semibold))
                Text("\(entries.count)").font(.system(size: 12, weight: .medium)).foregroundStyle(.tertiary)
                Spacer()
                // 「生成今日日报 / 本周周报」之类的动作：以图标放在标题右边，悬停显示名称
                ForEach(actions) { a in
                    Button { close(); Task { await a.run() } } label: {
                        Image(systemName: a.icon).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Brand.orange)
                            .frame(width: 26, height: 24)
                            .background(Brand.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(a.label)
                }
            }
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 8)
            Divider().opacity(0.6)
            if entries.isEmpty {
                Text("现在没有这一类的内容").font(.callout).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity).padding(.vertical, 28)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(shown) { e in
                            Button { close(); e.open() } label: {
                                HStack(spacing: 9) {
                                    Image(systemName: e.icon).font(.system(size: 11, weight: .semibold)).foregroundStyle(e.tint)
                                        .frame(width: 24, height: 24)
                                        .background(e.tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(e.title.isEmpty ? "（无标题）" : e.title).font(.system(size: 12.5, weight: .medium)).foregroundStyle(.primary).lineLimit(1)
                                        Text(e.sub).font(.system(size: 10.5)).foregroundStyle(.tertiary).lineLimit(1)
                                    }
                                    Spacer(minLength: 6)
                                    if !e.trailing.isEmpty {
                                        Text(e.trailing).font(.system(size: 10.5, weight: .medium)).monospacedDigit().foregroundStyle(e.trailTint)
                                    }
                                }
                                .padding(.horizontal, 14).padding(.vertical, 6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(hoverId == e.id ? Color.primary.opacity(0.06) : Color.clear)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .onHover { hoverId = $0 ? e.id : (hoverId == e.id ? nil : hoverId) }
                        }
                        if let h = headCount, entries.count > h {
                            Button { expanded.toggle() } label: {
                                Text(expanded ? "收起" : "显示更早的 \(entries.count - h) 份")
                                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity).padding(.vertical, 7)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 340)
            }
        }
        .frame(width: 340)
    }
}
