import AppKit
import SwiftUI

// MARK: - 通用小组件

struct TagChip: View {
    let text: String
    var tint: Color = Brand.orange

    var body: some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.12), in: Capsule())
            .foregroundStyle(tint)
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard(radius: 16)
    }
}

struct StatTile: View {
    let value: String
    let label: String
    var tint: Color = .primary
    /// 有值时用「数字大、单位小」的单行时长样式（9 时 56 分），避免窄卡里折行
    var minutes: Int?

    init(value: String, label: String, tint: Color = .primary) {
        self.value = value; self.label = label; self.tint = tint; self.minutes = nil
    }

    init(minutes: Int, label: String, tint: Color = .primary) {
        self.value = ""; self.label = label; self.tint = tint; self.minutes = minutes
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Group {
                if let m = minutes { durationText(m) } else { Text(value).font(.system(size: 28, weight: .semibold, design: .rounded)) }
            }
            .foregroundStyle(tint)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(radius: 16)
    }

    private func durationText(_ m: Int) -> Text {
        let big = Font.system(size: 28, weight: .semibold, design: .rounded)
        let unit = Font.system(size: 13, weight: .medium, design: .rounded)
        func num(_ n: Int) -> Text { Text("\(n)").font(big) }
        func u(_ t: String) -> Text { Text(t).font(unit) }
        if m < 60 { return num(m) + u(" 分钟") }
        if m % 60 == 0 { return num(m / 60) + u(" 小时") }
        return num(m / 60) + u(" 小时 ") + num(m % 60) + u(" 分")
    }
}

struct ErrorBanner: View {
    let text: String
    var onRetry: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(text).font(.callout).lineLimit(3).textSelection(.enabled)
            Spacer(minLength: 0)
            if let onRetry { Button("重试", action: onRetry).buttonStyle(.link) }
        }
        .padding(10)
        .glassCard(radius: 12, tint: .orange.opacity(0.25))
    }
}

struct EmptyHint: View {
    let icon: String
    let title: String
    var detail: String?

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 34)).foregroundStyle(.tertiary)
            Text(title).font(.headline).foregroundStyle(.secondary)
            if let detail { Text(detail).font(.callout).foregroundStyle(.tertiary).multilineTextAlignment(.center) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
    }
}

struct SectionTitle: View {
    let text: String
    var count: Int?
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 6) {
            Text(text).font(.headline).foregroundStyle(tint)
            if let count { Text("\(count)").font(.subheadline).foregroundStyle(.tertiary) }
        }
    }
}

// MARK: - 笔记行

struct NoteRow: View {
    let note: NoteInfo
    var showDay = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(note.title).font(.body.weight(.medium)).lineLimit(1)
                Spacer(minLength: 4)
                Text(timeText).font(.caption).foregroundStyle(.tertiary).monospacedDigit()
            }
            if let s = note.summary {
                Text(s).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            }
            if !note.tags.isEmpty {
                HStack(spacing: 4) {
                    ForEach(note.tags.prefix(5), id: \.self) { TagChip(text: "#" + $0.trimmingCharacters(in: CharacterSet(charactersIn: "#"))) }
                }
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }

    private var timeText: String {
        if showDay, let d = note.day { return Day.label(d) + " " + (note.clock ?? "") }
        return note.clock ?? ""
    }
}

// MARK: - 待办行

