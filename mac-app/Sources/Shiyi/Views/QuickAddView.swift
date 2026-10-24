import SwiftUI

/// 万能输入（复刻安卓端）：一个输入框，自动识别是待办 / Daily Note / 笔记。
/// - 前缀强制：`待办 …`、`日记 …`、`笔记 …`
/// - `#标签`、`@文件夹`；「明天 15:00 开会」「下周五下午3点半 交周报」这类日期时间会被识别成待办
/// - 识别结果可以在输入框下面直接改
/// 主窗口里以弹层出现，菜单栏里以紧凑形态内嵌。
struct QuickAddView: View {
    @EnvironmentObject var model: AppModel
    var compact = false
    /// 专注中的「记录」：同一个输入窗口，但内容写进专注绑定的任务（没绑定就记到今天的 Daily Note），底栏显示任务名而不是类型
    var record: FocusStore?
    /// 提交成功后的回调（弹层用来关闭自己）
    var onDone: (() -> Void)?

    @State private var text = ""
    @State private var override: CaptureKind?
    @State private var defaultDate: String?
    @State private var defaultTime: String?
    @State private var priority = 0
    @State private var submitting = false
    @State private var error: String?
    @State private var okText: String?
    @FocusState private var focused: Bool

    private var analysis: CaptureAnalysis { CaptureParser.analyze(text, sjz: model.hasSjz) }
    private func kind(_ a: CaptureAnalysis) -> CaptureKind { override ?? a.kind }

    /// 输入框高度：一行起步，按内容（粗估折行）长到最多 5 行，再多就在框里滚动
    private var editorHeight: CGFloat {
        let lines = text.components(separatedBy: "\n").reduce(0) { $0 + max(1, Int((Double($1.count) / 26).rounded(.up))) }
        return CGFloat(min(max(lines, 1), 5)) * 21 + 6
    }

