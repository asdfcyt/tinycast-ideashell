import AppKit
import SwiftUI

// MARK: - 侧栏：今日信息（AI 速览）

/// 「信息」页的 AI 速览摘要：今天还没读的「先读」前几篇（带为什么先读）+ 一条洞察；点标题直接去读，点卡片头进完整速览。
/// 今天还没有速览就引导生成（昨天的算过期）。
struct InfoCard: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var store = TodayStore.shared
    @ObservedObject private var digest = TodayDigestStore.shared
    @ObservedObject private var marks = ArticleMarks.shared
    @ObservedObject private var feeds = FeedStore.shared

    private struct Row: Identifiable {
        let id: String
        let title: String
        let source: String
        let why: String
        let link: String?
    }

    private func link(_ e: TodayEntry) -> String? {
        e.kind == .rss ? feeds.item(e.raw)?.link : e.raw
    }

    private var fresh: TodayDigest? {
        guard let d = digest.digest, d.day == Day.today() else { return nil }
        return d
    }

    /// 速览里还没读的「先读」，最多 3 篇
    private func rows(_ d: TodayDigest, _ p: ParsedDigest) -> [Row] {
        let entries = store.groups.flatMap(\.entries)
        var out: [Row] = []
        for pk in p.picks where pk.ref >= 1 && pk.ref <= d.ids.count {
            guard let e = entries.first(where: { $0.id == d.ids[pk.ref - 1] }), !store.isRead(e), !out.contains(where: { $0.id == e.id }) else { continue }
            out.append(Row(id: e.id, title: e.title, source: d.sources.flatMap { pk.ref - 1 < $0.count ? $0[pk.ref - 1] : nil } ?? "", why: pk.why, link: link(e)))
            if out.count == 3 { break }
        }
        return out
    }

    private func goReading() {
        UserDefaults.standard.set(ReadingSource.today.rawValue, forKey: "reader.source")
        model.section = .reading
    }

    private func generate() {
        goReading()
        digest.generate(store: store)
    }

    private static func when(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "HH:mm"
        let t = f.string(from: d)
        if Calendar.current.isDateInToday(d) { return "今天 " + t }
        if Calendar.current.isDateInYesterday(d) { return "昨天 " + t }
        f.dateFormat = "M 月 d 日"
        return f.string(from: d)
    }

    var body: some View {
        let parsed = digest.digest.map { TodayDigestStore.parse($0.raw) }
        Panel {
            VStack(alignment: .leading, spacing: 12) {
                header
                if store.groups.isEmpty {
                    Text(store.loading ? "正在载入今天的内容…" : "今天还没有内容").font(.callout).foregroundStyle(.secondary)
                } else if let d = fresh, let p = parsed {
                    content(d, p)
                } else if digest.busy {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(digest.waiting ? "等财新周刊、三联周刊的目录载入完…" : "AI 正在通读今天未读的内容…").font(.callout).foregroundStyle(.secondary)
                    }
                } else {
                    empty
                }
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 16)
        }
        .task { await store.loadIfNeeded() }
    }

    private var header: some View {
        Button(action: goReading) {
            HStack(spacing: 6) {
                Image(systemName: "binoculars.fill").foregroundStyle(Brand.orange)
                Text("AI 速览").foregroundStyle(Brand.orange)
                if store.totalUnread > 0 {
                    Text("未读 \(store.totalUnread)").font(.caption2.weight(.bold)).foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 1).background(Brand.orange, in: Capsule())
                }
                Spacer(minLength: 6)
                if let d = fresh, !digest.busy { Text(Self.when(d.at)).font(.caption).foregroundStyle(.tertiary) }
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(.tertiary)
            }
            .font(.subheadline.weight(.semibold))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 还没有今天的速览：说明它能做什么，一键生成
    private var empty: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(digest.digest != nil ? "上次的速览是 \(Self.when(digest.digest!.at)) 生成的，已经过期。" : "AI 会读一遍今天未读内容的标题和导语，告诉你各来源有什么、先读哪几篇、为什么，再给出洞察。")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("今天共 \(store.groups.reduce(0) { $0 + $1.entries.count }) 条，未读 \(store.totalUnread) 条")
                .font(.caption).foregroundStyle(.tertiary)
            Button(action: generate) {
                Label(digest.digest != nil ? "重新生成今天的速览" : "生成今天的 AI 速览", systemImage: "binoculars").font(.callout.weight(.semibold))
            }
            .buttonStyle(GlassActionStyle(tint: Brand.orange))
        }
    }

    @ViewBuilder private func content(_ d: TodayDigest, _ p: ParsedDigest) -> some View {
        let list = rows(d, p)
        VStack(alignment: .leading, spacing: 12) {
            if !p.criterion.isEmpty || !list.isEmpty {
                Text("先读这几篇").font(.system(size: 11, weight: .bold)).tracking(1.2).foregroundStyle(.secondary)
            }
            if list.isEmpty {
                Label(p.picks.isEmpty ? "还在生成…" : "速览里挑的几篇你都读完了", systemImage: p.picks.isEmpty ? "ellipsis" : "checkmark.circle")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(list.enumerated()), id: \.element.id) { i, row in
                        Button {
                            if let l = row.link { model.openArticle(l) } else { goReading() }
                        } label: {
                            HStack(alignment: .top, spacing: 9) {
                                Text("\(i + 1)").font(.system(size: 10.5, weight: .bold)).foregroundStyle(.white)
                                    .frame(width: 17, height: 17).background(Brand.orange, in: Circle()).padding(.top, 1)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(row.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.primary)
                                        .lineLimit(2).multilineTextAlignment(.leading)
                                    if !row.why.isEmpty {
                                        Text(row.why).font(.caption).foregroundStyle(Brand.orange).lineLimit(2).multilineTextAlignment(.leading)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if let t = p.insights.first {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Image(systemName: "lightbulb").font(.system(size: 11)).foregroundStyle(Brand.orange).frame(width: 14)
                    Text(t).font(.caption).foregroundStyle(.primary.opacity(0.85)).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 10) {
                Button(action: goReading) { Text("查看完整速览").font(.caption.weight(.semibold)) }.buttonStyle(.link)
                Spacer(minLength: 0)
                if digest.busy {
                    HStack(spacing: 5) { ProgressView().controlSize(.mini); Text("生成中…").font(.caption).foregroundStyle(.secondary) }
                } else {
                    Button(action: generate) { Label("重新生成", systemImage: "arrow.clockwise").font(.caption) }.buttonStyle(.link)
                }
            }
        }
    }
}
