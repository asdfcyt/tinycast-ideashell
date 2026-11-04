import Foundation

/// 外部 Agent（Cursor / WorkBuddy / 自己在终端里开的 opencode）每一轮的最终回复：验收卡点掉就没了，这里留一份，调度页里可以回看。
/// 内容就是 Agent 已经发过来的那条消息，不另外调用任何模型。
struct AgentResultRecord: Codable, Identifiable {
    var id = UUID()
    var at = Date()
    var source: AgentSource
    var project: String
    var cwd: String
    var failed: Bool
    var summary: String
    var duration: Double?
    var sessionId: String?
}

@MainActor
final class AgentResultStore: ObservableObject {
    static let shared = AgentResultStore()

    @Published private(set) var records: [AgentResultRecord] = []
    private static let keep = 100

    private static var url: URL {
        let d = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Shiyi", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d.appendingPathComponent("agent-results.json")
    }

    private init() {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        if let d = try? Data(contentsOf: Self.url) { records = (try? dec.decode([AgentResultRecord].self, from: d)) ?? [] }
    }

    func add(_ c: AgentCompletion) {
        let text = ReceiptParser.extract(c.summary).text
        guard !text.isEmpty else { return }
        records.insert(AgentResultRecord(source: c.source, project: c.project, cwd: c.cwd, failed: c.failed, summary: String(text.prefix(8000)),
                                         duration: c.duration, sessionId: c.sessionId), at: 0)
        if records.count > Self.keep { records = Array(records.prefix(Self.keep)) }
        persist()
    }

    func remove(_ id: UUID) {
        records.removeAll { $0.id == id }
        persist()
    }

    func clear() {
        records = []
        persist()
    }

    private func persist() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .secondsSince1970
        if let d = try? enc.encode(records) { try? d.write(to: Self.url, options: .atomic) }
    }
}
