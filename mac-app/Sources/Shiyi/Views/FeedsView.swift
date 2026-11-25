import AppKit
import SwiftUI

/// 左：订阅文章列表（顶部菜单切换：全部未读 / 星标 / 某个订阅源）
struct FeedsSidebar: View {
    @ObservedObject var store: FeedStore
    @Binding var pick: String?
    @Binding var showAdd: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 14).padding(.vertical, 12)
            Divider()
            if store.sources.isEmpty {
                empty
            } else {
                let list = store.visible(store.selection)
                if list.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "tray").font(.system(size: 28)).foregroundStyle(.tertiary)
                        Text(store.selection == .unread ? "没有未读文章了" : "这里还没有文章").font(.callout).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(list.prefix(300)) { row($0) }
                        }
                        .padding(.horizontal, 4).padding(.vertical, 8)
                    }
                }
            }
            Divider()
            footer.padding(.horizontal, 14).padding(.vertical, 8)
        }
    }

    // MARK: 顶部：当前范围 + 刷新

    private var header: some View {
        HStack(spacing: 8) {
            Menu {
                Button { store.selection = .unread } label: { Text(mark(.unread) + "全部未读　\(store.unread(.unread))") }
                Button { store.selection = .starred } label: { Text(mark(.starred) + "星标　\(store.unread(.starred))") }
                if !store.sources.isEmpty { Divider() }
                ForEach(store.sources) { s in
                    Button { store.selection = .feed(s.id) } label: {
                        Text(mark(.feed(s.id)) + s.title + (s.error != nil ? "　⚠︎" : "") + "　\(store.unread(.feed(s.id)))")
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(store.title(of: store.selection)).font(.system(size: 14, weight: .bold)).lineLimit(1)
                    let n = store.unread(store.selection == .starred ? .starred : store.selection)
                    if n > 0 {
                        Text("\(n)").font(.caption2.weight(.bold)).foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 1).background(Brand.orange, in: Capsule())
                    }
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
                }
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            Spacer(minLength: 0)
            Button { Task { await store.refreshAll() } } label: {
                if store.refreshing { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") }
            }
            .buttonStyle(.plain).foregroundStyle(.secondary).help("刷新全部订阅").disabled(store.refreshing || store.sources.isEmpty)
        }
    }

    private func mark(_ s: FeedSel) -> String { store.selection == s ? "✓ " : "" }

    // MARK: 空状态

    private var empty: some View {
        VStack(spacing: 12) {
            Image(systemName: "antenna.radiowaves.left.and.right").font(.system(size: 30)).foregroundStyle(.tertiary)
            Text("还没有订阅").font(.callout.weight(.medium))
            Text("粘贴网站或订阅源的地址，或从下面挑几个开始").font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            VStack(spacing: 6) {
                ForEach(FeedStore.presets) { p in
                    Button { Task { _ = try? await store.add(p.url) } } label: {
                        Label(p.title, systemImage: "plus.circle").frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                }
            }
            .padding(.horizontal, 18)
            Button("添加订阅…") { showAdd = true }.buttonStyle(.borderedProminent).controlSize(.small).tint(Brand.orange)
        }
        .padding(.vertical, 20).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 文章行

    private func row(_ it: FeedItem) -> some View {
        let on = pick == it.id
        return Button { pick = it.id } label: {
            HStack(alignment: .top, spacing: 7) {
                Circle().fill(it.read ? Color.clear : Brand.orange).frame(width: 7, height: 7).padding(.top, 6)
                VStack(alignment: .leading, spacing: 3) {
                    Text(it.title).font(.system(size: 13.5, weight: it.read ? .regular : .semibold))
                        .foregroundStyle(it.read && !on ? Color.secondary : Color.primary).lineLimit(2)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: 4) {
                        if it.starred { Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(.yellow) }
                        Text([store.source(it.feed)?.title ?? "", FeedFormat.relative(it.date)].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8).padding(.vertical, 7)
            .background(on ? Brand.orange.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(it.read ? "标为未读" : "标为已读") { store.setRead(it.id, !it.read) }
            Button(it.starred ? "取消星标" : "加星标") { store.toggleStar(it.id) }
            if let u = URL(string: it.link) { Button("在浏览器中打开") { NSWorkspace.shared.open(u) } }
        }
    }

    // MARK: 底部：添加 / 全部已读 / 更多

    private var footer: some View {
        HStack(spacing: 10) {
            Button { showAdd = true } label: { Label("添加订阅", systemImage: "plus") }
                .buttonStyle(.link).font(.caption)
            Spacer(minLength: 4)
            Button("全部已读") { store.markAllRead(store.selection) }
                .buttonStyle(.link).font(.caption).disabled(store.unread(store.selection) == 0)
            Menu {
                if case .feed(let id) = store.selection {
                    Button("刷新这个订阅") { Task { await store.refresh(id) } }
                    if let s = store.source(id), let err = s.error { Text("上次失败：" + err) }
                    Button("退订「\(store.title(of: store.selection))」", role: .destructive) { store.remove(id) }
                    Divider()
                }
                Button("导入 OPML…") { FeedFiles.importOPML(store) }
                Button("导出 OPML…") { FeedFiles.exportOPML(store) }.disabled(store.sources.isEmpty)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("更多")
        }
    }
}

/// 右：文章卡片（标题 / 来源 / 摘要）；全文点「阅读原文」在内置浏览器里打开并重排
struct FeedDetail: View {
    @ObservedObject var store: FeedStore
    let itemID: String?
    let open: (URL) -> Void

    var body: some View {
        if let it = store.item(itemID) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text([store.source(it.feed)?.title ?? "", FeedFormat.full(it.date)].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption.weight(.bold)).foregroundStyle(Brand.orange)
                    Text(it.title).font(.system(size: 24, weight: .bold)).fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    if !it.summary.isEmpty {
                        Text(it.summary).font(.system(size: 15.5)).foregroundStyle(.secondary).lineSpacing(6)
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    } else {
                        Text("这条订阅没有带摘要，点「阅读原文」查看。").font(.callout).foregroundStyle(.tertiary)
                    }
                    HStack(spacing: 10) {
                        if let u = URL(string: it.link) {
                            Button { open(u) } label: { Label("阅读原文", systemImage: "doc.text") }
                                .buttonStyle(.borderedProminent).tint(Brand.orange)
                            Button { NSWorkspace.shared.open(u) } label: { Label("浏览器打开", systemImage: "safari") }
                                .buttonStyle(.bordered)
                        }
                        Button { store.toggleStar(it.id) } label: {
                            Label(it.starred ? "取消星标" : "星标", systemImage: it.starred ? "star.fill" : "star")
                        }
                        .buttonStyle(.bordered)
                        Button { clip(it) } label: { Label("摘到便签", systemImage: "note.text.badge.plus") }
                            .buttonStyle(.bordered)
                    }
                    .padding(.top, 4)
                }
                .frame(maxWidth: 720, alignment: .leading)
                .padding(.horizontal, 32).padding(.vertical, 28)
                .frame(maxWidth: .infinity)
            }
        } else {
            VStack(spacing: 10) {
                Image(systemName: "antenna.radiowaves.left.and.right").font(.system(size: 38)).foregroundStyle(.tertiary)
                Text(store.sources.isEmpty ? "添加订阅后在这里阅读" : "从左边选一篇文章").font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func clip(_ it: FeedItem) {
        var text = "**" + it.title + "**"
        if !it.summary.isEmpty { text += "\n\n> " + it.summary.replacingOccurrences(of: "\n", with: "\n> ") }
        if !it.link.isEmpty { text += "\n\n[\(store.source(it.feed)?.title ?? "原文")](\(it.link))" }
        StickyController.shared.create(text: text)
    }
}

/// 添加订阅：粘贴网址（网站首页也行，会自动找订阅源）
struct AddFeedSheet: View {
    @ObservedObject var store: FeedStore
    let onClose: () -> Void
    @State private var text = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("添加订阅").font(.headline)
            TextField("网站或订阅源地址，例如 sspai.com", text: $text)
                .textFieldStyle(.roundedBorder)
                .onSubmit { submit() }
            if let e = error { Text(e).font(.caption).foregroundStyle(.red) }
            Text("也可以直接粘贴 RSS / Atom 地址；网站首页会自动查找它的订阅源。").font(.caption).foregroundStyle(.secondary)
            Divider()
            Text("推荐").font(.caption.weight(.bold)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(FeedStore.presets) { p in
                    let added = store.sources.contains { $0.url == p.url }
                    HStack {
                        Text(p.title).font(.callout)
                        Spacer()
                        if added {
                            Text("已订阅").font(.caption).foregroundStyle(.tertiary)
                        } else {
                            Button("添加") { Task { await add(p.url, close: false) } }.buttonStyle(.link).font(.caption)
                        }
                    }
                }
            }
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("完成") { onClose() }.keyboardShortcut(.cancelAction)
                Button("添加") { submit() }.keyboardShortcut(.defaultAction)
                    .disabled(busy || text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20).frame(width: 420)
    }

    private func submit() { Task { await add(text, close: true) } }

    private func add(_ s: String, close: Bool) async {
        busy = true
        error = nil
        defer { busy = false }
        do {
            _ = try await store.add(s)
            if close { onClose() } else { text = "" }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

enum FeedFiles {
    @MainActor static func importOPML(_ store: FeedStore) {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.xml, .data]
        p.message = "选一个 OPML 文件，导入其中的订阅源"
        guard p.runModal() == .OK, let u = p.url, let d = try? Data(contentsOf: u) else { return }
        Task {
            let n = await store.importOPML(d)
            AppModel.current?.showNotice(n > 0 ? "已导入 \(n) 个订阅源" : "没有可导入的新订阅源")
        }
    }

    @MainActor static func exportOPML(_ store: FeedStore) {
        let p = NSSavePanel()
        p.nameFieldStringValue = "拾忆订阅.opml"
        guard p.runModal() == .OK, let u = p.url else { return }
        try? store.exportOPML().write(to: u, atomically: true, encoding: .utf8)
        AppModel.current?.showNotice("已导出订阅源")
    }
}

enum FeedFormat {
    static func relative(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.unitsStyle = .short
        return f.localizedString(for: d, relativeTo: Date())
    }

    static func full(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: d)
    }
}
