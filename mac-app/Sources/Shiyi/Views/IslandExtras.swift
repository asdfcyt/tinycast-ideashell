import AppKit
import SwiftUI

// MARK: - 投放区

/// 拖东西到岛上时出现：左半边「保存」（自动识别），右半边「暂存」；保存中 / 完成时显示结果
struct IslandDropPane: View {
    @ObservedObject var state: IslandState
    @EnvironmentObject var model: AppModel
    @AppStorage(DisplayMode.shelfKey) private var shelfOn = true

    private var withSjz: Bool { state.sjzOn && state.drop.showsZones }

    var body: some View {
        Group {
            switch state.drop {
            case .working:
                resultBox {
                    ProgressView().controlSize(.small).tint(.white)
                    Text("处理中…").font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
                }
            case let .done(msg, ok):
                resultBox {
                    Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 22)).foregroundStyle(ok ? Color.green : Color.orange)
                    Text(msg).font(.system(size: 12.5, weight: .medium)).foregroundStyle(.white)
                        .multilineTextAlignment(.center).lineLimit(2).padding(.horizontal, 12)
                }
            default:
                VStack(spacing: 8) {
                    HStack(spacing: 10) {
                        zoneBox(.save, icon: "square.and.arrow.down", title: "保存",
                                lines: ["截图 → 笔记", "文字 / 链接 → 记录 / 待办"])
                        if shelfOn {
                            zoneBox(.shelf, icon: "tray.and.arrow.down", title: "暂存",
                                    lines: ["先放在岛上", "稍后再拖出去"])
                        }
                    }
                    .frame(height: withSjz ? 76 : nil)
                    if withSjz {
                        HStack(spacing: 8) {
                            miniZone(.evidence, icon: "doc.badge.plus", title: "证据")
                            miniZone(.regulation, icon: "book.closed", title: "法规")
                            miniZone(.clue, icon: "lightbulb", title: "线索")
                            miniZone(.data, icon: "tablecells", title: "数据")
                        }
                        .frame(height: 62)
                    }
                }
            }
        }
        // 高度写死（= dropHeight - 刘海 - 底部留白）：ZStack 里的待办层可能比它高，不能让它跟着撑
        .frame(height: withSjz ? 146 : 86)
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
        .animation(.easeOut(duration: 0.15), value: state.drop)
    }

    private func resultBox<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        return VStack(spacing: 7) { content() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(shape.fill(Color.white.opacity(0.07)))
    }

    /// 结审那一排：证据 / 法规 / 线索，第二行显示保存到哪个项目
    private func miniZone(_ zone: DropZone, icon: String, title: String) -> some View {
        let active = state.drop == .hover && state.zone == zone
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return VStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 16))
                .foregroundStyle(active ? Brand.orange : Color.white.opacity(0.7))
            Text(active ? "松手存\(title)" : "结审 · \(title)").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
            Text(miniTarget(zone))
                .font(.system(size: 9.5)).foregroundStyle(.white.opacity(0.5)).lineLimit(1).padding(.horizontal, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(shape.fill(Color.white.opacity(active ? 0.14 : 0.06)))
        .overlay(shape.strokeBorder(active ? Brand.orange : Color.white.opacity(0.22), style: StrokeStyle(lineWidth: 1.2, dash: [5, 4])))
        .animation(.easeOut(duration: 0.15), value: active)
    }

    /// 每个投放区的第二行：会存到哪里
    private func miniTarget(_ zone: DropZone) -> String {
        let pin = model.sjzPin
        guard !pin.project.isEmpty else { return "未选择项目" }
        switch zone {
        case .evidence: return !pin.evidencePath.isEmpty ? "追加 · " + pin.evidenceLabel : pin.noteLabel.isEmpty ? "新证据文件" : "追加 · " + pin.noteLabel
        case .regulation: return pin.regulation.isEmpty ? "自动取名并新建" : "追加 · " + pin.regulation
        case .clue: return pin.clueId.isEmpty ? "新线索" : "追加 · " + pin.clueLabel
        case .data: return "原始材料 · 文件"
        default: return pin.projectTitle.isEmpty ? pin.project : pin.projectTitle
        }
    }

    private func zoneBox(_ zone: DropZone, icon: String, title: String, lines: [String]) -> some View {
        let active = state.drop == .hover && state.zone == zone
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        return VStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 20))
                .foregroundStyle(active ? Brand.orange : Color.white.opacity(0.7))
            Text(active ? "松手" + title : title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
            ForEach(lines, id: \.self) { Text($0).font(.system(size: 10)).foregroundStyle(.white.opacity(0.55)) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(shape.fill(Color.white.opacity(active ? 0.14 : 0.06)))
        .overlay(shape.strokeBorder(active ? Brand.orange : Color.white.opacity(0.22), style: StrokeStyle(lineWidth: 1.2, dash: [5, 4])))
        .animation(.easeOut(duration: 0.15), value: active)
    }
}

// MARK: - 实时活动

/// 事件发生时岛自己弹出来的一条：刚截了图、番茄完成、待办到点……
struct IslandActivityView: View {
    @ObservedObject var state: IslandState
    @EnvironmentObject var model: AppModel
    let activity: IslandActivity
    @AppStorage(DisplayMode.shelfKey) private var shelfOn = true

