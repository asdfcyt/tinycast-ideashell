import AppKit
import ImageIO

struct ShelfItem: Identifiable, Codable, Equatable {
    enum Kind: String, Codable { case file, image, text, link }

    var id = UUID()
    var kind: Kind
    var name: String
    /// 文件 / 图片的路径（从 Finder 拖入的文件原地引用，不复制；截图等数据存在暂存目录里）
    var path: String?
    /// 文字 / 链接内容
    var text: String?
    var createdAt = Date()

    var url: URL? { path.map { URL(fileURLWithPath: $0) } }
    var exists: Bool { path.map { FileManager.default.fileExists(atPath: $0) } ?? true }
}

/// 暂存架：把东西先放在岛上，稍后再拖到别的 App。重启不丢。
@MainActor
final class ShelfStore: ObservableObject {
    static let shared = ShelfStore()

    @Published private(set) var items: [ShelfItem] = []
    private let maxItems = 60
    private var thumbs: [UUID: NSImage] = [:]

    private var blobDir: URL {
        let d = LocalStore.dir.appendingPathComponent("shelf", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    init() {
        if let text = LocalStore.read("shelf.json"), let data = text.data(using: .utf8),
           let list = try? JSONDecoder().decode([ShelfItem].self, from: data) {
            items = list.filter { $0.kind == .text || $0.kind == .link || $0.exists }
        }
    }

    // MARK: - 增删

    /// 放进暂存架，返回放进去的项数
    @discardableResult
    func add(_ input: RawDrop) async -> Int {
        let raw = await input.receivingPromises(into: blobDir.appendingPathComponent(UUID().uuidString, isDirectory: true))
        var added: [ShelfItem] = []

        for url in raw.fileURLs {
            let kind: ShelfItem.Kind = DropImages.imageExt.contains(url.pathExtension.lowercased()) ? .image : .file
            added.append(ShelfItem(kind: kind, name: url.lastPathComponent, path: url.path))
        }

        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = f.string(from: Date())
        for (i, d) in raw.imageData.enumerated() {
            let dir = blobDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let name = "截图-\(stamp)" + (raw.imageData.count > 1 ? "-\(i + 1)" : "") + ".png"
            let url = dir.appendingPathComponent(name)
            if let png = Self.pngData(d), (try? png.write(to: url)) != nil {
                added.append(ShelfItem(kind: .image, name: name, path: url.path))
            }
        }

        let t = raw.text.trimmed
        if !t.isEmpty {
            let isLink = t.hasPrefix("http") && !t.contains(" ") && !t.contains("\n")
            if isLink {
                added.append(ShelfItem(kind: .link, name: URL(string: t)?.host ?? t, text: t))
            } else {
                let first = t.split(whereSeparator: \.isNewline).first.map(String.init) ?? t
                added.append(ShelfItem(kind: .text, name: String(first.prefix(40)), text: t))
            }
        }

        guard !added.isEmpty else { return 0 }
        items.insert(contentsOf: added, at: 0)
        trim()
        save()
        return added.count
    }

    func remove(_ item: ShelfItem) {
        items.removeAll { $0.id == item.id }
        thumbs[item.id] = nil
        deleteBlob(item)
        save()
    }

    func clear() {
        items.forEach(deleteBlob)
        items.removeAll()
        thumbs.removeAll()
        save()
    }

    // MARK: - 取用

    func open(_ item: ShelfItem) {
        switch item.kind {
        case .file, .image:
            if let u = item.url { NSWorkspace.shared.open(u) }
        case .link:
            if let t = item.text, let u = URL(string: t) { NSWorkspace.shared.open(u) }
        case .text:
            copy(item)
        }
    }

    func copy(_ item: ShelfItem) {
        let pb = NSPasteboard.general
        pb.clearContents()
        switch item.kind {
        case .file, .image:
            if let u = item.url { pb.writeObjects([u as NSURL]) }
        case .text, .link:
            if let t = item.text { pb.setString(t, forType: .string) }
        }
    }

    /// 拖出去时给目标 App 的内容
    func provider(for item: ShelfItem) -> NSItemProvider {
        switch item.kind {
        case .file, .image:
            if let u = item.url, let p = NSItemProvider(contentsOf: u) { return p }
        case .link:
            if let t = item.text, let u = URL(string: t) { return NSItemProvider(object: u as NSURL) }
        case .text:
            if let t = item.text { return NSItemProvider(object: t as NSString) }
        }
        return NSItemProvider()
    }

    /// 再走一遍「保存」的识别：文件 / 图片 → 笔记，文字 / 链接 → 万能输入
    func rawDrop(for item: ShelfItem) -> RawDrop {
        switch item.kind {
        case .file, .image: return RawDrop(fileURLs: item.url.map { [$0] } ?? [])
        case .text, .link: return RawDrop(text: item.text ?? "")
        }
    }

    func thumbnail(for item: ShelfItem) -> NSImage? {
        if let t = thumbs[item.id] { return t }
        guard let u = item.url else { return nil }
        var img: NSImage?
        if item.kind == .image, let src = CGImageSourceCreateWithURL(u as CFURL, nil) {
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 160,
            ]
            if let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) {
                img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            }
        }
        if img == nil { img = NSWorkspace.shared.icon(forFile: u.path) }
        thumbs[item.id] = img
        return img
    }

    // MARK: - 内部

    private func trim() {
        while items.count > maxItems, let last = items.last {
            deleteBlob(last)
            items.removeLast()
        }
    }

    /// 只删暂存目录里自己存的文件；Finder 里原地引用的文件绝不动
    private func deleteBlob(_ item: ShelfItem) {
        guard let u = item.url, u.path.hasPrefix(blobDir.path) else { return }
        try? FileManager.default.removeItem(at: u.deletingLastPathComponent())
    }

    private func save() {
        if let d = try? JSONEncoder().encode(items), let s = String(data: d, encoding: .utf8) {
            LocalStore.write("shelf.json", s)
        }
    }

    private static func pngData(_ data: Data) -> Data? {
        if data.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]) { return data }
        return NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:])
    }
}
