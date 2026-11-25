import AppKit
import NaturalLanguage
import SwiftUI
import Translation

/*
 * 阅读器里的「翻译」和「AI」。
 * · 翻译：默认用设置里的 AI 模型翻译（质量好、懂上下文）；也可选 macOS 自带的 Translation（本机离线，文字不出这台 Mac）。
 *   版式参考「沉浸式翻译」——译文跟在原文每一段下面。译文按文章存在本机，翻过的段落下次打开直接带出，不再重翻。
 * · AI：底部悬浮条，会把当前文章的文字发给设置里的 AI 服务，所以只在你点了按钮之后才发，
 *   财新 / 三联这类付费内容首次使用前会先说明并要你确认；正文不保存，只存译文和摘要。
 * · AI 摘要：做成卡片放在文章最上面，存在本机，下次打开这篇文章还在。
 */

// MARK: - 翻译（挂在页面里的隐形宿主：Translation 的会话只能从 SwiftUI 视图里拿到）

@available(macOS 15.0, *)
struct ReaderTranslateHost: View {
    @ObservedObject var reader: ReaderController
    @State private var config: TranslationSession.Configuration?

    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .translationTask(config) { session in await run(session) }
            .onChange(of: reader.translateTick) { _, _ in start() }
    }

    private func start() {
        let items = reader.pendingItems
        guard !items.isEmpty else { reader.translateFinished(nil); return }
        // 先自己判断原文语言：已经是中文就不用翻；判断不出来再交给系统
        let sample = String(items.map(\.1).joined(separator: " ").prefix(2000))
        let rec = NLLanguageRecognizer()
        rec.processString(sample)
        let code = rec.dominantLanguage?.rawValue
        if let code, code.hasPrefix("zh") {
            reader.translateFinished("这一页已经是中文")
            return
        }
        let src = code.map { Locale.Language(identifier: $0) }
        let target = Locale.Language(identifier: "zh-Hans")
        if config != nil, config?.source == src { config?.invalidate(); return }
        var cfg = TranslationSession.Configuration(source: src, target: target)
        // macOS 26.4 起可选「高保真」策略：读文章不赶时间，译文质量优先
        if #available(macOS 26.4, *) { cfg = .init(source: src, target: target, preferredStrategy: .highFidelity) }
        config = cfg
    }

    private func run(_ session: TranslationSession) async {
        let items = await MainActor.run { reader.pendingItems }
        guard !items.isEmpty else { return }
        let reqs = items.map { TranslationSession.Request(sourceText: $0.1, clientIdentifier: String($0.0)) }
        var buf: [(Int, String)] = []
        do {
            // 边译边显示：每译好几段就贴回页面一次
            for try await r in session.translate(batch: reqs) {
                if let id = r.clientIdentifier, let i = Int(id) { buf.append((i, r.targetText)) }
                if buf.count >= 4 {
                    let part = buf
                    buf = []
                    await MainActor.run { reader.putTranslations(part) }
                }
            }
            let rest = buf
            await MainActor.run {
                reader.putTranslations(rest)
                reader.translateFinished(nil)
            }
        } catch {
            let msg = (error as? TranslationError)?.errorDescription ?? error.localizedDescription
            await MainActor.run { reader.translateFinished("翻译没有完成：" + msg) }
        }
    }
}

/// 没有 macOS 15 的 Translation 时的占位（部署目标是 macOS 14）
struct ReaderTranslateHostCompat: View {
    @ObservedObject var reader: ReaderController
    var body: some View {
        if #available(macOS 15.0, *) {
            ReaderTranslateHost(reader: reader)
        } else {
            Color.clear.frame(width: 0, height: 0)
                .onChange(of: reader.translateTick) { _, _ in reader.translateFinished("翻译需要 macOS 15 或更新的系统") }
        }
    }
}

// MARK: - 付费内容的确认（翻译和 AI 共用）

enum ReaderAIGate {
    static func isPaid(_ url: URL?) -> Bool {
        let h = url?.host ?? ""
        return h.hasSuffix("caixin.com") || h.hasSuffix("lifeweek.com.cn")
    }

    static func ackKey(_ url: URL?) -> String {
        "reader.ai.ack." + ((url?.host ?? "").hasSuffix("caixin.com") ? "caixin" : "lifeweek")
    }

