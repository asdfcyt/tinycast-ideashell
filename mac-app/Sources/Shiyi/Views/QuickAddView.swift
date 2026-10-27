import SwiftUI

/// 万能输入（复刻安卓端）：一个输入框，自动识别是待办 / Daily Note / 笔记。
/// - 前缀强制：`待办 …`、`日记 …`、`笔记 …`
/// - `#标签`、`@文件夹`；「明天 15:00 开会」「下周五下午3点半 交周报」这类日期时间会被识别成待办
/// - 识别结果可以在输入框下面直接改
/// 主窗口里以弹层出现，菜单栏里以紧凑形态内嵌。
struct QuickAddView: View {
    @EnvironmentObject var model: AppModel
    /// 听写按钮的状态（录音中变红）
    @ObservedObject private var voice = VoiceController.shared
    var compact = false
    /// 专注中的「记录」：同一个输入窗口，但内容写进专注绑定的任务（没绑定就记到今天的 Daily Note），底栏显示任务名而不是类型
    var record: FocusStore?
    /// 提交成功后的回调（弹层用来关闭自己）
    var onDone: (() -> Void)?
    /// 输入内容变化（全局悬浮输入窗用它留住草稿）
    var onDraftChange: ((String) -> Void)?
    /// 手动选的类型变化（全局悬浮输入窗用它连同草稿一起留住类型）
    var onKindChange: ((CaptureKind?) -> Void)?
    /// 提交成功（参数是结果文案）。设置后不再调 onDone 关闭，而是在输入框下面显示结果，由调用方决定什么时候关（全局悬浮输入窗用）
    var onSubmitted: ((String) -> Void)?

    @State private var text = ""
    /// 输入框里插入的图片（结审类型支持图文混排）：text 里每个 U+FFFC 对应一张
    @State private var images: [ComposerImage] = []
    /// 输入框里内容实际排出来的高度（ComposerTextView 量出来的）
    @State private var contentH: CGFloat = 0
    @State private var override: CaptureKind?
    /// 上一次提交的结审类型（想法 / 证据 / 法规 / 线索）：再打开万能输入时默认还是它，直到 Tab 切回自动或写了前缀
    @State private var sticky: CaptureKind?
    private static let stickyKey = "quickAdd.lastSjzKind"
    @State private var defaultDate: String?
    @State private var defaultTime: String?
    @State private var priority = 0
    @State private var submitting = false
    @State private var error: String?
    @State private var okText: String?
    /// 每加一次就把焦点还给输入框
    @State private var focusTick = 0

    private var analysis: CaptureAnalysis { CaptureParser.analyze(text, sjz: model.hasSjz) }
    /// 自动识别的类型：贴了图片又没写前缀，按「证据」处理（和截图保存一致）
    private func autoKind(_ a: CaptureAnalysis) -> CaptureKind { !images.isEmpty && model.hasSjz ? .evidence : a.recommended }
    private func kind(_ a: CaptureAnalysis) -> CaptureKind { override ?? a.forced ?? sticky ?? autoKind(a) }
    private func clearSticky() { sticky = nil; UserDefaults.standard.removeObject(forKey: Self.stickyKey) }

