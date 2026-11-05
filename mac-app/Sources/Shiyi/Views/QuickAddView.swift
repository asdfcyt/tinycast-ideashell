import SwiftUI

/// 便签里的万能输入：文字由便签持有（要存盘），输入框边写边预览 Markdown
struct QuickAddNote {
    var text: Binding<String>
    /// 现在是不是该接收听写 / 麦克风提交的那一张便签（开了好几张时只有一张响应）
    var isActive: () -> Bool
    /// 从笔记 / 结审记录打开的便签：底部由便签自己画来源条，这里不显示识别结果和保存按钮
    var bound = false
    /// 便签的确认条要求保存：值变了就保存一次
    var submitTick = 0
}

/// 万能输入（复刻安卓端）：一个输入框，自动识别是待办 / Daily Note / 笔记。
/// - 前缀强制：`待办 …`、`日记 …`、`笔记 …`
/// - `#标签`；开头写 `@WorkBuddy` / `@opencode` 直接派活；「明天 15:00 开会」「下周五下午3点半 交周报」这类日期时间会被识别成待办
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
    /// 搜索模式 / 分类变化（全局悬浮输入窗用它连同草稿一起留住搜索状态；nil = 不在搜索）
    var onSearchChange: ((SearchFilter?) -> Void)?
    /// 提交成功（参数是结果文案）。设置后不再调 onDone 关闭，而是在输入框下面显示结果，由调用方决定什么时候关（全局悬浮输入窗用）
    var onSubmitted: ((String) -> Void)?
    /// 便签形态：输入框占满整张便签，回车换行（⌘↩ 保存），不写草稿，文字同步给便签
    var note: QuickAddNote?

    @State private var text = ""
    /// 全能搜索：结审 / 闪念贝壳 / 滴答的数据都通过各自的 MCP 取回来
    @StateObject private var search = UniversalSearch()
    /// Tab / 菜单切到了「搜索」（也可以在开头写「ss …」「搜 …」「? …」，写完前缀 + 空格就自动切过去）
    @State private var searchOn = false
    @State private var searchFilter: SearchFilter = .all
    @State private var searchSel = 0
    @AppStorage("search.includeData") private var searchData = false
    @AppStorage("search.currentOnly") private var searchCurrent = false
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
    /// 便签形态下，提示行（识别结果 / 取证单选择）实际排出来的高度
    @State private var hintH: CGFloat = 0
    /// 便签形态下，结审的「去向与关联」默认收起（只留一行），点开才显示取证单 / 线索选择
    @State private var optionsOpen = false

    /// 派活：有可用的 Agent 才出现（便签 / 专注记录里不出现）
    private var agentTargets: [DispatchTarget] { record == nil && note == nil ? DispatchTarget.available : [] }
    private var agentOn: Bool { !agentTargets.isEmpty }
    @AppStorage("dispatch.lastTarget") private var lastTarget = DispatchTarget.workbuddy.rawValue
    @AppStorage("dispatch.opencode.dir") private var ocDir = ""
    @AppStorage("dispatch.opencode.extraDirs") private var ocExtra = ""
    /// opencode 的会话 / 目录：只读缓存，后台刷新
    @ObservedObject private var ocStore = OpenCodeStore.shared
    /// 派活是继续对话还是新开对话（默认新开）
    @State private var continueChat = false
    /// 带进来的资料（右键「派活」）：和指令分开，作为附件交给 Agent
    @State private var material: String?
    @State private var pickedSession: String?
    /// 这段话交给谁：开头 @ 了谁就是谁，否则用上次的
    private func agentTarget(_ a: CaptureAnalysis) -> DispatchTarget {
        if let t = a.agentTarget { return t }
        let list = DispatchTarget.available
        return list.first { $0.rawValue == lastTarget } ?? list.first ?? .workbuddy
    }
    /// opencode 新开对话用的目录：选过的，没选过就是最近一个项目
    private var ocWorkDir: String { ocDir.isEmpty ? (ocStore.dirs.first ?? "") : ocDir }
    /// opencode 继续对话用的会话：选过的，没选过就是最近一个
    private var ocWorkSession: OpenCodeSession? { ocStore.sessions.first { $0.id == pickedSession } ?? ocStore.sessions.first }

    /// 搜索关键词：开头写了「搜 …」，或者 Tab / 菜单切到了搜索；不是搜索时为 nil（便签 / 专注记录里没有搜索）
    private var searchQuery: String? {
        guard record == nil, note == nil else { return nil }
        let t = String(ComposerImage.stripMarker(text).drop(while: { $0.isWhitespace }))
        if searchOn { return t.trimmed }
        if let p = SearchFilter.parsePrefix(t) { return p.rest.trimmed }
        return nil
    }
    private var searchActive: Bool { searchQuery != nil }
    /// 「全部」里每个来源最多列几条（免得某一个来源把别的挤到下面看不见）；单选某个分类时全列
    private static let perSourceCap = 8
    private var searchVisible: [SearchItem] {
        if searchFilter != .all { return search.items.filter { searchFilter.matches($0) } }
        var counts: [SearchItem.Source: Int] = [:]
        var out: [SearchItem] = []
        for it in search.items {
            let n = counts[it.source, default: 0]
            if n < Self.perSourceCap { out.append(it); counts[it.source] = n + 1 }
        }
        return out
    }
    private var searchHidden: Int { searchFilter == .all ? max(search.items.count - searchVisible.count, 0) : 0 }

    private var analysis: CaptureAnalysis { CaptureParser.analyze(text, sjz: model.hasSjz, agents: agentTargets, light: override == .agent) }
    /// 自动识别的类型：贴了图片又没写前缀，按「笔记」处理（图片作为附件）；没连闪念贝壳才退到结审「证据」。
    /// 想存证据 / 线索，用前缀或 Tab 手动选
    private func autoKind(_ a: CaptureAnalysis) -> CaptureKind {
        guard !images.isEmpty else { return a.recommended }
        if model.hasIdeashell { return .note }
        return model.hasSjz ? .evidence : a.recommended
    }
    private func kind(_ a: CaptureAnalysis) -> CaptureKind {
        // 开头明确 @ 了 Agent（或写了「派活」）：以文字为准。否则残留的手动类型会把 @wb 开头的内容按 Daily Note 存掉（@wb 已被剥掉）
        if a.forced == .agent { return .agent }
        return override ?? a.forced ?? sticky ?? autoKind(a)
    }
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
                    do {
                        ComposerTextView(
                            text: $text,
                            images: $images,
                            contentHeight: $contentH,
                            allowsImages: (model.hasSjz || model.hasIdeashell) && record == nil,
                            markdown: note != nil,
                            fontSize: note != nil ? 14 : (compact ? 14 : 16),
                            focusTick: focusTick,
                            onSubmit: note == nil ? { submitFromKeyboard() } : nil,
                            onTab: { reverse in cycleKind(reverse: reverse) },
                            onBackspaceEmpty: { exitKind() },
                            onMove: { moveSearch($0) }
                        )
                        if text.isEmpty {
                            Text(searchActive ? searchPlaceholder : note != nil ? "写点什么…支持 Markdown" : (k == .agent ? (material != nil ? "对这份资料做什么？留空 = 让 \(agentTarget(a).title) 处理它" : "让 \(agentTarget(a).title) 做点什么…") : record != nil ? "专注时的想法、进展、卡点…" : (compact ? "记点什么…（Tab 切换类型）" : (model.hasSjz ? "记点什么？按 Tab 切换 想法 / 证据 / 法规 / 线索" : "记点什么？待办、想法、日记都可以，Tab 切换类型"))))
                                .font(.system(size: note != nil ? 14 : (compact ? 14 : 16)))
                                .foregroundStyle(.secondary)
                                .padding(.top, 2)
                                .allowsHitTesting(false)
                        }
                    }
                }
                .frame(height: note != nil ? nil : (compact ? max(editorHeight, 70) : editorHeight))
                .frame(maxHeight: note != nil ? .infinity : nil)
            }
            .frame(maxHeight: note != nil ? .infinity : nil)
            .padding(.horizontal, compact ? 12 : 18).padding(.top, compact ? 8 : 14)

            // 搜索：结果列表代替提示行
            if let q = searchQuery {
                QuickSearchResults(engine: search, query: q, visible: searchVisible, filter: $searchFilter, selection: $searchSel,
                                   compact: compact, hidden: searchHidden,
                                   onOpen: { openSearchResult($0, inSjz: $1) })
                    .padding(.horizontal, compact ? 12 : 18).padding(.top, 8)
            }

            // 提示行：空的时候给几个例子，写了字就显示识别结果
            if searchQuery == nil, note?.bound != true, k != .agent {
                hintRow(a, k)
                    .padding(.horizontal, compact ? 12 : 18).padding(.top, 6)
            }

            if searchQuery == nil, k == .agent, let m = material {
                materialChip(m)
                    .padding(.horizontal, compact ? 12 : 18).padding(.top, 6)
            }

            if let error {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    .padding(.horizontal, compact ? 12 : 18).padding(.top, 4)
            } else if let okText {
                Label(okText, systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
                    .padding(.horizontal, compact ? 12 : 18).padding(.top, 4)
            }

            if compact, note == nil { Divider().opacity(0.6).padding(.top, 12) }

            // 底栏：类型 + 优先级 + 提交
            if searchActive {
                searchFooter
                    .padding(.horizontal, compact ? 12 : 14).padding(.top, compact ? 8 : 8).padding(.bottom, compact ? 8 : 12)
            } else if note?.bound != true {
                footer(a, k)
                    .padding(.horizontal, compact ? 12 : 14).padding(.top, compact ? 8 : 8).padding(.bottom, compact ? 8 : 12)
            }
        }
        .frame(width: compact ? nil : 480)
        .frame(maxHeight: note != nil ? .infinity : nil)
        .onChange(of: override) { _, new in onKindChange?(new) }
        .onChange(of: searchOn) { _, on in onSearchChange?(on ? searchFilter : nil) }
        .onChange(of: searchFilter) { _, f in if searchOn { onSearchChange?(f) } }
        .onChange(of: searchQuery) { _, _ in triggerSearch() }
        .onChange(of: searchData) { _, _ in triggerSearch() }
        .onChange(of: searchCurrent) { _, _ in triggerSearch() }
        .onChange(of: search.items) { _, _ in
            let n = searchVisible.count
            if searchSel >= n { searchSel = max(n - 1, 0) }
        }
        .onChange(of: searchFilter) { _, _ in searchSel = 0 }
        // 语音听写（麦克风按钮，或输入窗开着时按语音快捷键）：说的话追加到输入框，可以直接说「证据，…」「想法，…」带类型口令
        .onChange(of: model.quickAddInsert) { _, new in
            guard !new.isEmpty, record == nil else { return }
            if let note, !note.isActive() { return }
            model.quickAddInsert = ""
            text = Self.joined(text, new)
            focusTick += 1
        }
        // 猛犸麦克风三击:提交输入框里的内容
        .onReceive(NotificationCenter.default.publisher(for: .micQuickAddSubmit)) { _ in
            if record == nil, !text.trimmed.isEmpty, note?.isActive() ?? true { submitFromKeyboard() }
        }
        .onChange(of: note?.submitTick ?? 0) { _, _ in
            if note?.bound != true, !text.trimmed.isEmpty { submitFromKeyboard() }
        }
        .onChange(of: text) { _, new in
            // 开头写了搜索前缀（ss / sj / sn / sd / sr / 搜 / ?）加空格：直接切到搜索，前缀不留在输入框里
            if record == nil, note == nil, !searchOn, let p = SearchFilter.parsePrefix(new) {
                searchOn = true
                searchFilter = p.filter
                searchSel = 0
                override = nil
                text = p.rest
                return
            }
            if let record, record.recordDraft != new { record.recordDraft = new }
            onDraftChange?(ComposerImage.stripMarker(new))
            if let note {
                let plain = ComposerImage.stripMarker(new)
                if note.text.wrappedValue != plain { note.text.wrappedValue = plain }
            }
        }
        // 便签那边改了文字（比如勾选了清单）：同步回输入框
        .onChange(of: note?.text.wrappedValue ?? "") { _, new in
            if note != nil, new != ComposerImage.stripMarker(text) { text = new; images = [] }
        }
        .onAppear {
            if let note {
                text = note.text.wrappedValue
                if text.isEmpty { focusTick += 1 }
                model.sjzError = nil
                return
            }
            focusTick += 1
            if agentOn { ocStore.refresh(after: 1.5) }
            if let record { text = record.recordDraft }
            if !model.quickAddText.isEmpty { text = model.quickAddText }
            material = model.quickAddMaterial
            model.quickAddMaterial = nil
            override = model.quickAddKind
            if record == nil, let f = model.quickAddSearch { searchOn = true; searchFilter = f; override = nil }
            model.quickAddSearch = nil
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
            if searchActive { triggerSearch() }
        }
    }

    // MARK: - 提示行 / 底栏

    @ViewBuilder private func hintRowContent(_ a: CaptureAnalysis, _ k: CaptureKind) -> some View {
        if let record {
            recordHint(record)
        } else if k.isSjz {
            sjzTarget(a, k)
        } else if k == .agent {
            EmptyView()
        } else if text.trimmed.isEmpty {
            if note != nil {
                Text("⇥ 切换类型 · ⌘↩ 保存").font(.caption2).foregroundStyle(.tertiary)
            } else {
                examples
            }
        } else {
            recognized(a, k)
        }
    }

    @ViewBuilder private func hintRow(_ a: CaptureAnalysis, _ k: CaptureKind) -> some View {
        if note != nil, k.isSjz {
            // 结审：去向 / 关联是一大块（取证单、线索搜索），便签里默认收成一行，点开再选，免得压住文字
            VStack(alignment: .leading, spacing: 6) {
                Button { withAnimation(.easeOut(duration: 0.15)) { optionsOpen.toggle() } } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.right").font(.system(size: 8.5, weight: .bold))
                            .rotationEffect(.degrees(optionsOpen ? 90 : 0))
                        Text("去向与关联").font(.caption.weight(.medium))
                        Text(model.sjzTargetTitle.isEmpty ? "未选择项目" : model.sjzTargetTitle)
                            .font(.caption).foregroundStyle(Color.indigo).lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if optionsOpen {
                    ScrollView(.vertical) {
                        hintRowContent(a, k)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .background(GeometryReader { g in Color.clear.preference(key: HintHeightKey.self, value: g.size.height) })
                    }
                    .scrollIndicators(.hidden)
                    .frame(height: min(max(hintH, 24), 150))
                    .onPreferenceChange(HintHeightKey.self) { hintH = $0 }
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        } else if note != nil {
            hintRowContent(a, k)
                .frame(maxWidth: .infinity, minHeight: 20, alignment: .topLeading)
        } else {
            // 搜索已有证据 / 法规 / 线索会把这一行撑高：必须放在 frame 外面固定高度，否则窗口还没长高时这一行会被压回一行，列表溢出去盖住底栏
            hintRowContent(a, k)
                .frame(maxWidth: .infinity, minHeight: 24, alignment: .topLeading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private func footer(_ a: CaptureAnalysis, _ k: CaptureKind) -> some View {
        if note != nil {
            // 便签窄：一行放不下就分成两行（类型 / 优先级 在上，听写 / 保存 在下）
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    kindControls(a, k, withProject: false)
                    Spacer(minLength: 8)
                    dictateButton
                    submitButton(a, k)
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) { kindControls(a, k, withProject: false); Spacer(minLength: 0) }
                    HStack(spacing: 8) { Spacer(minLength: 0); dictateButton; submitButton(a, k) }
                }
            }
        } else {
            HStack(spacing: 8) {
                if let record {
                    taskChip(record)
                } else {
                    kindControls(a, k)
                }
                Spacer(minLength: 8)
                if record == nil { dictateButton }
                if let onDone {
                    // 不占位置：只保留 Esc 取消
                    Button("取消", action: onDone)
                        .keyboardShortcut(.cancelAction)
                        .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
                }
                if let record { recordSubmitButton(record) } else { submitButton(a, k) }
            }
        }
    }

    @ViewBuilder private func kindControls(_ a: CaptureAnalysis, _ k: CaptureKind, withProject: Bool = true) -> some View {
        kindMenu(a, k)
        if k == .todo { priorityMenu }
        if k.isSjz, withProject { sjzChip(k) }
        if k == .agent { agentModeMenu(a) }
    }

    // MARK: - 组件

    /// 开启结审后，示例里带上线索 / 想法 / 证据 / 法规前缀
    private var exampleList: [String] {
        if model.hasSjz { return compact ? ["明天 15:00 开会", "想法 …", "证据 …", "ss …"] : ["明天 15:00 开会", "想法 …", "证据 …", "线索 …", "ss …"] }
        return agentOn ? ["明天 15:00 开会", "#读书 一句话想法", "@\(DispatchTarget.available[0].title) …", "ss …"] : ["明天 15:00 开会", "#读书 一句话想法", "ss …"]
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
                Text("\(images.count) 张图片 · " + (k.isSjz ? "按在文字里的位置混排保存" : "作为附件保存")).font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 派活（把这段话交给 Agent）

    /// 带进来的资料：一行预览 + 字数，可以去掉
    private func materialChip(_ m: String) -> some View {
        let one = m.replacingOccurrences(of: "\n", with: " ").trimmed
        return HStack(spacing: 6) {
            Image(systemName: "paperclip").font(.system(size: 10, weight: .semibold))
            Text(one).lineLimit(1).truncationMode(.tail)
            Text("\(m.count) 字").foregroundStyle(.tertiary).fixedSize()
            Spacer(minLength: 0)
            Button { material = nil } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("不带这份资料")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    /// 底栏：继续对话还是新开对话（颜色就是接活的 Agent）
    private func agentModeMenu(_ a: CaptureAnalysis) -> some View {
        let t = agentTarget(a)
        let session = ocWorkSession
        let icon: String
        let label: String
        // 只有 WorkBuddy（当前对话）和 opencode（会话列表）能在这里选「继续」；其他命令行接着聊走验收卡上的追问
        let canContinue = t == .opencode || t == .workbuddy
        if continueChat && canContinue {
            icon = "text.bubble"
            label = t == .opencode ? "继续 · " + (session?.displayTitle ?? "无会话") : "继续对话"
        } else {
            icon = "plus.bubble"
            label = t.isCommand ? "新开 · " + (ocWorkDir.isEmpty ? "选择文件夹" : (ocWorkDir as NSString).lastPathComponent) : "新开对话"
        }
        return Menu {
            if t.isCommand {
                Section("新开对话") {
                    ForEach(ocDirChoices, id: \.self) { d in
                        Button {
                            ocDir = d
                            continueChat = false
                        } label: {
                            let n = (d as NSString).lastPathComponent
                            if !continueChat && d == ocWorkDir { Label(n, systemImage: "checkmark") } else { Label(n, systemImage: "folder") }
                        }
                        .help(d)
                    }
                    Button("选择文件夹…") { chooseOpenCodeDir() }
                }
                if t == .opencode, !ocStore.sessions.isEmpty {
                    Section("继续对话") {
                        ForEach(ocStore.sessions.prefix(8)) { s in
                            Button {
                                pickedSession = s.id
                                continueChat = true
                            } label: {
                                let n = s.displayTitle + " · " + s.dirName
                                if continueChat && s.id == session?.id { Label(n, systemImage: "checkmark") } else { Label(n, systemImage: "text.bubble") }
                            }
                        }
                    }
                }
            } else {
                Button { continueChat = false } label: {
                    if !continueChat { Label("新开对话", systemImage: "checkmark") } else { Label("新开对话", systemImage: "plus.bubble") }
                }
                Button { continueChat = true } label: {
                    if continueChat { Label("继续当前对话", systemImage: "checkmark") } else { Label("继续当前对话", systemImage: "text.bubble") }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 11, weight: .semibold))
                Text(label).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.tail)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(t.color.opacity(0.14), in: Capsule())
            .foregroundStyle(t.color)
            .frame(maxWidth: 240, alignment: .leading)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
        // 地方不够时先压它：名字截断，不换行；发送键和类型保持完整
        .fixedSize(horizontal: false, vertical: true)
        .layoutPriority(-1)
    }

    /// 候选目录：当前选的 + 自己选过的 + opencode 最近用过的项目
    private var ocDirChoices: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for d in [ocWorkDir] + ocExtra.split(separator: "\n").map(String.init) + ocStore.dirs where !d.isEmpty && seen.insert(d).inserted { out.append(d) }
        return out
    }

    private func chooseOpenCodeDir() {
        let floating = onSubmitted != nil // 悬浮输入窗：弹出文件夹选择会让它失焦收起，选完再唤出来
        // 悬浮窗里的菜单项一点就触发：交给统一的选择器（可新建文件夹，并等菜单收起后再弹）
        FolderPicker.pick(title: "选择工作目录", start: ocWorkDir) { path in
            if let path {
                ocDir = path
                continueChat = false
                var extra = ocExtra.split(separator: "\n").map(String.init).filter { $0 != path }
                extra.insert(path, at: 0)
                ocExtra = extra.prefix(6).joined(separator: "\n")
            }
            if floating { QuickAddPanelController.shared.show() }
        }
    }

    private func submitAgent(_ a: CaptureAnalysis) {
        let prompt = ComposerImage.stripMarker(a.text).trimmed
        guard !prompt.isEmpty || material != nil else { return }
        let target = agentTarget(a)
        let continuing = continueChat && (target == .opencode || target == .workbuddy)
        var plan = DispatchPlan(target: target, fresh: !continuing)
        plan.material = material
        var place = ""
        if target.isCommand {
            if continuing {
                guard let s = ocWorkSession else { error = "没有可以继续的 opencode 会话"; return }
                plan.session = s
                place = s.dirName
            } else {
                guard !ocWorkDir.isEmpty else { error = "先选一个文件夹（底栏左边的按钮）"; return }
                plan.dir = ocWorkDir
                place = (ocWorkDir as NSString).lastPathComponent
            }
        }
        lastTarget = target.rawValue
        text = ""
        material = nil
        images = []
        override = nil
        priority = 0
        Task {
            let r = await DispatchCenter.shared.send(prompt, plan: plan)
            if !r.ok { Notifier.post(id: "dispatch.fail", title: "派给 \(target.title) 失败", body: r.message) }
        }
        let msg = "已派给 \(target.title)" + (place.isEmpty ? "" : " · " + place)
        if let onSubmitted {
            onSubmitted(msg)
        } else if let onDone {
            model.showNotice(msg)
            onDone()
        } else {
            okText = msg
            focusTick += 1
        }
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
        var steps: [CaptureKind?] = model.hasSjz ? [nil, .idea, .evidence, .regulation, .clue] : [nil, .todo, .daily, .note]
        if agentOn { steps.append(.agent) }
        // 最后多一格「搜索」（便签里没有）：自动 → … → 派活 → 搜索 → 自动
        let canSearch = note == nil
        let total = steps.count + (canSearch ? 1 : 0)
        let cur: Int
        if searchActive { cur = steps.count } else {
            let k: CaptureKind? = override ?? analysis.forced ?? sticky
            cur = steps.firstIndex { $0 == k } ?? 0
        }
        let next = (cur + (reverse ? total - 1 : 1)) % total
        if canSearch, next == steps.count {
            searchOn = true
            override = nil
        } else {
            leaveSearch()
            override = steps[next]
            if steps[next] == nil { clearSticky() }
        }
    }

    /// 输入框是空的还按删除键：退出 Tab 选的类型，回到自动识别
    private func exitKind() -> Bool {
        if searchOn, text.isEmpty { searchOn = false; searchFilter = .all; return true }
        guard record == nil, override != nil || sticky != nil else { return false }
        override = nil
        clearSticky()
        return true
    }

    private func submitFromKeyboard() {
        if searchActive {
            openSelectedResult(inSjz: NSApp.currentEvent?.modifierFlags.contains(.command) == true)
            return
        }
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
            ForEach(CaptureKind.available(sjz: model.hasSjz, agent: agentOn)) { c in
                Button {
                    if c == autoKind(a) && a.forced == nil { override = nil; clearSticky() } else { override = c }
                } label: {
                    if c == k { Label(c.rawValue, systemImage: "checkmark") } else { Label(c.rawValue, systemImage: c.icon) }
                }
            }
            if note == nil, record == nil {
                Divider()
                Button { searchOn = true; override = nil } label: { Label("搜索（ss）", systemImage: "magnifyingglass") }
            }
            if override != nil || sticky != nil {
                Divider()
                Button("恢复自动识别") { override = nil; clearSticky() }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: k.icon).font(.system(size: 12, weight: .semibold))
                Text(k.rawValue).font(.callout.weight(.medium))
                if note != nil {
                    // 便签窄：只在自动识别时用一个小点表示「自动」，省出位置
                    if override == nil && !text.trimmed.isEmpty { Image(systemName: "sparkle").font(.system(size: 7.5, weight: .bold)).opacity(0.5) }
                } else if override == nil && sticky != nil && a.forced == nil {
                    Text("上次").font(.caption2).foregroundStyle(.secondary)
                } else if override == nil && !text.trimmed.isEmpty {
                    Text("自动").font(.caption2).foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, note != nil ? 9 : 10).padding(.vertical, 4)
            .background(note != nil ? Color.primary.opacity(0.08) : Brand.orange.opacity(0.14), in: Capsule())
            .foregroundStyle(note != nil ? Color.primary.opacity(0.78) : Brand.orangeDeep)
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
                if note == nil || priority != 0 {
                    Text(priority == 0 ? "优先级" : (priority == 5 ? "高" : (priority == 3 ? "中" : "低"))).font(.callout)
                }
            }
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(Color.primary.opacity(0.06), in: Capsule())
            .foregroundStyle(.secondary)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
    }

    private func submitButton(_ a: CaptureAnalysis, _ k: CaptureKind) -> some View {
        let disabled = submitting || (text.trimmed.isEmpty && !(k == .agent && material != nil))
        return Button {
            submit(a, k)
        } label: {
            HStack(spacing: 6) {
                if submitting { ProgressView().controlSize(.small) } else { Text(submitLabel(k, a)).font(.callout.weight(.semibold)).lineLimit(1).fixedSize() }
                if note == nil { Text("↩").font(.caption2).opacity(0.7) }
            }
            .foregroundStyle(note != nil && disabled ? Color.primary.opacity(0.35) : .white)
            .padding(.horizontal, 12).padding(.vertical, 5)
            // 便签里不用主题橙：深墨色，和纸色一起看着更安静
            .background(note != nil ? (disabled ? Color.primary.opacity(0.08) : Color.primary.opacity(0.78)) : Brand.orange.opacity(disabled ? 0.35 : 1), in: Capsule())
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
            if k == .daily { chip("clock", "追加到今天的 Daily Note", tint: .secondary) }
            if k == .note && a.tags.isEmpty { chip("doc.text", "新建一条笔记", tint: .secondary) }
            Spacer(minLength: 0)
        }
        .font(.caption)
    }

    private func chip(_ icon: String, _ label: String, tint rawTint: Color) -> some View {
        let tint = note != nil ? Color.primary.opacity(0.62) : rawTint
        return HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 10))
            Text(label).lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(tint.opacity(0.1), in: Capsule())
    }

    private func submitLabel(_ k: CaptureKind, _ a: CaptureAnalysis) -> String {
        if note != nil {
            switch k {
            case .daily: return "记入日记"
            case .evidence: return "存为证据"
            case .regulation: return "存为法规"
            default: break
            }
        }
        switch k {
        case .todo: return "添加待办"
        case .daily: return "记入 Daily Note"
        case .note: return "保存笔记"
        case .clue: return "记为线索"
        case .idea: return "记为想法"
        case .evidence: return "保存为证据"
        case .regulation: return "保存为法规"
        case .agent: return "派给 \(agentTarget(a).title)"
        }
    }

    // MARK: - 全能搜索

    private func triggerSearch() {
        guard let q = searchQuery else { search.reset(); searchSel = 0; return }
        searchSel = 0
        search.update(q, model: model, includeData: searchData, currentOnly: searchCurrent)
    }

    /// 上 / 下方向键：在结果里挪选中项（只在搜索时接管，其他时候照常移动光标）
    private func moveSearch(_ dir: Int) -> Bool {
        guard searchActive else { return false }
        let n = searchVisible.count
        guard n > 0 else { return true }
        searchSel = (searchSel + dir + n) % n
        return true
    }

    private func openSelectedResult(inSjz: Bool) {
        let list = searchVisible
        guard list.indices.contains(searchSel) else { return }
        openSearchResult(list[searchSel], inSjz: inSjz)
    }

    private func openSearchResult(_ item: SearchItem, inSjz: Bool) {
        model.openSearchItem(item, inSjzApp: inSjz)
        text = ""
        images = []
        searchOn = false
        searchFilter = .all
        search.reset()
        // 输入窗马上就收起，onChange 来不及触发：直接告诉它「打开结果后不用再恢复搜索」
        onDraftChange?("")
        onSearchChange?(nil)
        if let onDone { onDone() } else { focusTick += 1 }
    }

    /// 退出搜索：去掉开头的「搜 」前缀（输入框里留着原来的关键词），关掉搜索开关
    private func leaveSearch() {
        searchOn = false
        searchFilter = .all
        if let p = SearchFilter.parsePrefix(text) { text = p.rest }
    }

    private var searchPlaceholder: String {
        switch searchFilter {
        case .all: return "搜索" + [model.hasSjz ? "结审" : nil, model.hasIdeashell ? "笔记" : nil, "待办", model.hasIdeashell ? "日记" : nil].compactMap { $0 }.joined(separator: "、") + "…"
        case .sjz: return "搜索结审（任务、文书、取证单、线索、法规）…"
        case .note: return "搜索闪念贝壳笔记…"
        case .todo: return "搜索滴答 / 闪念待办…"
        case .daily: return "搜索 Daily Note 里的日记…"
        }
    }

    /// 搜索范围开关：关着只有图标（悬停看说明），开着显示文字
    private func searchToggle(_ icon: String, _ label: String, on: Binding<Bool>, help: String) -> some View {
        Button { on.wrappedValue.toggle() } label: {
            HStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 10.5))
                if !compact, on.wrappedValue { Text(label).lineLimit(1) }
            }
            .font(.caption)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(on.wrappedValue ? Color.indigo.opacity(0.14) : Color.primary.opacity(0.06), in: Capsule())
            .foregroundStyle(on.wrappedValue ? Color.indigo : Color.secondary)
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help(help)
    }

    private var searchFooter: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(CaptureKind.available(sjz: model.hasSjz, agent: agentOn)) { c in
                    Button { leaveSearch(); override = c } label: { Label(c.rawValue, systemImage: c.icon) }
                }
                Divider()
                Button("退出搜索") { leaveSearch(); override = nil }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .semibold))
                    Text("搜索").font(.callout.weight(.medium))
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(Color.indigo.opacity(0.14), in: Capsule())
                .foregroundStyle(Color.indigo)
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .help("正在搜索（⇥ 切换类型，也可以改成记录）")
            if model.hasSjz {
                if !model.sjzTargetTitle.isEmpty {
                    searchToggle("scope", "当前项目", on: $searchCurrent, help: "只搜结审里钉住的项目「\(model.sjzTargetTitle)」")
                }
                searchToggle("cylinder.split.1x2", "数据中心", on: $searchData, help: "同时搜索数据中心的表结构和表内数据（涉及原始数据，默认不搜）")
            }
            Spacer(minLength: 8)
            dictateButton
            if let onDone {
                Button("取消", action: onDone)
                    .keyboardShortcut(.cancelAction)
                    .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
            }
            let disabled = searchVisible.isEmpty
            Button { openSelectedResult(inSjz: false) } label: {
                HStack(spacing: 6) {
                    Text("打开").font(.callout.weight(.semibold)).lineLimit(1).fixedSize()
                    Text("↩").font(.caption2).opacity(0.7)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(Brand.orange.opacity(disabled ? 0.35 : 1), in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(disabled)
        }
    }

    // MARK: - 提交

    private func submit(_ a: CaptureAnalysis, _ k: CaptureKind) {
        guard !submitting, !text.trimmed.isEmpty || (k == .agent && material != nil) else { return }
        error = nil
        okText = nil
        if k == .agent { submitAgent(a); return }
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

private struct HintHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
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