    /// 财新 / 三联：第一次把正文交给 AI 之前说明并确认；其它站点直接放行
    @MainActor static func confirm(_ url: URL?, action: String) -> Bool {
        guard isPaid(url) else { return true }
        if UserDefaults.standard.bool(forKey: ackKey(url)) { return true }
        let host = URL(string: AppModel.current?.llmBaseUrl ?? "")?.host ?? "你设置的 AI 服务"
        let a = NSAlert()
        a.messageText = "把这篇付费文章交给 AI \(action)？"
        a.informativeText = "这是付费订阅内容。继续后，当前文章的文字会发送到 \(host)（你在设置里配置的服务）；拾忆不保存正文，也不会自动发送。文章受版权保护，仅限你个人阅读辅助，请勿转发或公开 AI 生成的全文。"
        a.addButton(withTitle: "继续")
        a.addButton(withTitle: "取消")
        guard a.runModal() == .alertFirstButtonReturn else { return false }
        UserDefaults.standard.set(true, forKey: ackKey(url))
        return true
    }
}

// MARK: - AI 翻译（流式：边生成边贴回页面）

/// 把模型流式吐出的「[编号] 译文」逐行解析出来
private struct TrStream {
    var buf = ""
    var cur: Int?
    var text = ""

    /// 喂入新片段；返回这次刚刚写完整的段落（编号从 1 开始）
    mutating func feed(_ s: String) -> [(Int, String)] {
        buf += s
        var out: [(Int, String)] = []
        while let nl = buf.firstIndex(of: "\n") {
            let line = String(buf[..<nl])
            buf.removeSubrange(...nl)
            if let c = consume(line) { out.append(c) }
        }
        return out
    }

    mutating func finish() -> [(Int, String)] {
        var out: [(Int, String)] = []
        if !buf.isEmpty {
            let line = buf
            buf = ""
            if let c = consume(line) { out.append(c) }
        }
        if let c = commit() { out.append(c) }
        return out
    }

    private mutating func consume(_ line: String) -> (Int, String)? {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return nil }
        if let m = Self.marker(t) {
            let prev = commit()
            cur = m.0
            text = m.1
            return prev
        }
        if cur != nil { text += (text.isEmpty ? "" : " ") + t }
        return nil
    }

    private mutating func commit() -> (Int, String)? {
        defer { cur = nil; text = "" }
        guard let c = cur else { return nil }
        let t = text.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : (c, t)
    }

    /// 正在生成、还没写完的那一段（给页面做「打字」效果）
    func live() -> (Int, String)? {
        let t = buf.trimmingCharacters(in: .whitespaces)
        if let m = Self.marker(t) { return m.1.isEmpty ? nil : m }
        guard let c = cur else { return nil }
        var s = text
        if !t.isEmpty && !t.hasPrefix("[") { s += (s.isEmpty ? "" : " ") + t }
        s = s.trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? nil : (c, s)
    }

    static func marker(_ t: String) -> (Int, String)? {
        guard t.hasPrefix("["), let close = t.firstIndex(of: "]"),
              let n = Int(t[t.index(after: t.startIndex) ..< close]) else { return nil }
        return (n, String(t[t.index(after: close)...]).trimmingCharacters(in: .whitespaces))
    }
}

