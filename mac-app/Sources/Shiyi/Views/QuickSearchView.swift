import SwiftUI

/// 全能搜索结果的来源筛选
enum SearchFilter: String, CaseIterable, Identifiable {
    case all = "全部", sjz = "结审", note = "笔记", todo = "待办", daily = "日记"
    var id: String { rawValue }

    func matches(_ item: SearchItem) -> Bool {
        switch self {
        case .all: return true
        case .sjz: return item.source == .sjz
        case .note: return item.source == .note
        case .todo: return item.source == .todo
        case .daily: return item.source == .daily
        }
    }

    /// 输入框开头的快捷前缀：`ss` 搜全部，`sj` 结审，`sn` 笔记，`sd` 待办，`sr` 日记（另外「搜」「搜索」「查找」「?」也算搜全部）
    static let shortcuts: [(prefix: String, filter: SearchFilter)] = [
        ("ss", .all), ("sj", .sjz), ("sn", .note), ("sd", .todo), ("sr", .daily),
    ]
    private static let prefixRE = RX(#"^(ss|sj|sn|sd|sr|搜索|搜|查找|找|search|find)(?:\s*[:：]\s*|[\s　]+)|^[?？]\s*"#, multiline: false, ignoreCase: true)

    /// 开头是搜索前缀（后面要有空格或冒号）：返回对应的分类和去掉前缀后的文字
    static func parsePrefix(_ text: String) -> (filter: SearchFilter, rest: String)? {
        let t = String(text.drop(while: { $0.isWhitespace }))
        guard let m = prefixRE.first(in: t), m.range.location == 0 else { return nil }
        let word = m.group(1).lowercased()
        let f = shortcuts.first { $0.prefix == word }?.filter ?? .all
        return (f, (t as NSString).substring(from: m.range.length))
    }
}

extension SearchItem.Source {
    var tint: Color {
        switch self {
        case .sjz: return .indigo
        case .note: return Brand.orange
        case .todo: return .blue
        case .daily: return .teal
        }
    }
}

/// 万能输入框的搜索结果面板：来源筛选 + 结果列表（↑↓ 选择、↩ 打开、⌘↩ 在结审中打开）
struct QuickSearchResults: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var engine: UniversalSearch
    let query: String
    let visible: [SearchItem]
    @Binding var filter: SearchFilter
    @Binding var selection: Int
    var compact = false
    /// 「全部」里每个来源只列前几条，剩下的条数（提示去对应分类看）
    var hidden = 0
    var onOpen: (SearchItem, Bool) -> Void
    /// 列表实际排出来的高度（结果多了窗口跟着长；不量的话 ScrollView 没有自己的高度，会被压成一行）
    @State private var listH: CGFloat = 0

    private var terms: [String] { UniversalSearch.terms(query) }
    private var selectedIsSjz: Bool { visible.indices.contains(selection) && visible[selection].source == .sjz }

    /// 没连结审 / 闪念贝壳时，对应的分类不显示
    private func available(_ f: SearchFilter) -> Bool {
        switch f {
        case .sjz: return model.hasSjz
        case .note, .daily: return model.hasIdeashell
        default: return true
        }
    }

