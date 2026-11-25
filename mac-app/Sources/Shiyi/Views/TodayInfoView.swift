import AppKit
import SwiftUI

/// 今日信息的左栏：按来源分组的当天内容
struct TodaySidebar: View {
    @ObservedObject var store: TodayStore
    @Binding var pick: String?
    /// 点「AI 速览」：右边回到速览页
    var onDigest: () -> Void = {}
    @ObservedObject private var marks = ArticleMarks.shared
    @ObservedObject private var digest = TodayDigestStore.shared

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
            if !store.groups.isEmpty { digestRow }
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

    /// 「AI 速览」入口：点开右边是今天内容的概览、场景和洞察
    private var digestRow: some View {
        let on = pick == nil
        return Button {
            pick = nil
            onDigest()
            // 还没有今天的速览：点一下就直接开始生成
            if digest.digest == nil && !digest.busy { digest.generate(store: store) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "binoculars").font(.system(size: 12)).foregroundStyle(Brand.orange).frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text("AI 速览").font(.system(size: 13, weight: .bold))
                    Text(digest.digest == nil ? "一分钟看完今天要读的" : "先读什么、场景与洞察").font(.caption2).foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
                if digest.busy { ProgressView().controlSize(.mini) }
                else if digest.digest == nil { Text("生成").font(.caption2.weight(.semibold)).foregroundStyle(Brand.orange) }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(Brand.orange.opacity(on ? 0.16 : 0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6).padding(.bottom, 2)
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


/// 今日信息右边的「AI 速览」页：今天有什么（按来源）→ 先读哪几篇、为什么 → 场景 → 洞察，点文章直接去读
struct TodayDigestView: View {
    @ObservedObject var store: TodayStore
    @ObservedObject private var digest = TodayDigestStore.shared
    /// 点文章：参数是今日信息条目 ID
    let open: (String) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                head
                if let e = digest.error { Text(e).font(.callout).foregroundStyle(.red) }
                if let d = digest.digest {
                    content(d, TodayDigestStore.parse(d.raw))
                } else if digest.busy {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(digest.waiting ? "等财新、三联的目录载入完…" : "正在通读今天的内容…").font(.callout).foregroundStyle(.secondary)
                    }
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "binoculars").font(.system(size: 34)).foregroundStyle(.tertiary)
                        Text("AI 会读一遍今天各来源的标题和导语，\n告诉你每个来源有什么、先读哪几篇、为什么。")
                            .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity).padding(.top, 60)
                }
            }
            .frame(maxWidth: 680, alignment: .leading)
            .padding(.horizontal, 36).padding(.vertical, 30)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: 头部：日期 + 各来源条数 + 生成按钮

