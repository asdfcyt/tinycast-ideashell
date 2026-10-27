import AppKit
import ImageIO

/// 从拖拽剪贴板里读出来的原始内容（必须在拖拽回调里同步读，文件内容稍后再读）
struct RawDrop {
    var fileURLs: [URL] = []
    var imageData: [Data] = []
    var text = ""
    /// 文件承诺：截图的浮动缩略图等拖出来的是「承诺」，要接收后才有文件
    var promises: [NSFilePromiseReceiver] = []
    /// 已经有文件地址时附带的文件承诺：地址读不到（比如微信容器目录没有权限）时，改用承诺接收一份副本
    var altPromises: [NSFilePromiseReceiver] = []
    /// 拖进来的内容类型，读不出东西时写进提示，方便排查
    var types: [String] = []

    var isEmpty: Bool { fileURLs.isEmpty && imageData.isEmpty && promises.isEmpty && text.trimmed.isEmpty }

    /// 把文件承诺接收到 [dir]，返回把它们并进 fileURLs 的新内容
    func receivingPromises(into dir: URL) async -> RawDrop {
        guard !promises.isEmpty else { return self }
        var out = self
        out.promises = []
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let queue = OperationQueue()
        for p in promises {
            let urls: [URL] = await withCheckedContinuation { (cont: CheckedContinuation<[URL], Never>) in
                let box = PromiseBox(expected: max(p.fileNames.count, 1), cont: cont)
                p.receivePromisedFiles(atDestination: dir, options: [:], operationQueue: queue) { url, error in
                    box.add(error == nil ? url : nil)
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + 10) { box.finish() }
            }
            out.fileURLs.append(contentsOf: urls)
        }
        return out
    }

    /// 文件地址读不到时：接收文件承诺的副本，替换原来的文件地址
    func receivingAlt(into dir: URL) async -> RawDrop {
        guard !altPromises.isEmpty else { return self }
        var promised = RawDrop()
        promised.promises = altPromises
        let got = await promised.receivingPromises(into: dir)
        var out = self
        out.altPromises = []
        if !got.fileURLs.isEmpty { out.fileURLs = got.fileURLs }
        return out
    }
}

private final class PromiseBox: @unchecked Sendable {
    private let lock = NSLock()
    private let expected: Int
    private var cont: CheckedContinuation<[URL], Never>?
    private var urls: [URL] = []
    private var count = 0

    init(expected: Int, cont: CheckedContinuation<[URL], Never>) {
        self.expected = expected
        self.cont = cont
    }

    func add(_ url: URL?) {
        lock.lock()
        if let url { urls.append(url) }
        count += 1
        let done = count >= expected
        lock.unlock()
        if done { finish() }
    }

    func finish() {
        lock.lock()
        let c = cont
        cont = nil
        let result = urls
        lock.unlock()
        c?.resume(returning: result)
    }
}

enum DropReader {
    static let types: [NSPasteboard.PasteboardType] =
        [.fileURL, .URL, .string, .png, .tiff] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }

    static func accepts(_ pb: NSPasteboard) -> Bool {
        guard let t = pb.types else { return false }
        return t.contains { types.contains($0) }
    }

    static func read(_ pb: NSPasteboard) -> RawDrop {
        var raw = RawDrop()
        raw.types = (pb.types ?? []).map(\.rawValue)
        let fileOnly: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        raw.fileURLs = (pb.readObjects(forClasses: [NSURL.self], options: fileOnly) as? [URL]) ?? []
        if !raw.fileURLs.isEmpty {
            raw.altPromises = (pb.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver]) ?? []
            return raw
        }

        let str = pb.string(forType: .string)?.trimmed ?? ""
        let web = (pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL])?
            .first { !$0.isFileURL }?.absoluteString
        let strIsLink = str.isEmpty || (str.hasPrefix("http") && !str.contains(" ") && !str.contains("\n"))
        // 截图 / 网页图片：有图片数据，并且文字部分为空或只是个链接
        if let img = pb.data(forType: .png) ?? pb.data(forType: .tiff), strIsLink {
            raw.imageData = [img]
            raw.text = str.isEmpty ? (web ?? "") : str
        } else {
            raw.text = str.isEmpty ? (web ?? "") : str
            if raw.text.isEmpty {
                raw.promises = (pb.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver]) ?? []
            }
        }
        return raw
    }
}

/// 图片处理：接口单张上限 5MB、最多 9 张；超过就转格式 / 缩小
enum DropImages {
    static let imageExt: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tiff", "tif", "bmp"]
    static let textExt: Set<String> = ["txt", "md", "markdown", "csv"]
    /// 保存到结审证据 / 法规时按「原件」上传的文件（结审会存原件并解析出文字）
    static let docExt: Set<String> = ["pdf", "docx", "doc", "xlsx", "xls", "pptx"]
    /// 单个文件的实际上限由结审的设置决定（超了结审会返回提示）；这里只挡明显离谱的大小
    static let maxFile = 2048 * 1024 * 1024
    /// 不超过这个大小的文件直接内联（base64）传给结审；更大的只传本机路径，由结审自己读，避免内存和请求超时
    static let inlineMax = 8 * 1024 * 1024
    static let limit = 5 * 1024 * 1024 - 4096
    static let maxImages = 9

