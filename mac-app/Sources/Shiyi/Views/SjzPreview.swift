import SwiftUI
import AppKit
import PDFKit
import Quartz

/// 原件预览：PDF 用 PDFKit（连续滚动、自动缩放），Word / Excel / 图片等交给系统快速查看（QuickLook），都不看文字层
struct SjzFilePreview: View {
    let file: SjzFile
    /// PDF 打开后跳到第几页（从 1 开始）
    var page: Int? = nil

    var body: some View {
        Group {
            if file.isPDF { PDFPane(url: file.url, page: page) } else { QuickLookPane(url: file.url) }
        }
        .id(file.id)
    }

    private struct PDFPane: NSViewRepresentable {
        let url: URL
        let page: Int?

        final class Coordinator { var jumped: Int?; var loaded: URL? }
        func makeCoordinator() -> Coordinator { Coordinator() }

        func makeNSView(context: Context) -> PDFView {
            let v = PDFView()
            v.autoScales = true
            v.displayMode = .singlePageContinuous
            v.displaysPageBreaks = true
            v.backgroundColor = .clear
            load(v, context.coordinator)
            return v
        }
        func updateNSView(_ v: PDFView, context: Context) {
            if context.coordinator.loaded != url { load(v, context.coordinator) }
            else { jump(v, context.coordinator) }
        }
        /// 在后台读 PDF：大文件同步读会让切换时界面卡住
        private func load(_ v: PDFView, _ c: Coordinator) {
            c.loaded = url
            c.jumped = nil
            let u = url
            DispatchQueue.global(qos: .userInitiated).async {
                let d = PDFDocument(url: u)
                DispatchQueue.main.async {
                    guard c.loaded == u else { return }
                    v.document = d
                    jump(v, c)
                }
            }
        }
        /// 只在目标页变化时跳一次，不然用户翻页后每次刷新都会被拉回去
        private func jump(_ v: PDFView, _ c: Coordinator) {
            guard let page, page != c.jumped else { return }
            c.jumped = page
            DispatchQueue.main.async {
                if let pg = v.document?.page(at: max(0, page - 1)) { v.go(to: pg) }
            }
        }
    }

    private struct QuickLookPane: NSViewRepresentable {
        let url: URL
        func makeNSView(context: Context) -> QLPreviewView {
            let v = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
            v.autostarts = true
            v.previewItem = url as NSURL
            return v
        }
        func updateNSView(_ v: QLPreviewView, context: Context) {
            if (v.previewItem as? NSURL) as URL? != url { v.previewItem = url as NSURL }
        }
        // 不要在这里调 close()：视图还没激活完就关会被系统直接 abort（QLPreviewView deactivate 断言），交给系统随视图一起释放
    }
}

/// 简易 Markdown 预览：按「摘录」分成卡片；引用块合并、元信息单独成行、原件 / 文字层显示成文件条，去掉注释和 [[ ]] 之类的标记
struct SjzMarkdownView: View {
    let content: String
    var images: [String: NSImage] = [:]
    var files: [SjzFile] = []
    /// 点「预览原件」或出处页码：参数是文件和页码（没有页码为 nil）
    var onOpenFile: (SjzFile, Int?) -> Void = { _, _ in }
    /// 最多画多少个段落块（内容很长时先画一部分，避免一次画几千行卡住界面）
    var limit = Int.max

    // MARK: 结构

    private struct Section: Identifiable {
        let id: Int
        let card: Bool
        let blocks: [Block]
    }

    private enum Block {
        case heading(Int, String)
        case meta(String)
        case quote([String])
        case bullet(String, Int)
        case table([String], [[String]], [Bool])
        case ordered(String, String)
        case code(String)
        case rule
        case para(String)
        case image(String, String)
        case original(String)
        case textLayer(String, String)
    }

    private static let imgRE = RX("^!\\[([^\\]]*)\\]\\[(img\\d+)\\]\\s*$")
    private static let orderedRE = RX("^(\\d+)[\\.、]\\s+(.*)$")
    private static let layerRE = RX("^文字层：\\[\\[([^\\]]+)\\]\\]\\s*(.*)$")
    private static let origRE = RX("^原文件：\\[\\[([^\\]]+)\\]\\]\\s*$")