    var body: some View {
        let a = analysis
        let k = kind(a)
        VStack(alignment: .leading, spacing: 0) {
            // 输入区：没有框，直接写；弹层形态里图标放在文字左边，高度随内容长（1~5 行），不再先占一大块
            HStack(alignment: .top, spacing: 10) {
                if !compact {
                    Image(systemName: "sparkles").font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Brand.orange).frame(width: 20, height: 24)
                }
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $text)
                        .font(.system(size: compact ? 14 : 16))
                        .scrollContentBackground(.hidden)
                        .focused($focused)
                        .padding(.horizontal, -5).padding(.vertical, -1)
                    if text.isEmpty {
                        Text(record != nil ? "专注时的想法、进展、卡点…" : (compact ? "记点什么…" : "记点什么？待办、想法、日记都可以"))
                            .font(.system(size: compact ? 14 : 16))
                            .foregroundStyle(.tertiary)
                            .allowsHitTesting(false)
                    }
                }
                .frame(height: compact ? 70 : editorHeight)
            }
            .padding(.horizontal, compact ? 12 : 18).padding(.top, compact ? 8 : 14)

            // 提示行：空的时候给几个例子，写了字就显示识别结果
            Group {
                if let record {
                    recordHint(record)
                } else if text.trimmed.isEmpty {
                    examples
                } else {
                    recognized(a, k)
                }
            }
            .frame(minHeight: 24, alignment: .leading)
            .padding(.horizontal, compact ? 12 : 18).padding(.top, 6)

            if let error {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    .padding(.horizontal, compact ? 12 : 18).padding(.top, 4)
            } else if let okText {
                Label(okText, systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
                    .padding(.horizontal, compact ? 12 : 18).padding(.top, 4)
            }

            if compact { Divider().opacity(0.6).padding(.top, 12) }

            // 底栏：类型 + 优先级 + 提交
            HStack(spacing: 8) {
                if let record {
                    taskChip(record)
                } else {
                    kindMenu(a, k)
                    if k == .todo { priorityMenu }
                    if k.isSjz { sjzChip(k) }
                }
                Spacer(minLength: 8)
                if let onDone {
                    Button("取消", action: onDone)
                        .buttonStyle(.plain).foregroundStyle(.secondary).font(.callout)
                        .keyboardShortcut(.cancelAction)
                }
                if let record { recordSubmitButton(record) } else { submitButton(a, k) }
            }
            .padding(.horizontal, compact ? 12 : 14).padding(.top, compact ? 8 : 8).padding(.bottom, compact ? 8 : 12)
        }
        .frame(width: compact ? nil : 480)
        .onChange(of: text) { _, new in
            if let record, record.recordDraft != new { record.recordDraft = new }
        }
        .onAppear {
            focused = true
            if let record { text = record.recordDraft }
            if !model.quickAddText.isEmpty { text = model.quickAddText }
            override = model.quickAddKind
            defaultDate = model.quickAddDate
            defaultTime = model.quickAddTime
            model.quickAddTime = nil
            model.quickAddText = ""
            model.quickAddKind = nil
            model.quickAddDate = nil
        }
    }

    // MARK: - 组件

    /// 开启结审后，示例里带上线索 / 证据 / 法规前缀
    private var exampleList: [String] {
        if model.hasSjz { return compact ? ["明天 15:00 开会", "线索 …", "证据 …", "法规 …"] : ["明天 15:00 开会", "线索 …", "证据 …", "法规 …", "笔记 @项目 …"] }
        return ["明天 15:00 开会", "#读书 一句话想法", "笔记 @项目 …"]
    }

    /// 结审去向：线索 → 项目；证据 → 钉住的取证单 / 新证据文件；法规 → 钉住的法规 / 自动取名。放在底栏，空间不够时从末尾截断
    private func sjzChip(_ k: CaptureKind) -> some View {
        let pin = model.sjzPin
        let project = model.sjzTargetTitle.isEmpty ? "未选择项目" : model.sjzTargetTitle
        var label = project
        if !model.sjzTargetTitle.isEmpty {
            switch k {
            case .evidence: label += " · " + (pin.noteLabel.isEmpty ? "新证据文件" : pin.noteLabel)
            case .regulation: label += " · " + (pin.regulation.isEmpty ? "自动取名" : pin.regulation)
            default: break
            }
        }
        return HStack(spacing: 4) {
            Image(systemName: "checkmark.shield").font(.system(size: 10))
            Text(label).lineLimit(1).truncationMode(.tail)
        }
        .font(.caption)
        .foregroundStyle(Color.indigo)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Color.indigo.opacity(0.1), in: Capsule())
        .layoutPriority(-1)
        .help("结审 · " + label)
    }

    // MARK: - 专注记录

    private func recordGoesToTask(_ f: FocusStore) -> Bool { f.run?.taskId != nil }

    /// 提示行：说明这条会记到哪里
    private func recordHint(_ f: FocusStore) -> some View {
        HStack(spacing: 6) {
            Text(recordGoesToTask(f) ? "记到任务笔记的「进展记录」，并同步成滴答评论" : "没有关联待办：记到今天的 Daily Note")
                .font(.caption).foregroundStyle(.tertiary).lineLimit(1)
            Spacer(minLength: 0)
        }
    }

    /// 底栏左边：原来放类型（Daily Note）的位置，改成任务的名字；没关联任务时仍是 Daily Note
    private func taskChip(_ f: FocusStore) -> some View {
        let task = recordGoesToTask(f)
        let name = task ? ((f.run?.title.isEmpty == false) ? f.run!.title : "未命名任务") : "Daily Note"
        return HStack(spacing: 5) {
            Image(systemName: task ? "scope" : CaptureKind.daily.icon).font(.system(size: 12, weight: .semibold))
            Text(name).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.tail)
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(Brand.orange.opacity(0.14), in: Capsule())
        .foregroundStyle(Brand.orangeDeep)
        .frame(maxWidth: 260, alignment: .leading)
        .help(task ? "记到任务「\(name)」" : "记到今天的 Daily Note")
    }

    private func recordSubmitButton(_ f: FocusStore) -> some View {
        let disabled = model.recording || text.trimmed.isEmpty
        return Button {
            let t = text.trimmed
            guard !t.isEmpty else { return }
            f.recordDraft = ""
            text = ""
            Task { await model.recordFocus(t) }
            onDone?()
        } label: {
            HStack(spacing: 6) {
                if model.recording { ProgressView().controlSize(.small) } else {
                    Text(recordGoesToTask(f) ? "记录进展" : "记入 Daily Note").font(.callout.weight(.semibold))
                }
                Text("⌘↩").font(.caption2).opacity(0.7)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background(Brand.orange.opacity(disabled ? 0.35 : 1), in: Capsule())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.return, modifiers: .command)
        .disabled(disabled)
    }

    private var examples: some View {
        HStack(spacing: 6) {
            Text("试试").font(.caption).foregroundStyle(.tertiary)
            ForEach(exampleList, id: \.self) { e in
                Button { text = e.hasSuffix("…") ? String(e.dropLast()) : e; focused = true } label: {
                    Text(e).font(.caption).foregroundStyle(.secondary)
                        .padding(.horizontal, 9).padding(.vertical, 3)
                        .background(Color.primary.opacity(0.06), in: Capsule())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
    }

    /// 类型：默认自动识别，点开可以手动改
    private func kindMenu(_ a: CaptureAnalysis, _ k: CaptureKind) -> some View {
        Menu {
            ForEach(CaptureKind.available(sjz: model.hasSjz)) { c in
                Button {
                    override = (c == a.recommended && a.forced == nil) ? nil : c
                } label: {
                    if c == k { Label(c.rawValue, systemImage: "checkmark") } else { Label(c.rawValue, systemImage: c.icon) }
                }
            }
            if override != nil {
                Divider()
                Button("恢复自动识别") { override = nil }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: k.icon).font(.system(size: 12, weight: .semibold))
                Text(k.rawValue).font(.callout.weight(.medium))
                if override == nil && !text.trimmed.isEmpty {
                    Text("自动").font(.caption2).foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Brand.orange.opacity(0.14), in: Capsule())
            .foregroundStyle(Brand.orangeDeep)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help("类型（自动识别，也可以手动改）")
    }

    private var priorityMenu: some View {
        Menu {
            Picker("优先级", selection: $priority) {
                Text("无").tag(0)
                Text("低").tag(1)
                Text("中").tag(3)
                Text("高").tag(5)
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: priority == 0 ? "flag" : "flag.fill").font(.system(size: 12))
                    .foregroundStyle(priority == 5 ? Color.red : (priority == 3 ? Color.orange : (priority == 1 ? Color.blue : Color.secondary)))
                Text(priority == 0 ? "优先级" : (priority == 5 ? "高" : (priority == 3 ? "中" : "低"))).font(.callout)
            }
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(Color.primary.opacity(0.06), in: Capsule())
            .foregroundStyle(.secondary)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
    }

    private func submitButton(_ a: CaptureAnalysis, _ k: CaptureKind) -> some View {
        let disabled = submitting || text.trimmed.isEmpty
        return Button {
            submit(a, k)
        } label: {
            HStack(spacing: 6) {
                if submitting { ProgressView().controlSize(.small) } else { Text(submitLabel(k)).font(.callout.weight(.semibold)) }
                Text("⌘↩").font(.caption2).opacity(0.7)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background(Brand.orange.opacity(disabled ? 0.35 : 1), in: Capsule())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.return, modifiers: .command)
        .disabled(disabled)
    }

    /// 识别出来的东西：日期时间 / 标签 / 文件夹
    @ViewBuilder private func recognized(_ a: CaptureAnalysis, _ k: CaptureKind) -> some View {
        HStack(spacing: 6) {
            if k == .todo {
                let date = a.todo.date ?? defaultDate
                if let d = date {
                    chip("calendar", Day.label(d) + ((a.todo.time ?? (a.todo.date == nil ? defaultTime : nil)).map { " " + $0 } ?? ""), tint: Brand.orangeDeep)
                } else {
                    chip("tray", "无日期 · 收集箱", tint: .secondary)
                }
            }
            ForEach(a.tags, id: \.self) { chip("number", $0, tint: .accentColor) }
            if let f = a.folderName { chip("folder", f, tint: .accentColor) }
            if k == .daily { chip("clock", "追加到今天的 Daily Note", tint: .secondary) }
            if k == .note && a.tags.isEmpty && a.folderName == nil { chip("doc.text", "新建一条笔记", tint: .secondary) }
            Spacer(minLength: 0)
        }
        .font(.caption)
    }

    private func chip(_ icon: String, _ label: String, tint: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 10))
            Text(label)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(tint.opacity(0.1), in: Capsule())
    }

    private func submitLabel(_ k: CaptureKind) -> String {
        switch k {
        case .todo: return "添加待办"
        case .daily: return "记入 Daily Note"
        case .note: return "保存笔记"
        case .clue: return "记为线索"
        case .evidence: return "保存为证据"
        case .regulation: return "保存为法规"
        }
    }

    // MARK: - 提交

    private func submit(_ a: CaptureAnalysis, _ k: CaptureKind) {
        guard !submitting, !text.trimmed.isEmpty else { return }
        submitting = true
        error = nil
        okText = nil
        let pri = priority
        let def = defaultDate
        let defTime = defaultTime
        Task {
            defer { submitting = false }
            do {
                let msg = try await model.submitCapture(a, kind: k, priority: pri, defaultDate: def, defaultTime: defTime)
                text = ""
                override = nil
                priority = 0
                if let onDone {
                    model.showNotice(msg)
                    onDone()
                } else {
                    okText = msg
                    focused = true
                }
            } catch {
                self.error = "提交失败：" + error.localizedDescription
            }
        }
    }
}

/// 主窗口里的短暂提示条（快速记录成功等）
struct NoticeToast: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if let text = model.notice {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(text)
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .glassCapsule()
            .shadow(radius: 6, y: 2)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}