    /// 截图提示 + 已连接结审：两行布局，多出「证据 / 法规」
    private var isSjz: Bool {
        if case .capture = activity { return state.sjzOn }
        return false
    }

    private struct Btn: Identifiable {
        let id = UUID()
        var label: String?
        var icon: String?
        var help: String
        var prominent = false
        var action: ActivityAction
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        Group {
            if isSjz { sjzBody } else { plainBody }
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity)
        .frame(height: isSjz ? 104 : 62)
        .background(shape.fill(Color.white.opacity(0.08)))
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
    }

    private var closeButton: some View {
        Button { state.onActivityAction?(activity, .dismiss) } label: {
            Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white.opacity(0.5))
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.plain).help("忽略")
    }

    /// 截图提示（已连接结审）：上面缩略图 + 标题，下面一排按钮
    private var sjzBody: some View {
        VStack(spacing: 9) {
            HStack(spacing: 12) {
                leading
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                    Text("结审：" + (model.sjzTargetTitle.isEmpty ? "未钉住项目" : model.sjzTargetTitle))
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                }
                Spacer(minLength: 4)
                closeButton
            }
            HStack(spacing: 6) {
                wide("存为笔记", prominent: true, .primary)
                wide("存为证据", prominent: false, .evidence)
                wide("存为法规", prominent: false, .regulation)
                if shelfOn { wide("暂存", prominent: false, .secondary) }
            }
        }
    }

    private func wide(_ label: String, prominent: Bool, _ action: ActivityAction) -> some View {
        Button { state.onActivityAction?(activity, action) } label: {
            Text(label).font(.system(size: 12, weight: .semibold))
                .frame(maxWidth: .infinity).frame(height: 26)
                .foregroundStyle(prominent ? Brand.brown : Color.white)
                .background(prominent ? Brand.orange : Color.white.opacity(0.14), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private var plainBody: some View {
        HStack(spacing: 12) {
            leading
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
            }
            Spacer(minLength: 4)
            ForEach(buttons) { b in button(b) }
            closeButton
        }
    }

    // MARK: 内容

    @ViewBuilder private var leading: some View {
        switch activity {
        case let .capture(o):
            Group {
                if let img = o.thumbnail {
                    Image(nsImage: img).resizable().scaledToFill()
                } else {
                    Image(systemName: "photo").foregroundStyle(.white.opacity(0.6))
                }
            }
            .frame(width: 42, height: 42)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.white.opacity(0.2), lineWidth: 0.5))
            .onDrag { Self.provider(for: o) }
            .help("按住拖到别的 App 里直接使用")
        case let .focusDone(m, _, _):
            // 关掉小票时的小提示：只有一块点阵屏
            DotMatrixText(text: DotMatrixText.clock(m), size: 21)
                .frame(width: 92, height: 42)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black.opacity(0.7)))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(TicketPalette.termEdge, lineWidth: 1))
        case .breakDone:
            icon("cup.and.saucer.fill", Brand.orange)
        case .todoDue:
            icon("bell.badge.fill", Brand.orange)
        case let .audit(e):
            icon(e.icon, .indigo)
        }
    }

    private func icon(_ name: String, _ tint: Color) -> some View {
        Image(systemName: name).font(.system(size: 24)).foregroundStyle(tint).frame(width: 42, height: 42)
    }

    private var title: String {
        switch activity {
        case let .capture(o): return o.title
        case let .focusDone(m, _, _): return "番茄完成 · \(m) 分钟"
        case let .breakDone(k): return "\(k.label)结束"
        case let .todoDue(t, _): return t.cleanTitle
        case let .audit(e): return e.title
        }
    }

    private var subtitle: String {
        switch activity {
        case .capture: return "存为笔记、暂存，或按住缩略图拖走"
        case let .focusDone(_, b, _): return b.map { "休息一下：\($0.label) \($0.defaultMin) 分钟" } ?? "继续保持"
        case .breakDone: return "准备好开始下一个专注了吗？"
        case let .todoDue(t, lead):
            let time = t.time ?? ""
            return lead > 0 ? "\(lead) 分钟后 · \(time)" : "现在 · \(time)"
        case let .audit(e): return "结审 · \(e.projectTitle) · \(e.detail)"
        }
    }

    private var buttons: [Btn] {
        switch activity {
        case .capture:
            return [Btn(label: "存为笔记", help: "保存为笔记", prominent: true, action: .primary)]
                + (shelfOn ? [Btn(label: "暂存", help: "放进暂存架", action: .secondary)] : [])
        case let .focusDone(_, b, _):
            return b != nil
                ? [Btn(label: "开始休息", help: "开始\(b!.label)", prominent: true, action: .primary),
                   Btn(icon: "forward.fill", help: "跳过休息，继续专注", action: .secondary)]
                : [Btn(label: "再来一个", help: "再专注一个番茄", prominent: true, action: .primary)]
        case .breakDone:
            return [Btn(label: "开始专注", help: "开始专注", prominent: true, action: .primary)]
        case .todoDue:
            return [Btn(label: "完成", help: "完成这个待办", prominent: true, action: .primary),
                    Btn(icon: "play.fill", help: "专注这件事", action: .secondary),
                    Btn(icon: "clock.arrow.circlepath", help: "推迟 1 小时", action: .tertiary)]
        case .audit:
            return [Btn(label: "打开结审", help: "打开结审", prominent: true, action: .primary)]
        }
    }

    private func button(_ b: Btn) -> some View {
        Button { state.onActivityAction?(activity, b.action) } label: {
            Group {
                if let l = b.label {
                    Text(l).font(.system(size: 12, weight: .semibold)).padding(.horizontal, 11)
                } else if let i = b.icon {
                    Image(systemName: i).font(.system(size: 10, weight: .bold)).frame(width: 28)
                }
            }
            .frame(height: 26)
            .foregroundStyle(b.prominent ? Brand.brown : Color.white)
            .background(b.prominent ? Brand.orange : Color.white.opacity(0.14), in: Capsule())
        }
        .buttonStyle(.plain)
        .help(b.help)
    }

    private static func provider(for o: CaptureOffer) -> NSItemProvider {
        if let u = o.fileURL, let p = NSItemProvider(contentsOf: u) { return p }
        if let d = o.raw.imageData.first, let img = NSImage(data: d) { return NSItemProvider(object: img) }
        return NSItemProvider()
    }
}

