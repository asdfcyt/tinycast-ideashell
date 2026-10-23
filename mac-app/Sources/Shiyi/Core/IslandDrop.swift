import AppKit
import ImageIO

/// 从拖拽剪贴板里读出来的原始内容（必须在拖拽回调里同步读，文件内容稍后再读）
struct RawDrop {
    var fileURLs: [URL] = []
    var imageData: [Data] = []
    var text = ""
    /// 文件承诺：截图的浮动缩略图等拖出来的是「承诺」，要接收后才有文件
    var promises: [NSFilePromiseReceiver] = []

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
        let fileOnly: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        raw.fileURLs = (pb.readObjects(forClasses: [NSURL.self], options: fileOnly) as? [URL]) ?? []
        if !raw.fileURLs.isEmpty { return raw }

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
    static let limit = 5 * 1024 * 1024 - 4096
    static let maxImages = 9

    struct Result {
        var images: [(name: String, data: Data)] = []
        var texts: [String] = []
        var skipped = 0
    }

    static func prepare(_ raw: RawDrop) -> Result {
        var r = Result()
        for url in raw.fileURLs {
            let ext = url.pathExtension.lowercased()
            if imageExt.contains(ext) {
                if r.images.count >= maxImages { r.skipped += 1; continue }
                if let data = try? Data(contentsOf: url), let img = fit(data, name: url.lastPathComponent) {
                    r.images.append(img)
                } else {
                    r.skipped += 1
                }
            } else if textExt.contains(ext), let s = try? String(contentsOf: url, encoding: .utf8) {
                r.texts.append(String(s.prefix(20000)))
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
    private static func fit(_ data: Data, name: String) -> (name: String, data: Data)? {
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
                throw McpError.tool(prepared.skipped > 0 ? "暂不支持这类文件（支持图片和文本文件）" : "没有读到可以保存的内容")
            }
            let a = CaptureParser.analyze(body)
            return try await submitCapture(a, kind: a.kind)
        }

        guard hasIdeashell else { throw McpError.noCredential }
        let a = CaptureParser.analyze(body)
        var folder: IdeashellApi.Folder?
        let folders = (try? await ideashell.listFolders()) ?? []
        if let name = a.folderName {
            folder = CaptureParser.matchFolder(name, folders: folders)
        } else if !a.body.isEmpty {
            folder = CaptureParser.inferFolder(a.body, folders: folders)
        }
        let first = a.body.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmed ?? ""
        let title: String
        if first.isEmpty {
            let f = DateFormatter()
            f.dateFormat = "M-d HH:mm"
            title = "截图 " + f.string(from: Date())
        } else {
            title = String(first.prefix(30))
        }
        try await ideashell.createNote(title: title, body: a.body, tags: a.tags, folderId: folder?.id, images: prepared.images)
        invalidateHistory()
        Task {
            await loadTimeline(silent: true)
            if section == .review { await loadRiver(silent: true) }
        }
        return "已保存为笔记（\(prepared.images.count) 张图片）" + (folder.map { " 📁" + $0.name } ?? "")
    }
}
