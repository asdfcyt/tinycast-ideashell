import AppKit
import SwiftUI

/// 今日信息的左栏：按来源分组的当天内容
struct TodaySidebar: View {
    @ObservedObject var store: TodayStore
    @Binding var pick: String?
    @ObservedObject private var marks = ArticleMarks.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("今日信息").font(.system(size: 14, weight: .bold))
                        if store.totalUnread > 0 {
                            Text("\(store.totalUnread)").font(.caption2.weight(.bold)).foregroundStyle(.white)
                                .padding(.horizontal, 6).padding(.vertical, 1).background(Brand.orange, in: Capsule())
                        }
                    }
                    Text(Self.dateText).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button { Task { await store.reload(force: true) } } label: {
                    if store.loading { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") }
                }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("刷新全部来源").disabled(store.loading)
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            if store.groups.isEmpty {
                VStack(spacing: 8) {
                    if store.loading { ProgressView() } else {
                        Image(systemName: "sun.max").font(.system(size: 28)).foregroundStyle(.tertiary)
                        Text("今天还没有内容").font(.callout).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(store.groups) { g in
                            header(g)
                            if store.expanded.contains(g.id) {
                                ForEach(g.entries) { row($0) }
                            }
                        }
                    }
                    .padding(.horizontal, 4).padding(.vertical, 8)
                }
            }
        }
        .task { await store.loadIfNeeded() }
    }

    private static var dateText: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M 月 d 日 EEEE"
        return f.string(from: Date())
    }

    private func header(_ g: TodayGroup) -> some View {
        let open = store.expanded.contains(g.id)
        let n = store.unread(g)
        return Button { store.toggle(g.id) } label: {
            HStack(spacing: 7) {
                Image(systemName: g.icon).font(.system(size: 12)).foregroundStyle(Brand.orange).frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(g.name).font(.system(size: 13, weight: .bold))
                    if !g.note.isEmpty { Text(g.note).font(.caption2).foregroundStyle(.tertiary).lineLimit(1) }
                }
                Spacer(minLength: 0)
                if n > 0 { Text("\(n)").font(.caption2.weight(.bold)).foregroundStyle(Brand.orange) }
                Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func row(_ e: TodayEntry) -> some View {
        let on = pick == e.id
        let done = store.isRead(e)
        return Button { pick = e.id } label: {
            HStack(alignment: .top, spacing: 7) {
                Circle().fill(done ? Color.clear : Brand.orange).frame(width: 6, height: 6).padding(.top, 6)
                VStack(alignment: .leading, spacing: 2) {
                    Text(e.title).font(.system(size: 13, weight: done ? .regular : .medium))
                        .foregroundStyle(done && !on ? Color.secondary : Color.primary).lineLimit(2).multilineTextAlignment(.leading)
                    if !e.sub.isEmpty { Text(e.sub).font(.caption).foregroundStyle(.tertiary).lineLimit(1) }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 26).padding(.trailing, 8).padding(.vertical, 6)
            .background(on ? Brand.orange.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if e.kind == .web {
                ArticleMenu(title: e.title, link: e.raw, summary: e.sub)
            } else if let it = FeedStore.shared.item(e.raw) {
                Button(it.read ? "标为未读" : "标为已读") { FeedStore.shared.setRead(it.id, !it.read); store.objectWillChange.send() }
                Button(it.starred ? "取消星标" : "加星标") { FeedStore.shared.toggleStar(it.id) }
                Button("稍后读（存成待办）") { Task { await AppModel.current?.saveReadLater(title: it.title, link: it.link) } }
                if let u = URL(string: it.link) { Button("在浏览器中打开") { NSWorkspace.shared.open(u) } }
            }
        }
    }
}