struct TaskRow: View {
    @EnvironmentObject var model: AppModel
    let task: DidaTask
    var overdue = false
    var showDate = false
    var showProject = true
    /// 点一下整行是否弹出任务详情（待办页自己用选中来显示详情，传 false）
    var opensDetail = true

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                Task { await model.complete(task) }
            } label: {
                Image(systemName: task.done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18))
                    .foregroundStyle(task.done ? Color.green : priorityColor)
            }
            .buttonStyle(.plain)
            .disabled(task.done)
            .help(task.done ? "已完成" : "完成")

            VStack(alignment: .leading, spacing: 3) {
                Text(task.cleanTitle)
                    .strikethrough(task.done)
                    .foregroundStyle(task.done ? .secondary : .primary)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    if overdue, let d = task.date {
                        Text("逾期 \(max(1, Day.diff(d, Day.today()))) 天").font(.caption).foregroundStyle(.red)
                    } else if showDate, let d = task.date {
                        Text(Day.label(d)).font(.caption).foregroundStyle(.secondary)
                    }
                    if let t = task.time { Text(t).font(.caption).foregroundStyle(.secondary).monospacedDigit() }
                    if task.repeatFlag != nil { Image(systemName: "repeat").font(.caption2).foregroundStyle(.secondary) }
                    if taskNote != nil { Image(systemName: "doc.text").font(.caption2).foregroundStyle(.secondary).help("有任务笔记") }
                    if showProject, let p = model.overview?.projectName(task.projectId) {
                        Text(p).font(.caption).foregroundStyle(.tertiary)
                    }
                    ForEach(task.tags.filter { $0 != "结审" }.prefix(3), id: \.self) { TagChip(text: "#" + $0, tint: .secondary) }
                }
                if let note = shownNote {
                    Text(note).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        // 待办页（opensDetail = false）靠列表自己的选中，行上不挂点击手势：挂了会和拖拽抢手势，要按住好一会儿才开始拖
        .modifier(TapWhen(enabled: opensDetail) { model.openTask(task) })
        .contextMenu {
            if let note = taskNote { Button("打开任务笔记") { model.openNote(note.noteId, title: note.deliverable) } }
            TaskContextMenu(task: task)
        }
    }

    private var taskNote: TaskNoteRef? { model.taskNote(forTask: task) }

    /// 备注行：内容只是把标题重复一遍（结审任务常见）时不显示
    private var shownNote: String? {
        let c = task.content.trimmed
        if c.isEmpty { return nil }
        let core = c.replacingOccurrences(of: "[.…]+$", with: "", options: .regularExpression).trimmed
        if core.isEmpty || task.cleanTitle.contains(core) { return nil }
        return c
    }

    private var priorityColor: Color {
        switch task.priority {
        case 5: return .red
        case 3: return .orange
        case 1: return .blue
        default: return .secondary
        }
    }
}

// MARK: - 远程图片

struct RemoteImage: View {
    @EnvironmentObject var model: AppModel
    let url: String
    @State private var image: NSImage?
    @State private var failed = false

    private static let cache = NSCache<NSString, NSImage>()

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 560, maxHeight: 520)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .onTapGesture { if let u = URL(string: url), !url.hasPrefix("data:") { model.open(u) } }
            } else if failed {
                Label("图片加载失败", systemImage: "photo").font(.caption).foregroundStyle(.tertiary)
            } else {
                ProgressView().controlSize(.small).frame(height: 60)
            }
        }
        .task(id: url) {
            if let c = Self.cache.object(forKey: url as NSString) { image = c; return }
            let key = model.credentials.ideashellKey
            if let img = await Self.fetch(url, key: key) {
                Self.cache.setObject(img, forKey: url as NSString)
                image = img
            } else {
                failed = true
            }
        }
    }

    /// 图片在闪念贝壳自己的域名下时带上 API Key，别的域名一律不带
    private static func fetch(_ urlString: String, key: String) async -> NSImage? {
        if urlString.lowercased().hasPrefix("data:") {
            guard let r = urlString.range(of: "base64,"), let d = Data(base64Encoded: String(urlString[r.upperBound...])) else { return nil }
            return NSImage(data: d)
        }
        guard let url = URL(string: urlString), let host = url.host else { return nil }
        var req = URLRequest(url: url)
        if (host == "ideashell.cn" || host.hasSuffix(".ideashell.cn")) && !key.isEmpty {
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else { return nil }
        return NSImage(data: data)
    }
}


/// 只在需要时才挂点击手势（不需要时完全不挂，不影响拖拽）
struct TapWhen: ViewModifier {
    let enabled: Bool
    let action: () -> Void

    func body(content: Content) -> some View {
        if enabled { content.onTapGesture(perform: action) } else { content }
    }
}


/// 侧边栏的一行：自己画选中态（主题色），不依赖系统强调色
struct SidebarRow<Icon: View>: View {
    let title: String
    let selected: Bool
    var badge: Int = 0
    var fontSize: CGFloat = 13
    /// 选中色：主窗口用主题橙，设置窗口跟随系统强调色
    var tint: Color = Brand.orange
    let action: () -> Void
    @ViewBuilder var icon: (Bool) -> Icon
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                icon(selected)
                Text(title).font(.system(size: fontSize, weight: selected ? .semibold : .regular))
                Spacer(minLength: 4)
                if badge > 0 {
                    Text("\(badge)").font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(selected ? Color.white.opacity(0.9) : Color.secondary)
                }
            }
            .foregroundStyle(selected ? Color.white : Color.primary)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? tint : (hover ? Color.primary.opacity(0.06) : Color.clear),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}
