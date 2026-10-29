import Foundation

/// 设置的导出 / 导入：各项偏好（快捷键、开关、麦克风按键映射…）+ 语音词库。**不含任何密钥**。
enum SettingsTransfer {
    enum Failure: LocalizedError {
        case notSettingsFile
        var errorDescription: String? { "这不是拾忆导出的设置文件" }
    }

    /// 只搬用户主动设置过的项；窗口位置、运行状态、缓存都不带
    private static let prefixes = ["ui.", "voice.", "notify.", "llm.", "mic.config", "capture.", "app.", "quickadd."]
    private static let exact: Set<String> = ["focus.goalMin", "sjz.endpoint", "sjz.summary", "sjz.summaryMin", "ticket.keepDays", "sticky.deleteAfterConvert"]
    private static let excluded: Set<String> = ["voice.duck.saved"]

    private static func allowed(_ key: String) -> Bool {
        if excluded.contains(key) { return false }
        return exact.contains(key) || prefixes.contains { key.hasPrefix($0) }
    }

    /// 返回导出了多少项
    static func export(to url: URL) throws -> Int {
        let all = UserDefaults.standard.dictionaryRepresentation()
        let defaults = all.filter { allowed($0.key) }
        var lexicon: [String: Any] = [:]
        if let text = LocalStore.read("voice-lexicon.json"), let d = text.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            lexicon = obj
        }
        let root: [String: Any] = ["shiyiSettings": 1, "defaults": defaults, "lexicon": lexicon]
        let data = try PropertyListSerialization.data(fromPropertyList: root, format: .xml, options: 0)
        try data.write(to: url, options: .atomic)
        return defaults.count + (lexicon.isEmpty ? 0 : 1)
    }

    /// 返回导入了多少项。词库按并集合并，不会覆盖本机已有的热词和规则
    @MainActor
    static func `import`(from url: URL) throws -> Int {
        let data = try Data(contentsOf: url)
        guard let root = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              root["shiyiSettings"] != nil else { throw Failure.notSettingsFile }
        var n = 0
        if let defaults = root["defaults"] as? [String: Any] {
            for (k, v) in defaults where allowed(k) {
                UserDefaults.standard.set(v, forKey: k)
                n += 1
            }
        }
        if let lex = root["lexicon"] as? [String: Any], !lex.isEmpty,
           let d = try? JSONSerialization.data(withJSONObject: lex),
           let incoming = try? JSONDecoder().decode(LexiconData.self, from: d) {
            let cur = VoiceLexicon.shared.data
            var hot = cur.hotwords
            for w in incoming.hotwords where !hot.contains(w) { hot.append(w) }
            var rules = cur.replacements.map { ($0.from, $0.to) }
            for r in incoming.replacements where !rules.contains(where: { $0.0 == r.from }) { rules.append((r.from, r.to)) }
            VoiceLexicon.shared.save(hotwords: hot, replacements: rules)
            n += 1
        }
        AppShortcutStore.shared.reload()
        return n
    }
}