extension ReaderController {
    func translateWithAI(_ todo: [(Int, String)]) async {
        guard let model = AppModel.current, model.hasLlm else {
            translateFinished("先到「设置」里填写 AI 模型的 API Key（或在菜单里选「本机翻译」）")
            return
        }
        guard ReaderAIGate.confirm(url, action: "翻译") else { translateFinished(nil); return }
        let llm = model.llm
        let gen = trGen
        // 第一块切小一点：很快就能看到开头的译文；后面的块大一些，少发几次请求
        var chunks: [[(Int, String)]] = []
        var cur: [(Int, String)] = []
        var size = 0
        for it in todo {
            let maxChars = chunks.isEmpty ? 900 : 2800
            let maxCount = chunks.isEmpty ? 6 : 20
            if !cur.isEmpty && (size + it.1.count > maxChars || cur.count >= maxCount) { chunks.append(cur); cur = []; size = 0 }
            cur.append(it)
            size += it.1.count
        }
        if !cur.isEmpty { chunks.append(cur) }

        let emit: @Sendable ([(Int, String)], [(Int, String)]) async -> Void = { [weak self] part, fin in
            await MainActor.run { self?.applyStreamed(part, fin, gen: gen) }
        }
        var failed: String?
        var next = 0
        await withTaskGroup(of: String?.self) { group in
            func add() {
                guard next < chunks.count else { return }
                let c = chunks[next]
                next += 1
                group.addTask { await ReaderController.translateChunk(c, llm, emit: emit) }
            }
            for _ in 0 ..< min(3, chunks.count) { add() }
            for await err in group {
                if let err { failed = err }
                add()
            }
        }
        guard gen == trGen else { return }
        translateFinished(failed.map { "部分段落没翻成功：" + $0 })
    }

    /// 流式译文贴回页面：part 是还在生成的半段（只显示），fin 是已经写完的段落（显示并存起来）
    func applyStreamed(_ part: [(Int, String)], _ fin: [(Int, String)], gen: Int) {
        guard gen == trGen else { return }
        putTranslations(part, store: false)
        putTranslations(fin)
    }

    /// 翻一块：流式读取，边生成边通过 emit 交出去；返回错误信息（没有错误为 nil）
    nonisolated static func translateChunk(_ chunk: [(Int, String)], _ llm: LlmClient, retry: Bool = true,
                                           emit: @escaping @Sendable ([(Int, String)], [(Int, String)]) async -> Void) async -> String? {
        let user = chunk.enumerated().map { "[\($0.offset + 1)] \($0.element.1)" }.joined(separator: "\n")
        let system = "你是专业译者。用户给出若干编号段落，格式为「[编号] 原文」。把每一段翻译成流畅、准确、符合中文阅读习惯的简体中文；保留专有名词、数字和代码，人名和术语首次出现可括注原文；只翻译，不解释。严格按输入顺序逐段输出，格式与输入一致：「[编号] 译文」，一段占一行，不要漏段、不要合并、不要输出任何其他内容。"
        var parser = TrStream()
        var doneIdx = Set<Int>()
        var lastFlush = Date.distantPast
        func map(_ l: [(Int, String)]) -> [(Int, String)] {
            l.compactMap { n, t in (1 ... chunk.count).contains(n) ? (chunk[n - 1].0, t) : nil }
        }
        do {
            for try await d in llm.streamText(system: system, user: user) {
                let fin = map(parser.feed(d))
                var part: [(Int, String)] = []
                if Date().timeIntervalSince(lastFlush) > 0.08, let live = parser.live() {
                    part = map([live])
                    lastFlush = Date()
                }
                if !fin.isEmpty || !part.isEmpty {
                    fin.forEach { doneIdx.insert($0.0) }
                    await emit(part, fin)
                }
            }
            let rest = map(parser.finish())
            if !rest.isEmpty {
                rest.forEach { doneIdx.insert($0.0) }
                await emit([], rest)
            }
        } catch {
            if Task.isCancelled { return nil }
            return error.localizedDescription
        }
        // 漏掉的段落再单独请求一次
        let missing = chunk.filter { !doneIdx.contains($0.0) }
        if missing.isEmpty { return nil }
        if retry { return await translateChunk(missing, llm, retry: false, emit: emit) }
        return "AI 返回的格式不对"
    }
}

// MARK: - AI 悬浮条（底部一条玻璃胶囊；回答在它上面展开成卡片，流式输出）

private struct AIHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct ReaderAIBar: View {
    @ObservedObject var reader: ReaderController
    var close: () -> Void
    @State private var answer = ""
    @State private var title = "AI 阅读助手"
    @State private var status = ""
    @State private var busy = false
    @State private var error: String?
    @State private var question = ""
    @State private var job: Task<Void, Never>?
    @State private var contentH: CGFloat = 0
    @FocusState private var focused: Bool

    private enum Kind { case summary, plain, explain, ask(String) }
    private var model: AppModel? { AppModel.current }
    private var hasCard: Bool { !answer.isEmpty || error != nil || busy }

