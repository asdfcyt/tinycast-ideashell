import Foundation

/// 读取手机端写进闪念贝壳的「拾忆备份（请勿删除）」笔记（正文里一个 ```json 代码块），只读。
enum BackupService {
    static let title = "拾忆备份（请勿删除）"
    static let tag = "拾忆备份"

    static func isBackupNote(_ note: NoteInfo) -> Bool {
        note.title == title || note.tags.contains { $0.trimmingCharacters(in: CharacterSet(charactersIn: "#")) == tag }
    }

    static func decode(_ text: String) throws -> BackupFile {
        guard let data = text.data(using: .utf8), let file = try? JSONDecoder().decode(BackupFile.self, from: data),
              file.format == BackupFile.format else {
            throw McpError.proto("这不是拾忆的备份")
        }
        if file.version > BackupFile.supportedVersion {
            throw McpError.proto("备份来自更新版本的拾忆（v\(file.version)），请先升级 Mac 端")
        }
        return file
    }

    /// 从闪念贝壳拉取备份；没找到抛异常。返回备份和原始 JSON 文本（用于本地缓存）
    static func pull(api: IdeashellApi, noteId: String?) async throws -> (file: BackupFile, json: String, noteId: String) {
        let id: String
        if let noteId { id = noteId }
        else if let found = try await api.searchNotes(title, limit: 20).first(where: isBackupNote) { id = found.id }
        else { throw McpError.proto("闪念贝壳里没有找到备份笔记，请先在手机上点「备份到闪念贝壳」") }

        let content = try await api.noteFull(id).content
        guard let start = content.range(of: "```json"), let end = content.range(of: "```", options: .backwards),
              start.upperBound < end.lowerBound else {
            throw McpError.proto("备份笔记的内容不完整")
        }
        let json = String(content[start.upperBound ..< end.lowerBound]).trimmed
        return (try decode(json), json, id)
    }
}
