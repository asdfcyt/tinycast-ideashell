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

        final class Coordinator { var jumped: Int? }
        func makeCoordinator() -> Coordinator { Coordinator() }

        func makeNSView(context: Context) -> PDFView {
            let v = PDFView()
            v.autoScales = true
            v.displayMode = .singlePageContinuous
            v.displaysPageBreaks = true
            v.backgroundColor = .clear
            v.document = PDFDocument(url: url)
            jump(v, context.coordinator)
            return v
        }
        func updateNSView(_ v: PDFView, context: Context) {
            if v.document?.documentURL != url { v.document = PDFDocument(url: url) }
            jump(v, context.coordinator)
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
        static func dismantleNSView(_ v: QLPreviewView, coordinator: ()) { v.close() }
    }
}

/// 简易 Markdown 预览：按「摘录」分成卡片；引用块合并、元信息单独成行、原件 / 文字层显示成文件条，去掉注释和 [[ ]] 之类的标记
struct SjzMarkdownView: View {
    let content: String
    var images: [String: NSImage] = [:]
    var files: [SjzFile] = []
    /// 点「预览原件」或出处页码：参数是文件和页码（没有页码为 nil）
    var onOpenFile: (SjzFile, Int?) -> Void = { _, _ in }

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
        case bullet(String)
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

    private static func sections(_ md: String) -> [Section] {
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
        func flushQuote() { if !quote.isEmpty { out.append(.quote(quote)); quote = [] } }
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if let c = code { out.append(.code(c.joined(separator: "\n"))); code = nil } else { flushQuote(); code = [] }
                continue
            }
            if code != nil { code!.append(raw); continue }
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
            if line.hasPrefix("- ") || line.hasPrefix("* ") { out.append(.bullet(String(line.dropFirst(2)))); continue }
            if let m = orderedRE.first(in: line) { out.append(.ordered(m.group(1), m.group(2))); continue }
            out.append(.para(line))
        }
        if let c = code { out.append(.code(c.joined(separator: "\n"))) }
        flushQuote()
        return out
    }

    // MARK: 渲染

    var body: some View {
        let secs = Self.sections(content)
        LazyVStack(alignment: .leading, spacing: 10) {
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
        case .bullet(let t):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("•").foregroundStyle(.secondary)
                Text(inline(t)).font(.system(size: 13))
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
    }

    private static var cache: [String: Detail] = [:]
    private static var order: [String] = []
    private static var inflight: [String: Task<Detail?, Never>] = [:]

    private static func key(_ project: String, _ id: String) -> String { "\(project)|\(id)" }

    static func cached(project: String, id: String) -> Detail? { cache[key(project, id)] }

    /// 重新读一次并更新缓存（同一条正在读时共用同一个请求）
    @discardableResult
    static func load(api: SjzApi, project: String, id: String) async -> Detail? {
        let k = key(project, id)
        if let t = inflight[k] { return await t.value }
        let t = Task { () -> Detail? in
            guard let d = try? await api.captureDetail(project: project, id: id) else { return nil }
            return Detail(content: d.content, editable: d.editable, images: d.images.compactMapValues { NSImage(data: $0) }, files: d.files)
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
    let api: SjzApi
    let project: String
    let capture: SjzCapture
    var size = CGSize(width: 700, height: 560)
    let onClose: () -> Void
    let onEdit: () -> Void

    @State private var detail: SjzDetailStore.Detail?
    @State private var mode = SjzCaptureEditor.PMode.text
    @State private var fileSel = ""
    @State private var jumpPage: Int?
    @State private var failed = false

    private var tint: Color { SjzProjectDetailView.kindTint(capture.kind) }
    private var files: [SjzFile] { detail?.files ?? [] }
    private var currentFile: SjzFile? { files.first(where: { $0.id == fileSel }) ?? files.first }
    private var hasOriginal: Bool { files.contains { $0.role == "original" } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: capture.icon).foregroundStyle(tint)
                Text(capture.title.isEmpty ? capture.summary : capture.title).font(.headline).lineLimit(1)
                Text(capture.id).font(.caption).foregroundStyle(.tertiary)
                Spacer(minLength: 8)
                if !files.isEmpty {
                    Picker("", selection: $mode) {
                        Text(hasOriginal ? "原件" : "出处原件").tag(SjzCaptureEditor.PMode.original)
                        Text(hasOriginal ? "文字" : "摘录").tag(SjzCaptureEditor.PMode.text)
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 150)
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
                        ScrollView {
                            SjzMarkdownView(content: d.content, images: d.images, files: d.files) { f, page in fileSel = f.id; jumpPage = page; mode = .original }
                                .padding(12)
                        }
                        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                } else {
                    // 详情还没回来时先把已有的信息摆出来，不让窗口空着
                    VStack(alignment: .leading, spacing: 8) {
                        if !capture.summary.isEmpty { Text(capture.summary).font(.callout).foregroundStyle(.secondary) }
                        if failed { Label("暂时读不到详情，请确认结审在运行", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
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
                Text("空格 / Esc 关闭 · 回车编辑").font(.caption).foregroundStyle(.tertiary)
                Button("编辑并写回") { onEdit() }.buttonStyle(.borderless).font(.caption)
                if mode == .original, let f = currentFile {
                    Button("用默认应用打开") { NSWorkspace.shared.open(f.url) }.buttonStyle(.borderless).font(.caption)
                }
            }
        }
        .padding(16)
        .frame(width: size.width, height: size.height)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 22, y: 8)
        .task(id: capture.id) {
            if let c = SjzDetailStore.cached(project: project, id: capture.id) { apply(c, first: true) }
            if let d = await SjzDetailStore.load(api: api, project: project, id: capture.id) {
                apply(d, first: detail == nil)
            } else if detail == nil { failed = true }
        }
    }

    private func apply(_ d: SjzDetailStore.Detail, first: Bool) {
        detail = d
        if first {
            fileSel = d.files.first?.id ?? ""
            mode = SjzCaptureEditor.defaultMode(content: d.content, files: d.files)
        }
    }
}