    struct Result {
        var images: [(name: String, data: Data)] = []
        var texts: [String] = []
        /// PDF / Word / Excel 等文件原件
        var files: [(name: String, data: Data?, path: String?)] = []
        var skipped = 0
        /// 超过大小上限的文件名
        var oversize: [String] = []
        /// 读不出来的文件名（没有权限等）
        var unreadable: [String] = []
        /// 不认识的文件扩展名
        var unknownExt: [String] = []
    }

    /// 没有扩展名（或扩展名不对）的文件按开头的字节判断类型：微信 / 浏览器拖出来的临时文件常常没有后缀
    static func sniffExt(_ data: Data) -> String? {
        let head = [UInt8](data.prefix(8))
        if head.starts(with: [0x25, 0x50, 0x44, 0x46]) { return "pdf" }
        if head.starts(with: [0xD0, 0xCF, 0x11, 0xE0]) { return "doc" }
        if head.starts(with: [0x50, 0x4B, 0x03, 0x04]) {
            let probe = data.prefix(1 << 20)
            if probe.range(of: Data("word/".utf8)) != nil { return "docx" }
            if probe.range(of: Data("xl/".utf8)) != nil { return "xlsx" }
            if probe.range(of: Data("ppt/".utf8)) != nil { return "pptx" }
        }
        return nil
    }

    /// 一个文件都没读到时，给出具体原因
    static func failure(_ r: Result, types: [String]) -> String {
        if let n = r.oversize.first { return "\(n) 超过 2GB，请直接在结审里导入" }
        if !r.unreadable.isEmpty {
            return "读不到「\(r.unreadable[0])」（没有权限或文件已被移走）。请到 系统设置 → 隐私与安全性 → 完全磁盘访问 允许拾忆，或先把文件拖到桌面再拖入"
        }
        if !r.unknownExt.isEmpty {
            return "不支持这类文件：\(r.unknownExt.prefix(3).joined(separator: "、"))（支持图片、文本，以及 PDF / Word / Excel）"
        }
        let shown = types.filter { !$0.hasPrefix("dyn.") }.prefix(4).joined(separator: "、")
        return "没有读到可以保存的文件" + (shown.isEmpty ? "" : "（拖入的内容类型：\(shown)）")
    }

    static func prepare(_ raw: RawDrop) -> Result {
        var r = Result()
        for url in raw.fileURLs {
            let name = url.lastPathComponent
            var ext = url.pathExtension.lowercased()
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { r.unreadable.append(name); continue }
            if isDir.boolValue { r.skipped += 1; continue }
            if !(imageExt.contains(ext) || textExt.contains(ext) || docExt.contains(ext)) {
                // 没有后缀 / 后缀不认识：读开头几个字节判断（微信、浏览器拖出来的临时文件常常没有后缀）
                guard let h = try? FileHandle(forReadingFrom: url) else { r.unreadable.append(name); continue }
                let head = (try? h.read(upToCount: 1 << 20)) ?? Data()
                try? h.close()
                if let e = sniffExt(head) {
                    ext = e
                } else {
                    r.unknownExt.append(ext.isEmpty ? name : ".\(ext)")
                    r.skipped += 1
                    continue
                }
            }
            if imageExt.contains(ext) {
                if r.images.count >= maxImages { r.skipped += 1; continue }
                guard let data = try? Data(contentsOf: url) else { r.unreadable.append(name); continue }
                if let img = fit(data, name: name) { r.images.append(img) } else { r.skipped += 1 }
            } else if textExt.contains(ext) {
                guard let s = try? String(contentsOf: url, encoding: .utf8) else { r.unreadable.append(name); continue }
                r.texts.append(String(s.prefix(20000)))
            } else if docExt.contains(ext) {
                let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
                if size > maxFile {
                    r.oversize.append(name)
                } else if size > inlineMax {
                    // 大文件：只传路径，结审在本机直接复制
                    let fileName = url.pathExtension.lowercased() == ext ? name : "\(name).\(ext)"
                    guard FileManager.default.isReadableFile(atPath: url.path) else { r.unreadable.append(name); continue }
                    r.files.append((fileName, nil, url.path))
                } else if let data = try? Data(contentsOf: url), !data.isEmpty {
                    // 临时文件没有后缀时补上，结审按扩展名处理
                    let fileName = url.pathExtension.lowercased() == ext ? name : "\(name).\(ext)"
                    r.files.append((fileName, data, nil))
                } else {
                    r.unreadable.append(name)
                }
            } else {
                r.skipped += 1
            }
        }
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = f.string(from: Date())
        for (i, d) in raw.imageData.enumerated() {
            if r.images.count >= maxImages { break }
            let name = "截图-\(stamp)" + (raw.imageData.count > 1 ? "-\(i + 1)" : "") + ".png"
            if let img = fit(d, name: name) { r.images.append(img) } else { r.skipped += 1 }
        }
        return r
    }

