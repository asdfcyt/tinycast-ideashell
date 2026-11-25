import SwiftUI

/// AIHOT 的两个页签：日报 / 精选
enum AIHotTab: String { case daily, picks }

/// 左：AIHOT 的日报日期 / 一周精选列表
struct AIHotSidebar: View {
    @ObservedObject var store: AIHotStore
    @Binding var tab: AIHotTab
    @Binding var pick: AIHotItem?
    @ObservedObject private var marks = ArticleMarks.shared

    var body: some View {
        VStack(spacing: 0) {
            if let e = store.error, store.entries.isEmpty {
                VStack(spacing: 10) {
                    Text(e).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("重试") { Task { await store.reload() } }
                }
                .padding(20).frame(maxHeight: .infinity)
            } else if store.entries.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if tab == .daily {
                            ForEach(store.entries) { e in dailyRow(e) }
                        } else {
                            ForEach(store.picks) { p in pickRow(p) }
                        }
                    }
                    .padding(.horizontal, 4).padding(.vertical, 8)
                }
            }
            HStack(spacing: 8) {
                Link("AIHOT", destination: URL(string: "https://aihot.news")!).font(.caption).help("数据来源：AIHOT")
                Spacer(minLength: 4)
                Picker("", selection: $tab) {
                    Text("AI 日报").tag(AIHotTab.daily)
                    Text("本周精选").tag(AIHotTab.picks)
                }
                .pickerStyle(.segmented).labelsHidden().controlSize(.small).frame(width: 150)
                Button { Task { await store.reload() } } label: {
                    if store.loading { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") }
                }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("刷新").disabled(store.loading)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
        }
    }

    private func dailyRow(_ e: AIHotEntry) -> some View {
        let on = store.date == e.date
        return Button { Task { await store.select(e.date) } } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(AIHotFormat.dayTitle(e.date)).font(.caption.weight(.bold)).foregroundStyle(Brand.orange)
                Text(e.leadTitle).font(.system(size: 13.5, weight: .medium)).lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(on ? Brand.orange.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func pickRow(_ p: AIHotItem) -> some View {
        let on = pick?.id == p.id
        let done = marks.isRead(p.aihot ?? p.original)
        return Button { pick = p } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(p.title).font(.system(size: 13.5, weight: .medium)).lineLimit(2)
                    .foregroundStyle(done && !on ? Color.secondary : Color.primary)
                Text([p.category, p.source, AIHotFormat.time(p.published)].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.tertiary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(on ? Brand.orange.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let u = p.aihot ?? p.original { ArticleMenu(title: p.title, link: u.absoluteString, summary: p.summary) }
        }
    }
}

/// 右：日报正文 / 单条精选。原文在内嵌浏览器里打开（`open`）
struct AIHotDetail: View {
    @ObservedObject var store: AIHotStore
    let tab: AIHotTab
    let pick: AIHotItem?
    let open: (URL) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if tab == .picks {
                    if let p = pick {
                        card(p, large: true)
                    } else {
                        placeholder("从左边选一条精选")
                    }
                } else if let d = store.daily {
                    daily(d)
                } else if store.error != nil {
                    placeholder(store.error ?? "")
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 80)
                }
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(.horizontal, 32).padding(.vertical, 28)
            .frame(maxWidth: .infinity)
        }
    }

    private func placeholder(_ t: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkles.rectangle.stack").font(.system(size: 38)).foregroundStyle(.tertiary)
            Text(t).font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity).padding(.top, 100)
    }

    @ViewBuilder private func daily(_ d: AIHotDaily) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(AIHotFormat.dayTitle(d.date)).font(.caption.weight(.bold)).foregroundStyle(Brand.orange)
            Text(d.leadTitle).font(.system(size: 24, weight: .bold)).fixedSize(horizontal: false, vertical: true)
            Text(d.leadParagraph).font(.system(size: 15)).foregroundStyle(.secondary).lineSpacing(5)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 14) {
                if let l = d.link {
                    Button { open(l) } label: { Label("在 AIHOT 阅读", systemImage: "arrow.up.right.square") }
                        .buttonStyle(.link).font(.caption)
                }
                Button { clipDaily(d) } label: { Label("整期摘到便签", systemImage: "note.text.badge.plus") }
                    .buttonStyle(.link).font(.caption)
            }
            .padding(.top, 2)
        }
        if !d.highlights.isEmpty {
            header("今日重点")
            ForEach(d.highlights) { card($0, large: false) }
        }
        ForEach(d.sections) { s in
            header(s.label)
            ForEach(s.items) { card($0, large: false) }
        }
        if !d.flashes.isEmpty {
            header("快讯")
            VStack(alignment: .leading, spacing: 0) {
                ForEach(d.flashes) { f in
                    Button { if let u = f.aihot ?? f.original { open(u) } } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("·").foregroundStyle(Brand.orange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(f.title).font(.system(size: 13.5)).multilineTextAlignment(.leading)
                                Text([f.source, AIHotFormat.time(f.published)].filter { !$0.isEmpty }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.tertiary)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 6).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        if let u = f.aihot ?? f.original { ArticleMenu(title: f.title, link: u.absoluteString, summary: f.summary) }
                    }
                }
            }
        }
    }

    private func header(_ t: String) -> some View {
        Text(t).font(.system(size: 15, weight: .bold)).padding(.top, 8)
    }

    private func card(_ i: AIHotItem, large: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // 点标题 / 摘要：直接进 AIHOT 的阅读详情页
            Button { if let u = i.aihot ?? i.original { open(u) } } label: {
                VStack(alignment: .leading, spacing: 8) {
                    Text(i.title).font(.system(size: large ? 21 : 15.5, weight: .semibold)).foregroundStyle(.primary)
                        .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                    if !i.summary.isEmpty {
                        Text(i.summary).font(.system(size: large ? 15 : 13.5)).foregroundStyle(.secondary).lineSpacing(4)
                            .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                    }
                    if large, !i.reason.isEmpty {
                        Text("推荐理由：" + i.reason).font(.system(size: 13.5)).foregroundStyle(.secondary).lineSpacing(4)
                            .multilineTextAlignment(.leading)
                            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Brand.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("阅读详情")
            HStack(spacing: 12) {
                Text([i.category, i.source, AIHotFormat.time(i.published)].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                Spacer(minLength: 6)
                if let u = i.original { Button("原文") { open(u) }.buttonStyle(.link).font(.caption) }
                Button("摘到便签") { clip(i) }.buttonStyle(.link).font(.caption)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5))
        .contextMenu {
            if let u = i.aihot ?? i.original { ArticleMenu(title: i.title, link: u.absoluteString, summary: i.summary) }
        }
    }

    private func clip(_ i: AIHotItem) {
        var text = "**" + i.title + "**"
        if !i.summary.isEmpty { text += "\n\n> " + i.summary }
        if let u = i.original ?? i.aihot { text += "\n\n[\(i.source.isEmpty ? "原文" : i.source)](\(u.absoluteString))" }
        StickyController.shared.create(text: text)
    }

    private func clipDaily(_ d: AIHotDaily) {
        var text = "**AI 日报 \(d.date)｜\(d.leadTitle)**\n\n> \(d.leadParagraph)"
        for s in d.sections {
            text += "\n\n**\(s.label)**"
            for i in s.items { text += "\n- " + i.title }
        }
        if let l = d.link { text += "\n\n[数据来源：AIHOT](\(l.absoluteString))" }
        StickyController.shared.create(text: text)
    }
}

enum AIHotFormat {
    /// 2026-11-25 → 11 月 25 日 · 周三
    static func dayTitle(_ s: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy-MM-dd"
        guard let d = f.date(from: s) else { return s }
        f.dateFormat = "M 月 d 日 · EEE"
        return f.string(from: d)
    }

    static func time(_ d: Date?) -> String {
        guard let d else { return "" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "MM-dd HH:mm"
        return f.string(from: d)
    }
}