    var body: some View {
        VStack(spacing: 10) {
            if hasCard { card.transition(.move(edge: .bottom).combined(with: .opacity)) }
            capsule
        }
        .frame(maxWidth: 660)
        .padding(.horizontal, 20).padding(.bottom, 18)
        .animation(.spring(duration: 0.3), value: hasCard)
        .onChange(of: reader.url) { _, _ in reset() }
        .onAppear { focused = true }
        .onDisappear { job?.cancel() }
        .onExitCommand { if hasCard { dismissCard() } else { close() } }
    }

    // MARK: 回答卡片

    private var rendered: AttributedString {
        (try? AttributedString(markdown: answer, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(answer)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").font(.system(size: 11, weight: .semibold)).foregroundStyle(Brand.orange)
                Text(title).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Button { dismissCard() } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                    .buttonStyle(.plain).foregroundStyle(.tertiary).help("收起")
            }
            if let e = error {
                Text(e).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            } else if answer.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(status).font(.callout).foregroundStyle(.secondary)
                }
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(rendered).font(.system(size: 14)).lineSpacing(5).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(GeometryReader { Color.clear.preference(key: AIHeightKey.self, value: $0.size.height) })
                            Color.clear.frame(height: 1).id("end")
                        }
                    }
                    .frame(height: min(max(contentH, 20), 300))
                    .onPreferenceChange(AIHeightKey.self) { contentH = $0 }
                    .onChange(of: answer) { _, _ in if busy { proxy.scrollTo("end", anchor: .bottom) } }
                }
                if !busy {
                    HStack(spacing: 14) {
                        Button("复制") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(answer, forType: .string)
                            AppModel.current?.showNotice("已复制")
                        }
                        Button("摘到便签") { clip() }
                        Spacer()
                    }
                    .buttonStyle(.link).font(.caption)
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background { glass(RoundedRectangle(cornerRadius: 18, style: .continuous)) }
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.08), radius: 12, y: 3)
    }

    /// 亮一些的玻璃底：磨砂材质上再叠一层跟随系统外观的底色，不被页面颜色染灰
    private func glass<S: Shape>(_ shape: S) -> some View {
        ZStack {
            shape.fill(.ultraThinMaterial)
            shape.fill(Color(nsColor: .textBackgroundColor).opacity(0.82))
        }
    }

    // MARK: 输入胶囊

    private var capsule: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles").font(.system(size: 14, weight: .semibold)).foregroundStyle(Brand.orange)
            TextField("问问这篇文章…", text: $question)
                .textFieldStyle(.plain).font(.system(size: 14)).focused($focused)
                .onSubmit { send() }
            if busy {
                Button { stop() } label: { Image(systemName: "stop.circle.fill").font(.system(size: 19)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("停止")
            } else {
                quick("text.alignleft", reader.hasSummary ? "重新摘要" : "摘要", "把要点放在文章最上面") { ask(.summary) }
                quick("text.bubble", "白话", "用大白话讲给我听") { ask(.plain) }
                quick("highlighter", "解释", "解释文章里选中的文字") { ask(.explain) }
                Button { send() } label: { Image(systemName: "arrow.up.circle.fill").font(.system(size: 20)) }
                    .buttonStyle(.plain).foregroundStyle(question.trimmed.isEmpty ? Color.secondary.opacity(0.35) : Brand.orange)
                    .disabled(question.trimmed.isEmpty)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
        .background { glass(Capsule()) }
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.10), radius: 14, y: 4)
    }

    private func quick(_ icon: String, _ text: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(text, systemImage: icon).font(.system(size: 12)).foregroundStyle(.secondary)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Color.primary.opacity(0.06), in: Capsule())
        }
        .buttonStyle(.plain).help(help)
    }

    // MARK: 动作

    private func send() {
        let q = question.trimmed
        guard !q.isEmpty else { return }
        question = ""
        ask(.ask(q))
    }

    private func ask(_ kind: Kind) {
        guard !busy else { return }
        guard let m = model, m.hasLlm else {
            title = "AI 阅读助手"
            answer = ""
            error = "还没有设置 AI 模型：到「设置」里填 API Key 之后就能用。"
            return
        }
        let llm = m.llm
        job = Task { await run(kind, llm) }
    }

    private func stop() {
        job?.cancel()
        busy = false
    }

    private func dismissCard() {
        job?.cancel()
        busy = false
        answer = ""
        error = nil
    }

    private func reset() {
        dismissCard()
    }

    @MainActor private func run(_ kind: Kind, _ llm: LlmClient) async {
        error = nil
        answer = ""
        switch kind {
        case .summary: title = "摘要要点"; status = "正在通读这篇文章…"
        case .plain: title = "白话讲讲"; status = "正在组织语言…"
        case .explain: title = "解释选中"; status = "正在理解这段文字…"
        case .ask(let q): title = q; status = "正在查阅这篇文章…"
        }
        guard ReaderAIGate.confirm(reader.url, action: "回答") else { return }
        busy = true
        defer { busy = false }
        let text = await reader.articleText()
        guard !text.isEmpty else { error = "读不到这页的正文"; return }
        var system = "你是阅读助手。只依据给出的文章回答，不要编造文章里没有的内容；用简体中文，简洁清楚。"
        var user = "标题：\(reader.pageTitle)\n\n正文：\n\(text)"
        switch kind {
        case .summary:
            system += "严格按这个格式输出，不要任何其他内容：第一行是一句话核心结论（不超过 60 字，不加序号和符号）；之后每行以「- 」开头，共 3 到 5 条要点，每条不超过 40 字。"
        case .plain:
            system += "用通俗的大白话把这篇文章讲给不熟悉这个领域的人听，必要时解释专业词，控制在 300 字内。"
        case .explain:
            let sel = await reader.currentSelection()
            guard !sel.isEmpty else { error = "先在文章里选中要解释的文字"; return }
            system += "解释用户选中的那段文字：它在说什么、涉及的背景或术语，结合全文语境，控制在 200 字内。"
            user += "\n\n用户选中的文字：\n\(sel)"
        case .ask(let q):
            system += "回答用户关于这篇文章的问题；文章里没有答案就直说没有。"
            user += "\n\n问题：\(q)"
        }
        do {
            var acc = ""
            var isSummary = false
            if case .summary = kind { isSummary = true }
            for try await d in llm.streamText(system: system, user: user) {
                acc += d
                if !isSummary { answer = acc }   // 摘要要等写完才能排成卡片，其它回答边写边显示
            }
            guard !Task.isCancelled else { return }
            if isSummary {
                if reader.article, let s = Self.parseSummary(acc) {
                    reader.showSummary(s)
                    answer = ""
                    AppModel.current?.showNotice("摘要已放在文章最上面")
                } else {
                    answer = acc
                }
            }
        } catch {
            if !Task.isCancelled { self.error = error.localizedDescription }
        }
    }

    /// 「一句话结论 + 若干条 - 要点」→ 摘要卡片的内容
    private static func parseSummary(_ text: String) -> ReaderCache.Summary? {
        func clean(_ s: String) -> String {
            var t = s.trimmingCharacters(in: .whitespaces)
            for p in ["- ", "• ", "· ", "* ", "#"] where t.hasPrefix(p) { t = String(t.dropFirst(p.count)).trimmingCharacters(in: .whitespaces) }
            if let r = t.range(of: "^[0-9]+[.、)）]\\s*", options: .regularExpression) { t.removeSubrange(r) }
            return t.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespaces)
        }
        var lead = ""
        var points: [String] = []
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            let isPoint = ["- ", "• ", "· ", "* "].contains { line.hasPrefix($0) } || line.range(of: "^[0-9]+[.、)）]", options: .regularExpression) != nil
            let c = clean(line)
            if c.isEmpty { continue }
            if isPoint { points.append(c) } else if lead.isEmpty { lead = c } else { points.append(c) }
        }
        if lead.isEmpty, !points.isEmpty { lead = points.removeFirst() }
        return lead.isEmpty ? nil : ReaderCache.Summary(lead: lead, points: Array(points.prefix(6)))
    }

    private func clip() {
        var t = answer
        if let u = reader.url { t += "\n\n[\(reader.pageTitle.isEmpty ? (u.host ?? "原文") : reader.pageTitle)](\(u.absoluteString))" }
        StickyController.shared.create(text: t)
    }
}