// MARK: - 暂存架

/// 展开页底部：暂存的东西。拖出去、点一下复制、双击打开、右键更多
struct ShelfStrip: View {
    @ObservedObject var shelf: ShelfStore
    @State private var flash: UUID?
    @State private var hovering: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "tray.full").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Text("暂存").font(.caption.weight(.bold))
                if !shelf.items.isEmpty { Text("\(shelf.items.count)").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary) }
                Spacer()
                Button { IslandController.shared.pasteClipboard(toShelf: true) } label: {
                    Label("粘贴", systemImage: "doc.on.clipboard").font(.caption)
                }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("把剪贴板里的内容放进暂存架（⌘⇧V）")
                if !shelf.items.isEmpty {
                    Button("清空") { shelf.clear() }.buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                }
            }
            if shelf.items.isEmpty {
                Text("把东西拖到刘海右半边，先放在这里，稍后再拖到别的 App。")
                    .font(.caption).foregroundStyle(.tertiary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(shelf.items) { card($0) }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 6)
    }

    private func card(_ item: ShelfItem) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return VStack(spacing: 3) {
            ZStack(alignment: .topTrailing) {
                thumb(item)
                    .frame(width: 56, height: 56)
                    .background(Color.white.opacity(0.06), in: shape)
                    .clipShape(shape)
                    .overlay {
                        if flash == item.id {
                            ZStack {
                                shape.fill(Color.black.opacity(0.55))
                                Image(systemName: "checkmark").font(.system(size: 16, weight: .bold)).foregroundStyle(.green)
                            }
                        }
                    }
                if hovering == item.id {
                    Button { shelf.remove(item) } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 14))
                            .foregroundStyle(.white, Color.black.opacity(0.7))
                    }
                    .buttonStyle(.plain).offset(x: 4, y: -4)
                }
            }
            Text(item.name).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).frame(width: 56)
        }
        .onHover { hovering = $0 ? item.id : (hovering == item.id ? nil : hovering) }
        .onDrag { shelf.provider(for: item) }
        .onTapGesture(count: 2) { shelf.open(item) }
        .onTapGesture {
            shelf.copy(item)
            flash = item.id
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { if flash == item.id { flash = nil } }
        }
        .contextMenu {
            Button("打开") { shelf.open(item) }
            Button("复制") { shelf.copy(item) }
            Button("保存（自动识别）") { IslandController.shared.submit(shelf.rawDrop(for: item)) }
            if AppModel.current?.hasSjz == true {
                Button("保存为结审证据") { IslandController.shared.submit(shelf.rawDrop(for: item), to: .evidence) }
                Button("保存为结审法规") { IslandController.shared.submit(shelf.rawDrop(for: item), to: .regulation) }
                Button("记为结审线索") { IslandController.shared.submit(shelf.rawDrop(for: item), to: .clue) }
            }
            Divider()
            Button("移除", role: .destructive) { shelf.remove(item) }
        }
        .help(item.kind == .file || item.kind == .image ? "点一下复制，双击打开，拖出去使用" : "点一下复制，双击打开")
    }

    @ViewBuilder private func thumb(_ item: ShelfItem) -> some View {
        switch item.kind {
        case .image, .file:
            if let img = shelf.thumbnail(for: item) {
                Image(nsImage: img).resizable().scaledToFill()
            } else {
                Image(systemName: "doc").foregroundStyle(.secondary)
            }
        case .link:
            VStack(spacing: 2) {
                Image(systemName: "link").font(.system(size: 18)).foregroundStyle(Brand.orange)
            }
        case .text:
            Text(item.text ?? "").font(.system(size: 8.5)).foregroundStyle(.white.opacity(0.75))
                .lineLimit(5).multilineTextAlignment(.leading).padding(5)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}
