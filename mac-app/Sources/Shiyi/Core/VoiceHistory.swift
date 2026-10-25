import Foundation

/// 一次语音输入的记录：保留识别原文，方便和整理结果对照（对应安卓端 `VoiceHistory`）
struct VoiceRecord: Codable, Identifiable, Equatable {
    var id = UUID()
    var at = Date()
    /// 识别出的原文（词库替换前）
    var raw: String
    /// 识别引擎：系统 / 腾讯云
    var engine: String
    /// 整理后的每一条（保存时更新为最终内容）
    var items: [String] = []
    /// 是否经过 AI 整理
    var polished = false
    /// 状态：已保存 / 取消 / 失败…
    var status = "待确认"
    var note: String?
}

@MainActor
final class VoiceHistory: ObservableObject {
    static let shared = VoiceHistory()
    private static let file = "voice-history.json"
    private static let limit = 200

    @Published private(set) var records: [VoiceRecord]

    private init() {
        records = LocalStore.read(Self.file)
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONDecoder().decode([VoiceRecord].self, from: $0) } ?? []
    }

    @discardableResult
    func add(raw: String, engine: String) -> UUID {
        let r = VoiceRecord(raw: raw, engine: engine)
        records.insert(r, at: 0)
        if records.count > Self.limit { records.removeLast(records.count - Self.limit) }
        persist()
        return r.id
    }

    func update(_ id: UUID, _ change: (inout VoiceRecord) -> Void) {
        guard let i = records.firstIndex(where: { $0.id == id }) else { return }
        change(&records[i])
        persist()
    }

    func clear() {
        records = []
        persist()
    }

    private func persist() {
        if let d = try? JSONEncoder().encode(records), let s = String(data: d, encoding: .utf8) { LocalStore.write(Self.file, s) }
    }
}