    /// 输入框高度：一行起步，按内容（粗估折行）长到最多 5 行，再多就在框里滚动；带图片时按缩略图再加高
    private var editorHeight: CGFloat {
        let maxH: CGFloat = images.isEmpty ? 5 * 21 + 6 : 360
        if contentH > 0 { return min(max(contentH + 4, 26), maxH) }
        let lines = ComposerImage.stripMarker(text).components(separatedBy: "\n").reduce(0) { $0 + max(1, Int((Double($1.count) / 26).rounded(.up))) }
        return min(CGFloat(max(lines, 1)) * 21 + 6, maxH)
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
                    ComposerTextView(
                        text: $text,
                        images: $images,
                        contentHeight: $contentH,
                        allowsImages: model.hasSjz && record == nil,
                        fontSize: compact ? 14 : 16,
                        focusTick: focusTick,
                        onSubmit: { submitFromKeyboard() },
                        onTab: { reverse in cycleKind(reverse: reverse) },
                        onBackspaceEmpty: { exitKind() }
                    )
                    if text.isEmpty {
                        Text(record != nil ? "专注时的想法、进展、卡点…" : (compact ? "记点什么…（Tab 切换类型）" : (model.hasSjz ? "记点什么？按 Tab 切换 想法 / 证据 / 法规 / 线索" : "记点什么？待办、想法、日记都可以，Tab 切换类型")))
                            .font(.system(size: compact ? 14 : 16))
                            .foregroundStyle(.secondary)
                            .padding(.top, 2)
                            .allowsHitTesting(false)
                    }
                }
                .frame(height: compact ? max(editorHeight, 70) : editorHeight)
            }
            .padding(.horizontal, compact ? 12 : 18).padding(.top, compact ? 8 : 14)

            // 提示行：空的时候给几个例子，写了字就显示识别结果
            Group {
                if let record {
                    recordHint(record)
                } else if k.isSjz {
                    sjzTarget(a, k)
                } else if text.trimmed.isEmpty {
                    examples
                } else {
                    recognized(a, k)
                }
            }
            // 搜索已有证据 / 法规 / 线索会把这一行撑高：必须放在 frame 外面固定高度，否则窗口还没长高时这一行会被压回一行，列表溢出去盖住底栏
            .frame(maxWidth: .infinity, minHeight: 24, alignment: .topLeading)
            .fixedSize(horizontal: false, vertical: true)
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
                if record == nil { dictateButton }
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
        .onChange(of: override) { _, new in onKindChange?(new) }
        // 语音听写（麦克风按钮，或输入窗开着时按语音快捷键）：说的话追加到输入框，可以直接说「证据，…」「想法，…」带类型口令
        .onChange(of: model.quickAddInsert) { _, new in
            guard !new.isEmpty, record == nil else { return }
            model.quickAddInsert = ""
            text = Self.joined(text, new)
            focusTick += 1
        }
        // 猛犸麦克风三击:提交输入框里的内容
        .onReceive(NotificationCenter.default.publisher(for: .micQuickAddSubmit)) { _ in
            if record == nil, !text.trimmed.isEmpty { submitFromKeyboard() }
        }
        .onChange(of: text) { _, new in
            if let record, record.recordDraft != new { record.recordDraft = new }
            onDraftChange?(ComposerImage.stripMarker(new))
        }
        .onAppear {
            focusTick += 1
            if let record { text = record.recordDraft }
            if !model.quickAddText.isEmpty { text = model.quickAddText }
            override = model.quickAddKind
            if override == nil, record == nil, model.hasSjz,
               let raw = UserDefaults.standard.string(forKey: Self.stickyKey), let k = CaptureKind(rawValue: raw), k.isSjz { sticky = k }
            model.quickAddInsert = ""
            model.sjzError = nil
            defaultDate = model.quickAddDate
            defaultTime = model.quickAddTime
            model.quickAddTime = nil
            model.quickAddText = ""
            model.quickAddKind = nil
            model.quickAddDate = nil
        }
    }

    // MARK: - 组件

    /// 开启结审后，示例里带上线索 / 想法 / 证据 / 法规前缀
    private var exampleList: [String] {
        if model.hasSjz { return compact ? ["明天 15:00 开会", "想法 …", "证据 …", "线索 …"] : ["明天 15:00 开会", "想法 …", "证据 …", "法规 …", "线索 …"] }
        return ["明天 15:00 开会", "#读书 一句话想法", "笔记 @项目 …"]
    }

    /// 结审项目：放在底栏，空间不够时从末尾截断（具体追加到哪一份见上面的「去向」行）
    private func sjzChip(_ k: CaptureKind) -> some View {
        let label = model.sjzTargetTitle.isEmpty ? "未选择项目" : model.sjzTargetTitle
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

    /// 结审去向行（提示行的位置）：证据 → 钉住的取证单；法规 → 钉住的法规；线索 → 钉住的线索，都能搜索已有的并追加；想法 → 当天工作日志
    @ViewBuilder private func sjzTarget(_ a: CaptureAnalysis, _ k: CaptureKind) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if !a.tags.isEmpty {
                HStack(spacing: 6) {
                    ForEach(a.tags, id: \.self) { chip("number", $0, tint: Brand.orange) }
                    Spacer(minLength: 0)
                }
                .font(.caption)
            }
            switch k {
            case .evidence:
                VStack(alignment: .leading, spacing: 6) {
                    SjzPinStrip(kinds: [.note, .clue], padded: false, associates: true, deferNew: true)
                }
            case .regulation:
                VStack(alignment: .leading, spacing: 6) {
                    SjzPinStrip(kinds: [.regulation, .clue], padded: false, associates: true)
                }
            case .clue: SjzPinStrip(kinds: [.clue], padded: false)
            default:
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        chip("text.book.closed", "写进「\(model.sjzTargetTitle.isEmpty ? "当前项目" : model.sjzTargetTitle)」当天的工作日志", tint: .secondary)
                        Spacer(minLength: 0)
                    }
                    .font(.caption)
                    SjzPinStrip(kinds: [.clue], padded: false, associates: true)
                }
            }
            if !images.isEmpty {
                Text("\(images.count) 张图片 · 按在文字里的位置混排保存").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

    /// 听写追加：已有内容就接在后面（英文 / 数字结尾补一个空格，中文直接接）
    private static func joined(_ old: String, _ add: String) -> String {
        guard let last = old.last else { return add }
        if last.isWhitespace || last.isNewline { return old + add }
        let ascii = last.isASCII && (last.isLetter || last.isNumber)
        return old + (ascii ? " " : "") + add
    }

    /// 麦克风：开始 / 结束听写，识别结果追加到输入框（不走 AI 整理，仍由你选类型、取证单后保存）
    private var dictateButton: some View {
        let on = voice.dictating
        return Button {
            voice.dictate { model.quickAddInsert = $0 }
            focusTick += 1
        } label: {
            Image(systemName: on ? "stop.circle.fill" : "mic.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(on ? Color.red : Color.secondary)
                .frame(width: 26, height: 26)
                .background((on ? Color.red : Color.primary).opacity(on ? 0.12 : 0.06), in: Circle())
        }
        .buttonStyle(.plain)
        .help(on ? "结束听写" : "语音输入：说的话进输入框，可以先说「证据 / 想法 / 线索 / 法规」再说内容")
    }

    /// 输入框里按回车：和点提交按钮一样
    /// Tab / Shift+Tab 切换类型：结审开着时在「自动 → 想法 → 证据 → 法规 → 线索」里转圈，否则在「自动 → 待办 → Daily Note → 笔记」里转圈
    private func cycleKind(reverse: Bool) {
        guard record == nil else { return }
        let steps: [CaptureKind?] = model.hasSjz ? [nil, .idea, .evidence, .regulation, .clue] : [nil, .todo, .daily, .note]
        let cur: CaptureKind? = override ?? analysis.forced ?? sticky
        let i = steps.firstIndex { $0 == cur } ?? 0
        let next = steps[(i + (reverse ? steps.count - 1 : 1)) % steps.count]
        override = next
        if next == nil { clearSticky() }
    }

    /// 输入框是空的还按删除键：退出 Tab 选的类型，回到自动识别
    private func exitKind() -> Bool {
        guard record == nil, override != nil || sticky != nil else { return false }
        override = nil
        clearSticky()
        return true
    }

    private func submitFromKeyboard() {
        if let record { if !model.recording { recordSubmit(record) }; return }
        let a = analysis
        submit(a, kind(a))
    }

    private func recordSubmit(_ f: FocusStore) {
        let t = text.trimmed
        guard !t.isEmpty else { return }
        f.recordDraft = ""
        text = ""
        Task { await model.recordFocus(t) }
        onDone?()
    }

    private func recordSubmitButton(_ f: FocusStore) -> some View {
        let disabled = model.recording || text.trimmed.isEmpty
        return Button {
            recordSubmit(f)
        } label: {
            HStack(spacing: 6) {
                if model.recording { ProgressView().controlSize(.small) } else {
                    Text(recordGoesToTask(f) ? "记录进展" : "记入 Daily Note").font(.callout.weight(.semibold))
                }
                Text("↩").font(.caption2).opacity(0.7)
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
                Button { text = e.hasSuffix("…") ? String(e.dropLast()) : e; focusTick += 1 } label: {
                    Text(e).font(.caption).foregroundStyle(.secondary)
                        .padding(.horizontal, 9).padding(.vertical, 3)
                        .background(Color.primary.opacity(0.06), in: Capsule())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
            if !compact {
                Text("⇥ 切换类型").font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    /// 类型：默认自动识别，点开可以手动改
    private func kindMenu(_ a: CaptureAnalysis, _ k: CaptureKind) -> some View {
        Menu {
            ForEach(CaptureKind.available(sjz: model.hasSjz)) { c in
                Button {
                    if c == autoKind(a) && a.forced == nil { override = nil; clearSticky() } else { override = c }
                } label: {
                    if c == k { Label(c.rawValue, systemImage: "checkmark") } else { Label(c.rawValue, systemImage: c.icon) }
                }
            }
            if override != nil || sticky != nil {
                Divider()
                Button("恢复自动识别") { override = nil; clearSticky() }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: k.icon).font(.system(size: 12, weight: .semibold))
                Text(k.rawValue).font(.callout.weight(.medium))
                if override == nil && sticky != nil && a.forced == nil {
                    Text("上次").font(.caption2).foregroundStyle(.secondary)
                } else if override == nil && !text.trimmed.isEmpty {
                    Text("自动").font(.caption2).foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Brand.orange.opacity(0.14), in: Capsule())
            .foregroundStyle(Brand.orangeDeep)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help("类型（自动识别；在输入框里按 Tab / Shift+Tab 快速切换）")
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
                Text("↩").font(.caption2).opacity(0.7)
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
            ForEach(a.tags, id: \.self) { chip("number", $0, tint: Brand.orange) }
            if let f = a.folderName { chip("folder", f, tint: Brand.orange) }
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
        case .idea: return "记为想法"
        case .evidence: return "保存为证据"
        case .regulation: return "保存为法规"
        }
    }

    // MARK: - 提交

    private func submit(_ a: CaptureAnalysis, _ k: CaptureKind) {
        guard !submitting, !text.trimmed.isEmpty else { return }
        error = nil
        okText = nil
        // 先记到本机发件箱（立刻返回），写进滴答 / 闪念贝壳在后台做；失败会自动重试，真失败了再提示
        _ = CaptureOutbox.shared.takeSubmitted()   // 清掉之前遗留的，撤销只针对这一次
        do {
            // 选了「新建取证单」：保存证据时一并创建（见 SjzPinStrip.deferNew），提交后清掉
            let pendingNote = k == .evidence ? model.sjzPendingNote.trimmed : ""
            let msg = try CaptureOutbox.shared.submit(a, kind: k, priority: priority, defaultDate: defaultDate, defaultTime: defaultTime, images: images, newNote: pendingNote.isEmpty ? nil : pendingNote, model: model)
            if !pendingNote.isEmpty { model.sjzPendingNote = "" }
            // 记住这次的结审类型，下次打开还是它（非结审类型就回到自动识别）
            if model.hasSjz {
                if k.isSjz { UserDefaults.standard.set(k.rawValue, forKey: Self.stickyKey); sticky = k } else { clearSticky() }
            }
            text = ""
            images = []
            override = nil
            priority = 0
            if let onSubmitted {
                onSubmitted(msg)
            } else if let onDone {
                model.showNotice(msg)
                onDone()
            } else {
                okText = msg
                focusTick += 1
            }
        } catch {
            self.error = "提交失败：" + error.localizedDescription
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
