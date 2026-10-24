import AppKit
import ImageIO

/// 发现「刚截了一张图」：
/// - 剪贴板里出现新图片（⌃⌘⇧4 截图、或在别处复制了图片）
/// - 截图保存目录里出现新的截图文件（⌘⇧3 / ⌘⇧4，保存目录取自系统设置，默认桌面）
@MainActor
final class CaptureWatcher {
    var onOffer: ((CaptureOffer) -> Void)?

    private var clipTimer: Timer?
    private var lastChange = NSPasteboard.general.changeCount
    private var source: DispatchSourceFileSystemObject?
    private var watchedDir: URL?
    private var seen = Set<String>()

    private static let namePrefixes = ["Screenshot", "Screen Shot", "屏幕截图", "截屏", "スクリーンショット", "Bildschirmfoto"]

    func start() {
        stop()
        lastChange = NSPasteboard.general.changeCount
        clipTimer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { [weak self] _ in
            // changeCount 没变（绝大多数时候）就直接返回，不必为此开一个 Task
            MainActor.assumeIsolated { self?.checkClipboard() }
        }
        // 剪贴板轮询不需要精确：放宽容差，让系统把它和别的定时器合并唤醒
        clipTimer?.tolerance = 0.3
        watchDirectory()
    }

    func stop() {
        clipTimer?.invalidate()
        clipTimer = nil
        source?.cancel()
        source = nil
        watchedDir = nil
    }

    // MARK: - 剪贴板

    private func checkClipboard() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChange else { return }
        lastChange = pb.changeCount
        // 自己复制的（比如暂存架里点一下复制）不提示
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Bundle.main.bundleIdentifier { return }
        guard let types = pb.types, !types.contains(.fileURL) else { return }
        guard let data = pb.data(forType: .png) ?? pb.data(forType: .tiff), data.count > 2000 else { return }
        let thumb = CGImageSourceCreateWithData(data as CFData, nil).flatMap(Self.thumbnail)
        onOffer?(CaptureOffer(raw: RawDrop(imageData: [data]), fileURL: nil, thumbnail: thumb, title: "剪贴板里有一张图片"))
    }

    // MARK: - 截图文件

    private func watchDirectory() {
        let custom = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location")
        let dir = custom.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { return }
        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        watchedDir = dir
        seen = Set((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        src.setEventHandler { [weak self] in
            Task { @MainActor in self?.scan() }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
    }

    private func scan() {
        guard let dir = watchedDir, let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        for n in names where !seen.contains(n) {
            if n.hasPrefix(".") { continue }
            seen.insert(n)
            let url = dir.appendingPathComponent(n)
            guard Self.isScreenshot(url) else { continue }
            // 文件刚出现时可能还没写完，稍等一下再取
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.offer(url)
            }
        }
    }

    private func offer(_ url: URL) {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attrs?[.size] as? Int, size > 0 else { return }
        if let created = attrs?[.creationDate] as? Date, Date().timeIntervalSince(created) > 20 { return }
        let thumb = CGImageSourceCreateWithURL(url as CFURL, nil).flatMap(Self.thumbnail)
        onOffer?(CaptureOffer(raw: RawDrop(fileURLs: [url]), fileURL: url, thumbnail: thumb, title: "刚截了一张图"))
    }

    private static func isScreenshot(_ url: URL) -> Bool {
        guard ["png", "jpg", "jpeg", "heic", "tiff"].contains(url.pathExtension.lowercased()) else { return false }
        if namePrefixes.contains(where: { url.lastPathComponent.hasPrefix($0) }) { return true }
        return getxattr(url.path, "com.apple.metadata:kMDItemIsScreenCapture", nil, 0, 0, 0) >= 0
    }

    static func thumbnail(_ src: CGImageSource) -> NSImage? {
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 160,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}