    private static var cachedMD = ""
    private static var cachedSections: [Section] = []
    private static func sections(_ md: String) -> [Section] {
        if md == cachedMD { return cachedSections }
        let r = parseSections(md)
        cachedMD = md
        cachedSections = r
        return r
    }

    private static func limited(_ all: [Section], _ limit: Int) -> [Section] {
        guard limit < Int.max else { return all }
        var left = limit
        var cut: [Section] = []
        for sec in all where left > 0 {
            cut.append(Section(id: sec.id, card: sec.card, blocks: Array(sec.blocks.prefix(left))))
            left -= sec.blocks.count
        }
        return cut
    }

    /// 一共有多少个段落块（用来判断要不要分段显示）
    static func blockTotal(_ md: String) -> Int { sections(md).reduce(0) { $0 + $1.blocks.count } }

    private static func parseSections(_ md: String) -> [Section] {
        var parts: [(card: Bool, lines: [String])] = [(false, [])]
        for raw in md.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let t = raw.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("<!--"), t.contains("excerpt:") { parts.append((true, [])); continue }
            if t.hasPrefix("<!--"), t.hasSuffix("-->") { continue }
            parts[parts.count - 1].lines.append(raw)
        }
        return parts.enumerated().compactMap { i, p in
            let b = blocks(p.lines)
            return b.isEmpty ? nil : Section(id: i, card: p.card, blocks: b)
        }
    }

    private static func blocks(_ lines: [String]) -> [Block] {
        var out: [Block] = []
        var quote: [String] = []
        var code: [String]? = nil
        var rows: [[String]] = []
        func flushQuote() { if !quote.isEmpty { out.append(.quote(quote)); quote = [] } }
        func cells(_ l: String) -> [String] {
            var t = l.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("|") { t.removeFirst() }
            if t.hasSuffix("|") { t.removeLast() }
            return t.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        /// 表格：第二行是 | --- | ---: | 分隔行（冒号在右 = 右对齐）
        func flushTable() {
            guard !rows.isEmpty else { return }
            defer { rows = [] }
            if rows.count >= 2, rows[1].allSatisfy({ !$0.isEmpty && $0.allSatisfy { "-: ".contains($0) } }) {
                out.append(.table(rows[0], Array(rows.dropFirst(2)), rows[1].map { $0.hasSuffix(":") }))
            } else {
                for r in rows { out.append(.para(r.joined(separator: "  "))) }
            }
        }
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if let c = code { out.append(.code(c.joined(separator: "\n"))); code = nil } else { flushQuote(); code = [] }
                continue
            }
            if code != nil { code!.append(raw); continue }
            if line.hasPrefix("|"), line.count > 1 { flushQuote(); rows.append(cells(line)); continue }
            flushTable()
            if line.isEmpty { flushQuote(); continue }
            if let m = imgRE.first(in: line) { flushQuote(); out.append(.image(m.group(2), m.group(1))); continue }
            if line.hasPrefix("#") {
                flushQuote()
                let level = line.prefix(while: { $0 == "#" }).count
                let text = String(line.dropFirst(level)).trimmed
                if !text.isEmpty { out.append(.heading(level, text)) }
                continue
            }
            if line.hasPrefix(">") {
                let t = String(line.drop(while: { $0 == ">" || $0 == " " }))
                if t.isEmpty { continue }
                if t.hasPrefix("摘录于") || t.hasPrefix("来源：") || t.hasPrefix("出处：") || t.hasPrefix("备注：") || t.hasPrefix("导入于") {
                    flushQuote(); out.append(.meta(t))
                } else { quote.append(t) }
                continue
            }
            flushQuote()
            if line == "---" || line == "***" || line == "___" { out.append(.rule); continue }
            if let m = origRE.first(in: line) { out.append(.original(m.group(1))); continue }
            if let m = layerRE.first(in: line) { out.append(.textLayer(m.group(1), m.group(2))); continue }
            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                let indent = raw.prefix(while: { $0 == " " }).count / 2
                out.append(.bullet(String(line.dropFirst(2)), min(indent, 3))); continue
            }
            if let m = orderedRE.first(in: line) { out.append(.ordered(m.group(1), m.group(2))); continue }
            out.append(.para(line))
        }
        if let c = code { out.append(.code(c.joined(separator: "\n"))) }
        flushTable()
        flushQuote()
        return out
    }

    // MARK: 渲染

    var body: some View {
        let secs = Self.limited(Self.sections(content), limit)
        // 不能用 LazyVStack：放在 ScrollView 里，内容高度是估出来的（图片、换行文字高度各不相同），滚到底时最后一截会被裁掉
        VStack(alignment: .leading, spacing: 10) {
            ForEach(secs) { s in
                if s.card {
                    VStack(alignment: .leading, spacing: 7) { blockViews(s.blocks) }
                        .padding(.horizontal, 12).padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(Color.primary.opacity(0.07), lineWidth: 0.5))
                } else {
                    VStack(alignment: .leading, spacing: 7) { blockViews(s.blocks) }
                        .padding(.horizontal, 2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func blockViews(_ blocks: [Block]) -> some View {
        ForEach(Array(blocks.enumerated()), id: \.offset) { _, b in blockView(b) }
    }

    @ViewBuilder private func blockView(_ b: Block) -> some View {
        switch b {
        case .heading(let level, let t):
            if t.hasPrefix("原件：") {
                Label(String(t.dropFirst(3)), systemImage: "paperclip")
                    .font(.system(size: 13.5, weight: .semibold)).labelStyle(.titleAndIcon)
            } else {
                Text(inline(t)).font(.system(size: level <= 1 ? 17 : level == 2 ? 14.5 : 13.5, weight: .semibold))
                    .padding(.top, level <= 1 ? 2 : 0)
            }
        case .meta(let t):
            Text(metaText(t))
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
                .environment(\.openURL, OpenURLAction { url in
                    guard url.scheme == "shiyi-open", let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
                          let ref = c.queryItems?.first(where: { $0.name == "ref" })?.value,
                          let f = files.first(where: { $0.rel == ref }) else { return .discarded }
                    onOpenFile(f, c.queryItems?.first(where: { $0.name == "page" })?.value.flatMap { Int($0) })
                    return .handled
                })
        case .quote(let ls):
            HStack(alignment: .top, spacing: 9) {
                RoundedRectangle(cornerRadius: 1.5).fill(Brand.orange.opacity(0.55)).frame(width: 3)
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(ls.enumerated()), id: \.offset) { _, l in Text(inline(l)).font(.system(size: 13)).foregroundStyle(.primary.opacity(0.88)) }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        case .bullet(let t, let level):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(level > 0 ? "◦" : "•").foregroundStyle(.secondary)
                Text(inline(t)).font(.system(size: 13))
            }
            .padding(.leading, CGFloat(level) * 16)
        case .table(let head, let body, let right):
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                    GridRow {
                        ForEach(Array(head.enumerated()), id: \.offset) { i, h in
                            Text(inline(h)).font(.system(size: 12, weight: .semibold))
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .frame(maxWidth: .infinity, alignment: i < right.count && right[i] ? .trailing : .leading)
                                .background(Color.primary.opacity(0.07))
                        }
                    }
                    ForEach(Array(body.enumerated()), id: \.offset) { _, r in
                        Divider().gridCellColumns(max(head.count, 1)).opacity(0.5)
                        GridRow {
                            ForEach(0 ..< head.count, id: \.self) { i in
                                Text(inline(i < r.count ? r[i] : "")).font(.system(size: 12))
                                    .padding(.horizontal, 10).padding(.vertical, 5)
                                    .frame(maxWidth: .infinity, alignment: i < right.count && right[i] ? .trailing : .leading)
                            }
                        }
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Color.primary.opacity(0.14), lineWidth: 0.5))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        case .ordered(let n, let t):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(n).").foregroundStyle(.secondary).monospacedDigit()
                Text(inline(t)).font(.system(size: 13))
            }
        case .code(let t):
            Text(t).font(.system(size: 12, design: .monospaced))
                .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        case .rule:
            Divider()
        case .para(let t):
            Text(inline(t)).font(.system(size: 13))
        case .image(let key, let alt):
            if let img = images[key] {
                Image(nsImage: img).resizable().scaledToFit()
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .onTapGesture { NSWorkspace.shared.open(Self.tempFile(img, key: key)) }
                    .help(alt.isEmpty ? "点击用预览打开原图" : "\(alt) · 点击用预览打开原图")
            } else {
                Label("图片 \(key) 不可用", systemImage: "photo").font(.caption).foregroundStyle(.tertiary)
            }
        case .original(let ref):
            if let f = files.first(where: { $0.rel == ref }) {
                Button { onOpenFile(f, nil) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: f.icon).foregroundStyle(Brand.orange)
                        Text(f.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        Text(f.sizeLabel).font(.caption).foregroundStyle(.tertiary)
                        Spacer(minLength: 8)
                        Text("预览原件").font(.caption).foregroundStyle(Brand.orange)
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(Brand.orange)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(Brand.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                Label("\((ref as NSString).lastPathComponent)（原件已不在）", systemImage: "doc").font(.caption).foregroundStyle(.tertiary)
            }
        case .textLayer(let ref, let note):
            Label("文字层 · \((ref as NSString).lastPathComponent)\(note.isEmpty ? "" : " " + note)", systemImage: "text.alignleft")
                .font(.system(size: 11.5)).foregroundStyle(.tertiary).lineLimit(1)
        }
    }

    /// 元信息一行：「出处：[[x.pdf]] 第 3 页」做成可点的链接，点了在原件里跳到那一页
    private func metaText(_ t: String) -> AttributedString {
        var out = AttributedString()
        let parts = t.components(separatedBy: " · ")
        for (i, part) in parts.enumerated() {
            if i > 0 { out += AttributedString("  ·  ") }
            if part.hasPrefix("出处："), let m = Self.srcRE.first(in: part) {
                let ref = m.group(1)
                let page = m.group(3)
                let name = (ref as NSString).lastPathComponent
                var label = AttributedString("出处：\(name)\(m.group(2).isEmpty ? "" : " " + m.group(2))")
                if files.contains(where: { $0.rel == ref }) {
                    var c = URLComponents()
                    c.scheme = "shiyi-open"; c.host = "file"
                    c.queryItems = [URLQueryItem(name: "ref", value: ref)] + (page.isEmpty ? [] : [URLQueryItem(name: "page", value: page)])
                    if let u = c.url { label.link = u }
                    label.foregroundColor = Brand.orange
                }
                out += label
            } else {
                out += inline(part)
            }
        }
        return out
    }

    private static let srcRE = RX("出处：\\[\\[([^\\]]+)\\]\\]\\s*((?:第\\s*(\\d+)\\s*页)?)")

    private func inline(_ s: String) -> AttributedString {
        // [[路径]] 只保留文件名；行内的注释去掉
        var t = s
        t = t.replacingOccurrences(of: "<!--[^>]*-->", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "\\[\\[([^\\]]+)\\]\\]", with: "$1", options: .regularExpression)
        return (try? AttributedString(markdown: t, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(t)
    }

    private static func tempFile(_ img: NSImage, key: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("shiyi-\(key)-\(UUID().uuidString.prefix(6)).png")
        if let t = img.tiffRepresentation, let rep = NSBitmapImageRep(data: t), let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: url) }
        return url
    }
}

struct SjzQuickItem: Identifiable, Equatable {
    let project: String
    let capture: SjzCapture
    var id: String { project + "|" + capture.id }
}

/// 记录详情的内存缓存：悬停时预取，空格快速预览 / 编辑窗口打开时直接用，不用再等一次网络往返
@MainActor
enum SjzDetailStore {
    struct Detail {
        var content: String
        var editable: Bool
        var images: [String: NSImage]
        var files: [SjzFile]
        /// 资料清单的 dueAt / sentAt / recalledAt（yyyy-MM-dd）
        var times: [String: String] = [:]
    }

    private static var cache: [String: Detail] = [:]
    private static var order: [String] = []
    private static var inflight: [String: Task<Detail?, Never>] = [:]
    /// 上一次读取失败的原因（预览窗口里显示出来，不再只说「读不到」）
    static var lastError: [String: String] = [:]
    static func error(project: String, id: String) -> String { lastError[key(project, id)] ?? "" }

    private static func key(_ project: String, _ id: String) -> String { "\(project)|\(id)" }

    static func cached(project: String, id: String) -> Detail? { cache[key(project, id)] }

    /// 重新读一次并更新缓存（同一条正在读时共用同一个请求）
    @discardableResult
    static func load(api: SjzApi, project: String, id: String) async -> Detail? {
        let k = key(project, id)
        if let t = inflight[k] { return await t.value }
        let t = Task { () -> Detail? in
            let d: (content: String, editable: Bool, images: [String: Data], files: [SjzFile], times: [String: String])
            do { d = try await api.captureDetail(project: project, id: id); lastError[k] = nil } catch { lastError[k] = error.localizedDescription; return nil }
            return Detail(content: d.content, editable: d.editable, images: d.images.compactMapValues { NSImage(data: $0) }, files: d.files, times: d.times)
        }
        inflight[k] = t
        let r = await t.value
        inflight[k] = nil
        if let r {
            cache[k] = r
            order.removeAll { $0 == k }
            order.append(k)
            if order.count > 40, let old = order.first { order.removeFirst(); cache[old] = nil }
        }
        return r
    }

    static func forget(project: String, id: String) { cache[key(project, id)] = nil }
}

/// 空格快速预览：只读、立刻出现。有原件直接看原件，没有就看排好版的正文；回车转到编辑，空格 / Esc 关闭
struct SjzQuickLook: View {
    @EnvironmentObject var model: AppModel
    let api: SjzApi
    let project: String
    let capture: SjzCapture
    var size = CGSize(width: 700, height: 560)
    /// 嵌在编辑窗口右侧并排查看：没有卡片外框和快捷键提示，有关闭按钮
    var embedded = false
    /// 在独立的预览窗口里：铺满窗口，没有卡片外框，大小跟着窗口走
    var windowed = false
    let onClose: () -> Void
    let onEdit: () -> Void

    @State private var detail: SjzDetailStore.Detail?
    @State private var mode = SjzCaptureEditor.PMode.text
    @State private var fileSel = ""
    @State private var jumpPage: Int?
    @State private var failed = false
    /// 工作小结的手动编辑
    @State private var editingSummary = false
    @State private var editText = ""
    @State private var savingSummary = false
    @State private var editError = ""
    @State private var exportingSummary = false
    /// 已经建好的面板（原件 / 文字）
    @State private var shown: Set<SjzCaptureEditor.PMode> = []

    private var tint: Color { SjzProjectDetailView.kindTint(capture.kind) }
    private var files: [SjzFile] { detail?.files ?? [] }
    private var currentFile: SjzFile? { files.first(where: { $0.id == fileSel }) ?? files.first }
    private var hasOriginal: Bool { files.contains { $0.role == "original" } }

    var body: some View {
        Group {
            if windowed { windowedBody } else { cardBody }
        }
        .onChange(of: mode) { _, m in shown.insert(m) }
        .onReceive(NotificationCenter.default.publisher(for: .sjzSummaryEdit)) { n in
            if windowed, (n.object as? String) == "\(project)|\(capture.id)" { beginEditSummary() }
        }
        .task(id: capture.id) {
            if let c = SjzDetailStore.cached(project: project, id: capture.id) { apply(c, first: true) }
            failed = false
            var d = await SjzDetailStore.load(api: api, project: project, id: capture.id)
            // 偶尔会赶上结审刚重启 / 会话过期：隔一会儿自动再读一次
            if d == nil, detail == nil {
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                d = await SjzDetailStore.load(api: api, project: project, id: capture.id)
            }
            if let d { apply(d, first: detail == nil) } else if detail == nil { failed = true }
        }
    }

    /// 读不到详情时的提示：带上原因和「重试」
    @ViewBuilder private var failedNote: some View {
        let why = SjzDetailStore.error(project: project, id: capture.id)
        Label("暂时读不到详情，请确认结审在运行", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
        if !why.isEmpty { Text(why).font(.caption2).foregroundStyle(.tertiary).lineLimit(3).padding(.horizontal, 24) }
        Button("重试") {
            failed = false
            Task {
                if let d = await SjzDetailStore.load(api: api, project: project, id: capture.id) { apply(d, first: detail == nil) } else { failed = true }
            }
        }
        .buttonStyle(.borderless).font(.caption)
    }

    // MARK: 独立窗口（访达空格预览的样子）

    /// 一行：左边让开红黄绿按钮，标题居中，右边是动作图标；下面内容铺满，没有卡片外框
    private var windowedBody: some View {
        VStack(spacing: 0) {
            // 标题条本身放在下面 overlay 的独立视图里（见 OnTopHost）：文字面板的 ScrollView 会把自己的范围伸到标题栏下面，盖住这里的按钮
            Color.clear.frame(height: 28)
            Group {
                if editingSummary {
                    VStack(spacing: 4) {
                        TextEditor(text: $editText)
                            .font(.system(size: 12.5, design: .monospaced))
                            .scrollContentBackground(.hidden)
                            .padding(.horizontal, 12).padding(.top, 6)
                        HStack(spacing: 6) {
                            Text("Markdown 源码；保存后这份小结会标为「手写」，自动生成不会再覆盖它").font(.caption2).foregroundStyle(.tertiary)
                            if !editError.isEmpty { Text(editError).font(.caption2).foregroundStyle(.red).lineLimit(2) }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 14).padding(.bottom, 8)
                    }
                } else if let d = detail {
                    // 两个面板建好后一直留着，切换只是显示 / 隐藏，不再重新读 PDF、重新排版
                    ZStack {
                        if let f = currentFile, shown.contains(.original) {
                            VStack(spacing: 0) {
                                if files.count > 1 {
                                    ScrollView(.horizontal, showsIndicators: false) {
                                        HStack(spacing: 6) {
                                            ForEach(files) { x in
                                                Button { fileSel = x.id; jumpPage = nil } label: {
                                                    Label(x.name, systemImage: x.icon).font(.caption).lineLimit(1)
                                                        .padding(.horizontal, 9).padding(.vertical, 4)
                                                        .background(x.id == f.id ? Brand.orange.opacity(0.18) : Color.primary.opacity(0.06), in: Capsule())
                                                        .foregroundStyle(x.id == f.id ? Brand.orange : .secondary)
                                                }
                                                .buttonStyle(.plain)
                                            }
                                        }
                                        .padding(.horizontal, 12).padding(.vertical, 6)
                                    }
                                }
                                SjzFilePreview(file: f, page: jumpPage).frame(maxWidth: .infinity, maxHeight: .infinity)
                            }
                            .opacity(mode == .original ? 1 : 0)
                            .allowsHitTesting(mode == .original)
                        }
                        // 文字面板只在看文字时才建（几百个段落一直留着，每次布局都要重算）；PDF / 原件建好后留着
                        if mode != .original || currentFile == nil {
                            QuickTextPane(content: d.content, images: d.images, files: d.files) { f, _ in NSWorkspace.shared.open(f.url) }
                                .equatable()
                        }
                    }
                } else {
                    VStack(spacing: 8) {
                        Spacer(minLength: 0)
                        if failed { failedNote }
                        else { ProgressView().controlSize(.small) }
                        if !capture.summary.isEmpty { Text(capture.summary).font(.callout).foregroundStyle(.secondary).lineLimit(3).padding(.horizontal, 24) }
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .top) { OnTopHost(content: windowedHeader).frame(maxWidth: .infinity).frame(height: 28) }
    }

    /// 图标 + 标题 + 编号，右边是动作图标
    private var windowedHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: capture.icon).font(.system(size: 11, weight: .semibold)).foregroundStyle(tint)
            Text(capture.title.isEmpty ? capture.summary : capture.title).font(.system(size: 12.5, weight: .semibold)).lineLimit(1).truncationMode(.middle)
            if !capture.isSummary { Text(capture.id).font(.system(size: 11)).foregroundStyle(.tertiary).fixedSize() }
            Spacer(minLength: 8)
            HStack(spacing: 0) {
                if editingSummary {
                    Button("取消") { editingSummary = false; editError = "" }
                        .buttonStyle(.borderless).font(.system(size: 12)).padding(.trailing, 8)
                    Button(savingSummary ? "保存中…" : "保存") { saveSummaryEdit() }
                        .buttonStyle(.borderedProminent).controlSize(.small).disabled(savingSummary)
                        .padding(.trailing, 6)
                } else {
                    if capture.isSummary {
                        WinIconButton(icon: "square.and.pencil", help: "编辑这份小结（回车）") { beginEditSummary() }
                        WinIconButton(icon: exportingSummary ? "hourglass" : "doc.badge.arrow.up", help: "导出 Word（公文版式）") { exportSummaryWord() }
                    }
                    if hasOriginal, let f = currentFile {
                        WinIconButton(icon: "arrow.up.forward.app", help: "用默认应用打开") { NSWorkspace.shared.open(f.url) }
                    }
                    WinIconButton(icon: "note.text", help: "在结审中打开") { [model, project, capture] in model.openSjzCapture(project: project, capture) }
                }
            }
        }
        .padding(.leading, 11).padding(.trailing, 4)
        .frame(maxWidth: .infinity, minHeight: 28, maxHeight: 28)
        .background(WindowDragArea())
        .ignoresSafeArea()
        .environmentObject(model)
    }

    // MARK: 卡片 / 并排查看

    private var cardBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: capture.icon).foregroundStyle(tint)
                Text(capture.title.isEmpty ? capture.summary : capture.title).font(.headline).lineLimit(1)
                Text(capture.id).font(.caption).foregroundStyle(.tertiary)
                Spacer(minLength: 8)
                if embedded {
                    Button(action: onClose) { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                        .buttonStyle(.plain).help("关闭并排查看")
                }
            }
            Group {
                if let d = detail {
                    if mode == .original, let f = currentFile {
                        VStack(alignment: .leading, spacing: 6) {
                            if files.count > 1 {
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 6) {
                                        ForEach(files) { x in
                                            Button { fileSel = x.id; jumpPage = nil } label: {
                                                Label(x.name, systemImage: x.icon).font(.caption).lineLimit(1)
                                                    .padding(.horizontal, 9).padding(.vertical, 4)
                                                    .background(x.id == f.id ? Brand.orange.opacity(0.18) : Color.primary.opacity(0.06), in: Capsule())
                                                    .foregroundStyle(x.id == f.id ? Brand.orange : .secondary)
                                            }
                                            .buttonStyle(.plain)
                                        }
                                    }
                                }
                            }
                            SjzFilePreview(file: f, page: jumpPage)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.primary.opacity(0.1), lineWidth: 0.5))
                        }
                    } else {
                        QuickTextPane(content: d.content, images: d.images, files: d.files, pad: 12) { f, _ in NSWorkspace.shared.open(f.url) }
                            .equatable()
                            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                } else {
                    // 详情还没回来时先把已有的信息摆出来，不让窗口空着
                    VStack(alignment: .leading, spacing: 8) {
                        if !capture.summary.isEmpty { Text(capture.summary).font(.callout).foregroundStyle(.secondary) }
                        if failed { failedNote }
                        else { ProgressView().controlSize(.small) }
                        Spacer(minLength: 0)
                    }
                    .padding(12).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
            .frame(maxHeight: .infinity)
            HStack(spacing: 10) {
                if !capture.source.isEmpty, capture.source != "拾忆" { Text(capture.source).font(.caption).foregroundStyle(.tertiary).lineLimit(1) }
                Spacer()
                Button("编辑并写回") { onEdit() }.buttonStyle(.borderless).font(.caption)
                if mode == .original, let f = currentFile {
                    Button("用默认应用打开") { NSWorkspace.shared.open(f.url) }.buttonStyle(.borderless).font(.caption)
                }
            }
        }
        .padding(EdgeInsets(top: windowed ? 7 : 16, leading: 16, bottom: 16, trailing: 16))
        .frame(width: windowed ? nil : size.width, height: embedded || windowed ? nil : size.height)
        .frame(maxWidth: windowed ? .infinity : nil, maxHeight: embedded || windowed ? .infinity : nil)
        .background(embedded || windowed ? Color.primary.opacity(0.02) : Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: embedded || windowed ? 0 : 14, style: .continuous))
        .overlay(RoundRect14(show: !embedded && !windowed))
        .shadow(color: .black.opacity(embedded || windowed ? 0 : 0.18), radius: embedded || windowed ? 0 : 22, y: embedded || windowed ? 0 : 8)
    }

    private var summaryPath: String { String(capture.id.dropFirst(SjzSummary.idPrefix.count)) }

    /// 读小结原文，切到编辑状态
    private func beginEditSummary() {
        guard capture.isSummary, !editingSummary, detail != nil else { return }
        Task {
            do {
                editText = try await api.summarySource(project: project, path: summaryPath)
                editError = ""
                editingSummary = true
            } catch {
                let a = NSAlert()
                a.messageText = "读不到小结原文"
                a.informativeText = error.localizedDescription
                a.runModal()
            }
        }
    }

    /// 导出成公文版式的 Word，导出后用默认程序打开
    private func exportSummaryWord() {
        guard capture.isSummary, !exportingSummary else { return }
        exportingSummary = true
        Task {
            defer { exportingSummary = false }
            do {
                let url = try await api.exportSummary(project: project, path: summaryPath)
                NSWorkspace.shared.open(url)
                model.showNotice("已导出 \(url.lastPathComponent)")
            } catch {
                let a = NSAlert()
                a.messageText = "导出失败"
                a.informativeText = error.localizedDescription
                a.runModal()
            }
        }
    }

    private func saveSummaryEdit() {
        guard !savingSummary else { return }
        if editText.trimmed.isEmpty { editError = "内容不能为空"; return }
        savingSummary = true
        editError = ""
        Task {
            defer { savingSummary = false }
            do {
                try await api.saveSummary(project: project, path: summaryPath, markdown: editText)
                SjzDetailStore.forget(project: project, id: capture.id)
                if let d = await SjzDetailStore.load(api: api, project: project, id: capture.id) { apply(d, first: false) }
                editingSummary = false
                NotificationCenter.default.post(name: .sjzCapturesChanged, object: nil)
            } catch {
                editError = error.localizedDescription
            }
        }
    }

    private func apply(_ d: SjzDetailStore.Detail, first: Bool) {
        detail = d
        if first {
            fileSel = d.files.first?.id ?? ""
            mode = SjzCaptureEditor.defaultMode(content: d.content, files: d.files)
            shown.insert(mode)
        }
    }
}

