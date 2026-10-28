import Foundation
import Security

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

/// 系统钥匙串里的一条通用密码（整份凭证存成一条 JSON，只会触发一次授权）。失败时调用方回退到本机文件。
enum Keychain {
    private static let service = "com.carpe.shiyi.mac.credentials"
    private static let account = "credentials"

    private static var base: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func read() -> Data? {
        var q = base
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    @discardableResult
    static func write(_ data: Data) -> Bool {
        let status = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
}

/// 两个服务的凭证；只存本机（优先系统钥匙串，不可用时退回 0600 权限的本机文件），永远不上传
final class CredentialStore: @unchecked Sendable {
    private let lock = NSLock()
    private var _ideashell: String
    private var _dida: String
    private var _backupNoteId: String?
    private var _llmKey: String
    private var _sjzKey: String
    private var _tencentId: String
    private var _tencentKey: String

    private struct Disk: Codable {
        var ideashellKey: String = ""
        var didaToken: String = ""
        var backupNoteId: String?
        var llmKey: String?
        var sjzKey: String?
        var tencentId: String?
        var tencentKey: String?
    }

    init() {
        let fileDisk = LocalStore.read("credentials.json")
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONDecoder().decode(Disk.self, from: $0) }
        let keyDisk = Keychain.read().flatMap { try? JSONDecoder().decode(Disk.self, from: $0) }
        let disk = keyDisk ?? fileDisk ?? Disk()
        _ideashell = disk.ideashellKey
        _dida = disk.didaToken
        _backupNoteId = disk.backupNoteId
        _llmKey = disk.llmKey ?? ""
        _sjzKey = disk.sjzKey ?? ""
        _tencentId = disk.tencentId ?? ""
        _tencentKey = disk.tencentKey ?? ""
        // 第一次从文件迁到钥匙串：写成功后，文件里只留不敏感的字段
        if keyDisk == nil, fileDisk != nil { persist() }
    }

    var ideashellKey: String { lock.withLock { _ideashell } }
    var didaToken: String { lock.withLock { _dida } }
    var backupNoteId: String? { lock.withLock { _backupNoteId } }
    var llmKey: String { lock.withLock { _llmKey } }
    var sjzKey: String { lock.withLock { _sjzKey } }
    var tencentId: String { lock.withLock { _tencentId } }
    var tencentKey: String { lock.withLock { _tencentKey } }

    /// 腾讯云语音识别的 SecretId / SecretKey
    func setTencent(id: String, key: String) {
        lock.withLock {
            _tencentId = id
            _tencentKey = key
            persist()
        }
    }

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
        let disk = Disk(ideashellKey: _ideashell, didaToken: _dida, backupNoteId: _backupNoteId, llmKey: _llmKey.isEmpty ? nil : _llmKey, sjzKey: _sjzKey.isEmpty ? nil : _sjzKey, tencentId: _tencentId.isEmpty ? nil : _tencentId, tencentKey: _tencentKey.isEmpty ? nil : _tencentKey)
        guard let d = try? JSONEncoder().encode(disk) else { return }
        if Keychain.write(d) {
            // 密钥已进钥匙串：文件里只留不敏感的字段
            let plain = Disk(ideashellKey: "", didaToken: "", backupNoteId: _backupNoteId)
            if let pd = try? JSONEncoder().encode(plain), let ps = String(data: pd, encoding: .utf8) {
                LocalStore.write("credentials.json", ps, secret: true)
            }
        } else if let s = String(data: d, encoding: .utf8) {
            LocalStore.write("credentials.json", s, secret: true)
        }
    }
}
