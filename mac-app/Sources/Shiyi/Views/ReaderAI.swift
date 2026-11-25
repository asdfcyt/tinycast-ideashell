import AppKit
import NaturalLanguage
import SwiftUI
import Translation

/*
 * 阅读器里的「翻译」和「AI」。
 * · 翻译：用 macOS 自带的 Translation（本机离线翻译，文字不出这台 Mac，免费）；版式参考「沉浸式翻译」——译文跟在原文每一段下面。
 * · AI：用设置里填的 AI 模型（OpenAI 兼容接口）。会把当前文章的文字发给这个服务，所以只在你点了按钮之后才发，
 *   财新 / 三联这类付费内容首次使用前会先说明并要你确认；正文不保存。
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
        Task {
            let texts = await reader.collectTexts()
            guard !texts.isEmpty else {
                reader.translateFinished("这一页没有需要翻译的外文")
                return
            }
            // 先自己判断原文语言：已经是中文就不用翻；判断不出来再交给系统
            let sample = String(texts.joined(separator: " ").prefix(2000))
            let rec = NLLanguageRecognizer()
            rec.processString(sample)
            let code = rec.dominantLanguage?.rawValue
            if let code, code.hasPrefix("zh") {
                reader.translateFinished("这一页已经是中文")
                return
            }
            reader.pendingTexts = texts
            let src = code.map { Locale.Language(identifier: $0) }
            let target = Locale.Language(identifier: "zh-Hans")
            if config != nil, config?.source == src { config?.invalidate(); return }
            var cfg = TranslationSession.Configuration(source: src, target: target)
            // macOS 26.4 起可选「高保真」策略：读文章不赶时间，译文质量优先
            if #available(macOS 26.4, *) { cfg = .init(source: src, target: target, preferredStrategy: .highFidelity) }
            config = cfg
        }
    }

    private func run(_ session: TranslationSession) async {
        let texts = await MainActor.run { reader.pendingTexts }
        guard !texts.isEmpty else { return }
        let reqs = texts.enumerated().map { TranslationSession.Request(sourceText: $1, clientIdentifier: String($0)) }
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

// MARK: - AI 面板

struct ReaderAIPanel: View {
    @ObservedObject var reader: ReaderController
    @State private var answer = ""
    @State private var busy = false
    @State private var error: String?
    @State private var question = ""
    @State private var ack = false

    private var host: String { reader.url?.host ?? "" }
    private var paid: Bool { host.hasSuffix("caixin.com") || host.hasSuffix("lifeweek.com.cn") }
    private var ackKey: String { "reader.ai.ack." + (host.hasSuffix("caixin.com") ? "caixin" : "lifeweek") }
    private var model: AppModel? { AppModel.current }
    private var serviceHost: String { URL(string: model?.llmBaseUrl ?? "")?.host ?? "你设置的 AI 服务" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("AI 阅读助手", systemImage: "sparkles").font(.system(size: 14, weight: .bold))
                Spacer()
                if busy { ProgressView().controlSize(.small) }
            }
            if model?.hasLlm != true {
                Text("还没有设置 AI 模型：到「设置」里填 API Key 之后就能用。").font(.callout).foregroundStyle(.secondary)
            } else if paid && !ack {
                paidNotice
            } else {
                controls
            }
        }
        .padding(16).frame(width: 360)
        .onAppear { ack = UserDefaults.standard.bool(forKey: ackKey) }
    }

    // 付费内容：先说清楚发生什么，再确认
    private var paidNotice: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("先说明一下", systemImage: "exclamationmark.shield").font(.callout.weight(.semibold)).foregroundStyle(Brand.orange)
            Text("这是付费订阅内容。点 AI 之后，当前文章的文字会发送到 \(serviceHost)（你在设置里配置的服务），用来生成回答；拾忆不保存正文，也不会自动发送。")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("文章受版权保护，仅限你个人阅读辅助，请勿转发或公开 AI 生成的全文复述。这个操作只读取你已经打开的页面，不会向网站发起额外请求。")
                .font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            Button("我知道了，继续") {
                UserDefaults.standard.set(true, forKey: ackKey)
                ack = true
            }
            .buttonStyle(.borderedProminent).tint(Brand.orange).controlSize(.small)
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            if reader.locked {
                Text("当前只有预览、没有全文，AI 只能基于预览回答。").font(.caption).foregroundStyle(.orange)
            }
            HStack(spacing: 8) {
                chip("摘要要点", "text.alignleft") { await ask(.summary) }
                chip("白话讲讲", "text.bubble") { await ask(.plain) }
                chip("解释选中", "highlighter") { await ask(.explain) }
            }
            HStack(spacing: 8) {
                TextField("针对这篇文章提问…", text: $question).textFieldStyle(.roundedBorder).onSubmit { send() }
                Button { send() } label: { Image(systemName: "arrow.up.circle.fill").font(.system(size: 18)) }
                    .buttonStyle(.plain).foregroundStyle(Brand.orange)
                    .disabled(busy || question.trimmed.isEmpty)
            }
            if let e = error { Text(e).font(.caption).foregroundStyle(.red) }
            if !answer.isEmpty {
                // ScrollView 在气泡里没有固有高度，会缩成 0：短答案直接铺开，长答案给固定高度再滚动
                let body = Text((try? AttributedString(markdown: answer, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(answer))
                    .font(.system(size: 13.5)).lineSpacing(4).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                if answer.count > 320 {
                    ScrollView { body }.frame(height: 300)
                } else {
                    body
                }
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
            Text("文字会发送到 \(serviceHost)，不保存正文。").font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private func chip(_ title: String, _ icon: String, _ action: @escaping () async -> Void) -> some View {
        Button { Task { await action() } } label: { Label(title, systemImage: icon).font(.caption) }
            .buttonStyle(.bordered).controlSize(.small).disabled(busy)
    }

    private enum Kind { case summary, plain, explain, ask(String) }

    private func send() {
        let q = question.trimmed
        guard !q.isEmpty else { return }
        Task { await ask(.ask(q)) }
    }

    private func ask(_ kind: Kind) async {
        guard let llm = model?.llm, !busy else { return }
        error = nil
        busy = true
        defer { busy = false }
        let text = await reader.articleText()
        guard !text.isEmpty else { error = "读不到这页的正文"; return }
        var system = "你是阅读助手。只依据给出的文章回答，不要编造文章里没有的内容；用简体中文，简洁清楚。"
        var user = "标题：\(reader.pageTitle)\n\n正文：\n\(text)"
        switch kind {
        case .summary:
            system += "先用一句话说清文章的核心结论，再列 3 到 5 条要点（每条一句话）。不要大段复述原文。"
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
            answer = try await llm.chatText(system: system, user: user)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func clip() {
        var t = answer
        if let u = reader.url { t += "\n\n[\(reader.pageTitle.isEmpty ? (u.host ?? "原文") : reader.pageTitle)](\(u.absoluteString))" }
        StickyController.shared.create(text: t)
    }
}