    private var head: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Image(systemName: "binoculars").font(.system(size: 11, weight: .bold))
                    Text("AI 速览").font(.system(size: 11, weight: .bold)).tracking(1.6)
                }
                .foregroundStyle(Brand.orange)
                Text(Self.dateText).font(.system(size: 26, weight: .bold))
                Text(stats).font(.caption).foregroundStyle(.secondary)
                if let d = digest.digest, !digest.busy { Text("基于标题和导语 · 生成于 \(Self.clock(d.at))").font(.caption2).foregroundStyle(.tertiary) }
            }
            Spacer(minLength: 8)
            if digest.busy {
                Button { digest.stop() } label: { Label("停止", systemImage: "stop.circle") }.buttonStyle(.bordered)
            } else {
                Button { digest.generate(store: store) } label: {
                    Label(digest.digest == nil ? "生成" : "重新生成", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered).disabled(store.groups.isEmpty)
            }
        }
    }

    private var stats: String {
        let total = store.groups.reduce(0) { $0 + $1.entries.count }
        let parts = store.groups.map { "\($0.name) \($0.entries.count)" }
        return "共 \(total) 条 · " + parts.joined(separator: " · ") + (store.loading ? " · 还在载入…" : "")
    }

    private static var dateText: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M 月 d 日 EEEE"
        return f.string(from: Date())
    }

    private static func clock(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: d)
    }

    // MARK: 内容

    @ViewBuilder private func content(_ d: TodayDigest, _ p: ParsedDigest) -> some View {
        if !p.inventory.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                label("今天有什么")
                ForEach(Array(p.inventory.enumerated()), id: \.offset) { _, s in inventory(s) }
            }
        }
        let picks = p.picks.filter { $0.ref >= 1 && $0.ref <= d.ids.count }
        if !picks.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                label("先读这几篇")
                if !p.criterion.isEmpty {
                    Text("挑选依据：" + p.criterion).font(.system(size: 12.5)).foregroundStyle(.secondary).lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(picks.enumerated()), id: \.offset) { i, pk in pick(i + 1, pk, d) }
                }
                .padding(.horizontal, -10)
            }
        }
        if !p.scenes.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                label("按场景看")
                ForEach(Array(p.scenes.enumerated()), id: \.offset) { _, s in scene(s, d) }
            }
        }
        if !p.insights.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                label("洞察")
                ForEach(Array(p.insights.enumerated()), id: \.offset) { _, t in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: "lightbulb").font(.system(size: 12)).foregroundStyle(Brand.orange)
                        Text(t).font(.system(size: 14.5)).lineSpacing(5).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func label(_ t: String) -> some View {
        Text(t).font(.system(size: 11.5, weight: .bold)).tracking(1.4).foregroundStyle(.secondary)
    }

    private func icon(of name: String) -> String {
        store.groups.first { $0.name == name }?.icon ?? "doc.text"
    }

    /// 某个来源今天（本期）有什么
    private func inventory(_ s: ParsedDigest.Source) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: icon(of: s.name)).font(.system(size: 11)).frame(width: 14)
                Text(s.name).font(.system(size: 13, weight: .bold))
            }
            .foregroundStyle(Brand.orange)
            .frame(width: 92, alignment: .leading)
            Text(s.text).font(.system(size: 14)).lineSpacing(4).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }

    /// 必读：一行标题（右边是来源），下面两行紧凑的「讲了 / 先读」
    private func pick(_ rank: Int, _ pk: ParsedDigest.Pick, _ d: TodayDigest) -> some View {
        let src = (d.sources.flatMap { pk.ref - 1 < $0.count ? $0[pk.ref - 1] : nil }) ?? ""
        return DigestPickRow(rank: rank, title: d.titles[pk.ref - 1], source: src, what: pk.what, why: pk.why) { open(d.ids[pk.ref - 1]) }
    }

    /// 场景：左边场景名，右边具体内容和涉及的文章（最多列三篇）
    private func scene(_ s: ParsedDigest.Scene, _ d: TodayDigest) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(s.name).font(.system(size: 13, weight: .bold)).foregroundStyle(Brand.orange)
                .frame(width: 92, alignment: .leading)
            VStack(alignment: .leading, spacing: 6) {
                if !s.desc.isEmpty {
                    Text(s.desc).font(.system(size: 14)).lineSpacing(4).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
                let refs = Array(s.refs.filter { $0 >= 1 && $0 <= d.ids.count }.prefix(3))
                ForEach(refs, id: \.self) { n in
                    Button { open(d.ids[n - 1]) } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.turn.down.right").font(.system(size: 9)).foregroundStyle(.tertiary)
                            Text(d.titles[n - 1]).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            Spacer(minLength: 0)
        }
    }
}


private struct DigestPickRow: View {
    let rank: Int
    let title: String
    let source: String
    let what: String
    let why: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Text("\(rank)").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 20, height: 20).background(Brand.orange, in: Circle()).padding(.top, 1)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(title).font(.system(size: 14.5, weight: .semibold)).foregroundStyle(.primary)
                            .lineLimit(2).multilineTextAlignment(.leading)
                        Spacer(minLength: 6)
                        if !source.isEmpty { Text(source).font(.system(size: 11)).foregroundStyle(.tertiary).fixedSize() }
                    }
                    if !what.isEmpty {
                        Text(what).font(.system(size: 13)).lineSpacing(3).foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                    }
                    if !why.isEmpty {
                        // 同一段文字里：橙色「为何先读」+ 理由，随宽度自然换行
                        (Text("为何先读  ").font(.system(size: 12, weight: .bold)).foregroundColor(Brand.orange)
                            + Text(why).font(.system(size: 13)).foregroundColor(.primary))
                            .lineSpacing(3).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 9)
            .background(hover ? Color.primary.opacity(0.05) : Color.clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}
