import SwiftUI

/// 阅读：《财新周刊》。左边是期号和目录（公开页面），右边是内嵌浏览器——用你自己的财新账号登录后读全文，并按阅读样式重排版。
struct ReadingView: View {
    @ObservedObject private var store = WeeklyStore.shared
    @ObservedObject private var reader = ReaderController.shared
    @State private var selected: String?

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 292)
            Divider()
            detail
        }
        .background(AmbientBackground())
        .task {
            await store.loadIfNeeded()
            await reader.refreshLogin()
        }
    }

    // MARK: 左：期号 + 目录

    private var sidebar: some View {
        VStack(spacing: 0) {
            issueHeader
                .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 10)
            Divider()
            if let e = store.error, store.sections.isEmpty {
                VStack(spacing: 10) {
                    Text(e).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("重试") { Task { await store.reload() } }
                }
                .padding(20).frame(maxHeight: .infinity)
            } else if store.sections.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(store.sections) { s in
                            Text(s.name).font(.caption.weight(.bold)).foregroundStyle(Brand.orange)
                                .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 4)
                            ForEach(s.articles) { a in row(a) }
                        }
                    }
                    .padding(.horizontal, 4).padding(.bottom, 12)
                }
            }
            Divider()
            account.padding(.horizontal, 14).padding(.vertical, 9)
        }
    }

    private var issueHeader: some View {
        HStack(spacing: 10) {
            AsyncImage(url: store.current?.cover) { img in
                img.resizable().scaledToFill()
            } placeholder: {
                Color.primary.opacity(0.06)
            }
            .frame(width: 42, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))

            VStack(alignment: .leading, spacing: 3) {
                Menu {
                    ForEach(store.issues.prefix(40)) { i in
                        Button {
                            Task { await store.select(i) }
                        } label: {
                            Text((i.no == store.current?.no ? "✓ " : "") + i.label + "　" + i.title)
                        }
                    }
                } label: {
                    HStack(spacing: 3) {
                        Text(store.current?.label ?? "财新周刊").font(.system(size: 14, weight: .bold))
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
                    }
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                Text(store.current?.title ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 0)
            Button { Task { await store.reload() } } label: {
                if store.loading { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") }
            }
            .buttonStyle(.plain).foregroundStyle(.secondary).help("刷新目录").disabled(store.loading)
        }
    }

    private func row(_ a: WeeklyArticle) -> some View {
        let on = selected == a.id
        let done = store.isRead(a)
        return Button { open(a) } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(a.title).font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(done && !on ? Color.secondary : Color.primary).lineLimit(2)
                if !a.summary.isEmpty {
                    Text(a.summary).font(.caption).foregroundStyle(.tertiary).lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(on ? Brand.orange.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var account: some View {
        HStack(spacing: 6) {
            Circle().fill(reader.loggedIn ? Color.green : Color.secondary.opacity(0.5)).frame(width: 7, height: 7)
            Text(reader.loggedIn ? "已登录财新" : "未登录财新").font(.caption).foregroundStyle(.secondary)
            Spacer()
            if reader.loggedIn {
                Button("退出") { Task { await reader.logout() } }.buttonStyle(.link).font(.caption)
            } else {
                Button("登录") { reader.openLogin(back: URL(string: "https://weekly.caixin.com/")) }.buttonStyle(.link).font(.caption)
            }
        }
    }

    private func open(_ a: WeeklyArticle) {
        selected = a.id
        store.markRead(a)
        reader.open(a.url)
    }

    // MARK: 右：阅读

    @ViewBuilder private var detail: some View {
        if reader.url == nil {
            VStack(spacing: 10) {
                Image(systemName: "newspaper").font(.system(size: 38)).foregroundStyle(.tertiary)
                Text("选一篇文章开始阅读").font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                toolbar
                Divider()
                if reader.article && reader.locked { lockedBanner; Divider() }
                ReaderWebView(controller: reader)
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 4) {
            if reader.canGoBack {
                tool("chevron.left", "返回") { reader.goBack() }
            }
            if reader.loading { ProgressView().controlSize(.small).padding(.leading, 4) }
            Spacer(minLength: 8)
            if reader.article {
                tool("textformat.size.smaller", "字号减小") { reader.size = max(reader.size - 1, 14) }
                tool("textformat.size.larger", "字号增大") { reader.size = min(reader.size + 1, 30) }
                Menu {
                    Picker("外观", selection: $reader.theme) {
                        Text("纸张").tag("paper")
                        Text("白色").tag("white")
                        Text("深色").tag("dark")
                    }
                    .pickerStyle(.inline)
                } label: {
                    Image(systemName: "circle.lefthalf.filled").font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary).frame(width: 28, height: 26).contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("阅读外观")
                tool("note.text.badge.plus", "把选中的文字摘到便签（带出处）") { Task { await reader.clipSelectionToSticky() } }
            }
            tool("safari", "在浏览器中打开") { reader.openInBrowser() }
        }
        .padding(.horizontal, 10).frame(height: 36)
    }

    private func tool(_ icon: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary).frame(width: 28, height: 26).contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(help)
    }

    private var lockedBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.fill").foregroundStyle(Brand.orange)
            Text(reader.loggedIn ? "只显示了预览：这个账号没有《财新周刊》阅读权限，或登录已过期" : "只显示了预览：登录有《财新周刊》权限的账号后可读全文")
                .font(.callout).foregroundStyle(.secondary)
            Spacer(minLength: 6)
            Button(reader.loggedIn ? "重新登录" : "登录") { reader.openLogin() }
                .buttonStyle(.bordered).controlSize(.small)
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
        .background(Brand.orange.opacity(0.08))
    }
}
