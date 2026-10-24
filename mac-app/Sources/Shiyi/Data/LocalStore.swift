import Foundation

/// 本机小文件存储：凭证（0600 权限）与备份缓存，都在 ~/Library/Application Support/Shiyi/ 下
enum LocalStore {
    static var dir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let d = base.appendingPathComponent("Shiyi", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func read(_ name: String) -> String? {
        try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
    }

    static func write(_ name: String, _ text: String, secret: Bool = false) {
        let url = dir.appendingPathComponent(name)
        try? text.write(to: url, atomically: true, encoding: .utf8)
        if secret { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
    }

    static func remove(_ name: String) {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
    }
}

/// 两个服务的凭证；只存本机，永远不上传
final class CredentialStore: @unchecked Sendable {
    private let lock = NSLock()
    private var _ideashell: String
    private var _dida: String
    private var _backupNoteId: String?
    private var _llmKey: String
    private var _sjzKey: String

    private struct Disk: Codable {
        var ideashellKey: String = ""
        var didaToken: String = ""
        var backupNoteId: String?
        var llmKey: String?
        var sjzKey: String?
    }

    init() {
        let disk = LocalStore.read("credentials.json")
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONDecoder().decode(Disk.self, from: $0) } ?? Disk()
        _ideashell = disk.ideashellKey
        _dida = disk.didaToken
        _backupNoteId = disk.backupNoteId
        _llmKey = disk.llmKey ?? ""
        _sjzKey = disk.sjzKey ?? ""
    }

    var ideashellKey: String { lock.withLock { _ideashell } }
    var didaToken: String { lock.withLock { _dida } }
    var backupNoteId: String? { lock.withLock { _backupNoteId } }
    var llmKey: String { lock.withLock { _llmKey } }
    var sjzKey: String { lock.withLock { _sjzKey } }

    func setSjzKey(_ k: String) {
        lock.withLock {
            _sjzKey = k
            persist()
        }
    }

    func setLlmKey(_ k: String) {
        lock.withLock {
            _llmKey = k
            persist()
        }
    }

    func update(ideashell: String, dida: String) {
        lock.withLock {
            _ideashell = ideashell
            _dida = dida
            persist()
        }
    }

    func setBackupNoteId(_ id: String?) {
        lock.withLock {
            _backupNoteId = id
            persist()
        }
    }

    /// 调用方已持有锁
    private func persist() {
        let disk = Disk(ideashellKey: _ideashell, didaToken: _dida, backupNoteId: _backupNoteId, llmKey: _llmKey.isEmpty ? nil : _llmKey, sjzKey: _sjzKey.isEmpty ? nil : _sjzKey)
        if let d = try? JSONEncoder().encode(disk), let s = String(data: d, encoding: .utf8) {
            LocalStore.write("credentials.json", s, secret: true)
        }
    }
}