    /// png / jpeg 且不超限：原样上传；否则转 PNG；还是太大就降成 JPEG 并逐级缩小
    static func fit(_ data: Data, name: String) -> (name: String, data: Data)? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(src) as String? else { return nil }
        let base = (name as NSString).deletingPathExtension
        if data.count <= limit, type == "public.png" || type == "public.jpeg" {
            return (base + (type == "public.png" ? ".png" : ".jpg"), data)
        }
        if let cg = CGImageSourceCreateImageAtIndex(src, 0, nil), let png = encode(cg, "public.png", nil), png.count <= limit {
            return (base + ".png", png)
        }
        for maxDim in [3000, 2000, 1280] {
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxDim,
            ]
            guard let t = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary),
                  let jpg = encode(t, "public.jpeg", 0.85) else { continue }
            if jpg.count <= limit || maxDim == 1280 { return (base + ".jpg", jpg) }
        }
        return nil
    }

    private static func encode(_ image: CGImage, _ type: String, _ quality: Double?) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, type as CFString, 1, nil) else { return nil }
        var props: [CFString: Any] = [:]
        if let quality { props[kCGImageDestinationLossyCompressionQuality] = quality }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }
}

extension AppModel {
    /// 灵动岛投放：和万能输入同一套识别。
    /// 带图片（截图）→ 保存为笔记；纯文字 / 链接 → 按万能输入自动判断（待办 / Daily Note / 笔记）。
    func submitDrop(_ input: RawDrop) async throws -> String {
        let raw = await input.receivingPromises(into: FileManager.default.temporaryDirectory.appendingPathComponent("shiyi-drop", isDirectory: true))
        let prepared = await Task.detached(priority: .userInitiated) { DropImages.prepare(raw) }.value
        var texts: [String] = []
        if !raw.text.trimmed.isEmpty { texts.append(raw.text.trimmed) }
        texts.append(contentsOf: prepared.texts.map(\.trimmed).filter { !$0.isEmpty })
        let body = texts.joined(separator: "\n\n")

        if prepared.images.isEmpty {
            guard !body.isEmpty else {
                if !prepared.files.isEmpty || !prepared.oversize.isEmpty {
                    throw McpError.tool("PDF / Word 请拖到「证据」或「法规」格（连接结审后可用），或放进暂存架")
                }
                throw McpError.tool(prepared.skipped > 0 ? "暂不支持这类文件（支持图片、文本，以及 PDF / Word）" : "没有读到可以保存的内容")
            }
            let a = CaptureParser.analyze(body, sjz: hasSjz)
            return try await submitCapture(a, kind: a.kind)
        }

        guard hasIdeashell else { throw McpError.noCredential }
        let a = CaptureParser.analyze(body, sjz: hasSjz)
        var folder: IdeashellApi.Folder?
        let folders = (try? await ideashell.listFolders()) ?? []
        if let name = a.folderName {
            folder = CaptureParser.matchFolder(name, folders: folders)
        } else if !a.body.isEmpty {
            folder = CaptureParser.inferFolder(a.body, folders: folders)
        }
        // 截图里的文字：本机识别，附在正文后面（可以在设置里关掉）
        var ocr: [String] = []
        if ImageOCR.enabled {
            let datas = prepared.images.map(\.data)
            ocr = await Task.detached(priority: .userInitiated) { datas.map { ImageOCR.text(in: $0) } }.value
        }
        let found = ocr.filter { !$0.isEmpty }
        var fullBody = a.body
        if !found.isEmpty {
            let parts = ocr.enumerated().filter { !$0.element.isEmpty }.map { i, t in
                ocr.count > 1 ? "图 \(i + 1)：\n" + t : t
            }
            fullBody += (fullBody.isEmpty ? "" : "\n\n") + "---\n图中文字：\n" + parts.joined(separator: "\n\n")
        }

        let first = a.body.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmed ?? ""
        let title: String
        if first.isEmpty {
            let f = DateFormatter()
            f.dateFormat = "M-d HH:mm"
            let ocrLine = found.first?.split(whereSeparator: \.isNewline).first.map { String($0).trimmed } ?? ""
            title = ocrLine.count >= 4 ? "截图 · " + String(ocrLine.prefix(22)) : "截图 " + f.string(from: Date())
        } else {
            title = String(first.prefix(30))
        }
        try await ideashell.createNote(title: title, body: fullBody, tags: a.tags, folderId: folder?.id, images: prepared.images)
        invalidateHistory()
        Task {
            await loadTimeline(silent: true)
            if section == .review { await loadRiver(silent: true) }
        }
        return "已保存为笔记（\(prepared.images.count) 张图片" + (found.isEmpty ? "" : "，识别出文字") + "）" + (folder.map { " 📁" + $0.name } ?? "")
    }
}