/// 把一段 SwiftUI 放进独立的 NSHostingView：它是真正的 AppKit 子视图，叠在同一窗口里其它 ScrollView 的上面，点击不会被盖住
private struct OnTopHost<Content: View>: NSViewRepresentable {
    let content: Content
    func makeNSView(context: Context) -> NSHostingView<Content> {
        let v = NSHostingView(rootView: content)
        v.sizingOptions = []
        return v
    }
    func updateNSView(_ v: NSHostingView<Content>, context: Context) { v.rootView = content }
}

private struct RoundRect14: View {
    let show: Bool
    var body: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.primary.opacity(show ? 0.12 : 0), lineWidth: 0.5)
    }
}

/// 预览窗口标题栏右侧的小图标按钮（和访达预览的分享 / 打开按钮一样：只有图标，悬停有底色）
private struct WinIconLabel: View {
    let icon: String
    @State private var hovering = false
    var body: some View {
        Image(systemName: icon).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            .frame(width: 26, height: 22)
            .background(Color.primary.opacity(hovering ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

private struct WinIconButton: View {
    let icon: String
    let help: String
    let action: () -> Void
    var body: some View {
        Button(action: action) { WinIconLabel(icon: icon) }.buttonStyle(.plain).help(help)
    }
}

/// 预览窗口里的文字面板：内容没变就不重画；很长的内容先画前面一部分，点「显示更多」再继续
struct QuickTextPane: View, Equatable {
    let content: String
    let images: [String: NSImage]
    let files: [SjzFile]
    let onOpenFile: (SjzFile, Int?) -> Void
    var pad: CGFloat = 22
    @State private var limit = 80

    static func == (a: QuickTextPane, b: QuickTextPane) -> Bool {
        a.content == b.content && a.files == b.files && a.images.count == b.images.count
    }

    var body: some View {
        let total = SjzMarkdownView.blockTotal(content)
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                SjzMarkdownView(content: content, images: images, files: files, onOpenFile: onOpenFile, limit: limit)
                if total > limit {
                    Button { limit += 300 } label: {
                        Text("还有 \(total - limit) 段，点这里继续显示").font(.callout)
                            .frame(maxWidth: .infinity).padding(.vertical, 8)
                            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, pad).padding(.top, 8).padding(.bottom, 20)
        }
    }
}
