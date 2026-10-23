import Foundation

/// 完成一个番茄时给用户的反馈：数据、期间记下的内容、一句鼓励。也是「成果小票」的数据（移植自安卓端 `Celebration`）。
struct Celebration: Identifiable, Codable, Equatable {
    var id = UUID()
    /// 关联的任务名（自由专注为空）
    var title: String
    /// 这次专注的分钟数
    var minutes: Int
    /// 本轮第几个番茄（0 = 不显示；提前结束的不算）
    var round: Int
    /// 走完了（false = 提前结束）
    var completed: Bool
    /// 期间的记录：tag 是记下的时刻（mm:ss），text 是内容
    var records: [Entry]
    /// 生成小票时已知的「今天累计专注」分钟数
    var todayMin: Int
    var cheer: String
    var postedAt = Date()

    struct Entry: Codable, Equatable {
        var tag: String
        var text: String
    }

    var statusText: String { completed ? "已完成" : "已记录" }
    var whatText: String { completed ? "已完成番茄" : "专注已记录" }
    /// 小票右下角的流水号（取 id 的后 6 位十六进制）
    var serial: String { String(id.uuidString.replacingOccurrences(of: "-", with: "").suffix(6)).uppercased() }
}

/// 鼓励的话：按场景随机挑一句
enum Cheer {
    private static let pomodoro = [
        "稳稳地把这一段时间交给了重要的事，漂亮。",
        "又一个番茄入账，节奏很棒！",
        "专注是会复利的，今天的你比刚才更接近目标。",
        "不被打断地做完一整段，本身就值得夸一下。",
        "先休息一会儿，回来继续发光。",
    ]
    private static let withRecords = [
        "不只是坐了一段时间，还留下了实实在在的记录，这就是进展。",
        "边做边记，以后的你会感谢现在的你。",
        "这些记录就是这个番茄的成果，继续保持！",
    ]
    private static let early = [
        "没走完也算数，已经记下这段专注了。",
        "做了就有收获，下次再来一个完整的番茄。",
    ]

    static func pomodoro(hasRecords: Bool, completed: Bool) -> String {
        (!completed ? early : (hasRecords ? withRecords : pomodoro)).randomElement() ?? ""
    }
}

/// 成果小票的本机留存：最近 100 张（`tickets.json`）。也用来在没连滴答时估算「今日累计专注」
@MainActor
final class TicketStore {
    static let shared = TicketStore()
    private static let maxCount = 100

    private(set) var items: [Celebration]

    private init() {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .millisecondsSince1970
        items = LocalStore.read("tickets.json")
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? dec.decode([Celebration].self, from: $0) } ?? []
    }

    func add(_ c: Celebration) {
        items = Array((items + [c]).suffix(Self.maxCount))
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .millisecondsSince1970
        if let d = try? enc.encode(items), let s = String(data: d, encoding: .utf8) { LocalStore.write("tickets.json", s) }
    }

    /// 今天通过本应用记下的专注分钟数
    var todayMinutes: Int {
        let cal = Calendar.current
        return items.filter { cal.isDateInToday($0.postedAt) }.reduce(0) { $0 + $1.minutes }
    }
}