    private func count(_ f: SearchFilter) -> Int { engine.items.filter { f.matches($0) }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            controls
            if !engine.errors.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(SearchItem.Source.allCases.filter { engine.errors[$0] != nil }, id: \.self) { s in
                        Label("\(s.rawValue)：\(engine.errors[s] ?? "")", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption2).foregroundStyle(.orange).lineLimit(2)
                    }
                }
            }
            if visible.isEmpty {
                emptyState
            } else {
                list
                HStack(spacing: 8) {
                    Text(selectedIsSjz ? "↑↓ 选择 · ↩ 打开 · ⌘↩ 在结审中打开" : "↑↓ 选择 · ↩ 打开")
                        .foregroundStyle(.tertiary)
                    if hidden > 0 { Text("另有 \(hidden) 条，点上面的分类查看").foregroundStyle(.tertiary) }
                }
                .font(.caption2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    // MARK: 控制行

    private var controls: some View {
        HStack(spacing: 5) {
            ForEach(SearchFilter.allCases.filter(available)) { f in
                let n = count(f)
                Button { filter = f; selection = 0 } label: {
                    HStack(spacing: 3) {
                        Text(f.rawValue)
                        if n > 0 { Text("\(n)").foregroundStyle(.tertiary) }
                    }
                    .font(.caption.weight(filter == f ? .semibold : .regular))
                    .lineLimit(1).fixedSize()
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(filter == f ? Brand.orange.opacity(0.16) : Color.primary.opacity(0.05), in: Capsule())
                    .foregroundStyle(filter == f ? Brand.orangeDeep : Color.secondary)
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private var emptyState: some View {
        if query.isEmpty {
            Text("前缀直达：ss 全部 · sj 结审 · sn 笔记 · sd 待办 · sr 日记")
                .font(.caption2).foregroundStyle(.tertiary)
                .padding(.vertical, 4)
        } else if !engine.loading.isEmpty || engine.searchedQuery != query {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(engine.loading.isEmpty ? "搜索中…" : "正在搜索 " + engine.loading.map(\.rawValue).sorted().joined(separator: "、") + "…")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.vertical, 6)
        } else {
            Text("没有找到「\(query)」相关的内容")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.vertical, 6)
        }
    }

    // MARK: 列表

    private static let maxListHeight: CGFloat = 320

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(spacing: 2) {
                    ForEach(Array(visible.enumerated()), id: \.element.id) { i, item in
                        row(item, selected: i == selection)
                            .id(item.id)
                            .onTapGesture { selection = i; onOpen(item, false) }
                    }
                    if !engine.loading.isEmpty {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            Text("还在搜索 " + engine.loading.map(\.rawValue).sorted().joined(separator: "、") + "…").font(.caption2).foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 4)
                    }
                }
                .background(GeometryReader { g in Color.clear.preference(key: SearchListHeightKey.self, value: g.size.height) })
            }
            .scrollIndicators(.hidden)
            // 没量出来之前按每行约 40 估一个，免得先压成一行再弹开
            .frame(height: min(listH > 0 ? listH : CGFloat(visible.count) * 40, Self.maxListHeight))
            .onPreferenceChange(SearchListHeightKey.self) { h in if h > 0, abs(h - listH) > 0.5 { listH = h } }
            .onChange(of: selection) { _, new in
                guard visible.indices.contains(new) else { return }
                proxy.scrollTo(visible[new].id)
            }
        }
    }

    private func row(_ item: SearchItem, selected: Bool) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: item.icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(item.source.tint)
                .frame(width: 22, height: 22)
                .background(item.source.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(highlighted(item.title)).font(.system(size: 12.5, weight: .medium)).lineLimit(1).truncationMode(.tail)
                if !item.snippet.isEmpty {
                    Text(highlighted(item.snippet)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                }
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 2) {
                Text(item.kindLabel).font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 6).padding(.vertical, 1.5)
                    .background(item.source.tint.opacity(0.12), in: Capsule())
                    .foregroundStyle(item.source.tint)
                if !item.context.isEmpty {
                    Text(item.context).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.tail).frame(maxWidth: 80, alignment: .trailing)
                }
            }
        }
        .padding(.horizontal, 7).padding(.vertical, 4)
        .background(selected ? Brand.orange.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
    }

    /// 关键词高亮
    private func highlighted(_ s: String) -> AttributedString {
        var a = AttributedString(s)
        for t in terms {
            var from = a.startIndex
            while from < a.endIndex, let r = a[from...].range(of: t, options: .caseInsensitive) {
                a[r].foregroundColor = Brand.orangeDeep
                a[r].inlinePresentationIntent = .stronglyEmphasized
                from = r.upperBound
            }
        }
        return a
    }
}

private struct SearchListHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
