import Foundation

/*
 * 今日信息的「AI 速览」：把今天要读的内容（财新 / 三联最新一期、AI 日报精选、订阅的新文章）的标题和导语交给 AI，
 * 总结成「今天有什么 / 先读哪几篇、为什么 / 场景 / 洞察」。只发标题和导语，不发文章正文；结果存在本机，当天再打开直接带出。
 */

struct TodayDigest: Codable, Equatable {
    var day: String
    /// 模型输出的原文（流式生成时不断变长）
    var raw: String
    /// 提示里的条目编号 → 今日信息条目 ID / 标题 / 来源名（编号从 1 开始）
    var ids: [String]
    var titles: [String]
    var sources: [String]?
    var at: Date
}

struct ParsedDigest {
    struct Source { var name: String; var text: String }
    struct Pick { var ref: Int; var what: String; var why: String }
    struct Scene { var name: String; var desc: String; var refs: [Int] }
    /// 今天有什么：每个来源一两句话
    var inventory: [Source] = []
    /// 今天选读的总标准（一句话）
    var criterion = ""
    /// 先读哪几篇：讲了什么、为什么先读
    var picks: [Pick] = []
    var scenes: [Scene] = []
    var insights: [String] = []
}

@MainActor
final class TodayDigestStore: ObservableObject {
    static let shared = TodayDigestStore()

    @Published private(set) var digest: TodayDigest?
    @Published private(set) var busy = false
    /// 财新 / 三联这些周刊比较慢，还没载入完时先等它们
    @Published private(set) var waiting = false
    @Published var error: String?
    private var job: Task<Void, Never>?
    private static let file = "today-digest.json"

    private init() {
        if let t = LocalStore.read(Self.file), let d = t.data(using: .utf8),
           let x = try? JSONDecoder().decode(TodayDigest.self, from: d), x.day == Day.today(), x.raw.contains("依据") {
            digest = x
        }
    }

    private static let system = """
    你是一位克制、犀利的信息编辑，为用户做「今日速览」：让他一分钟内知道今天各来源有什么、该先读哪几篇、为什么先读。输入里有「用户当前在做的事」（项目、待办，可能没有）和今天的条目（分来源，每条有编号、标题、导语，没有正文）。
    写作要求：
    - 具体：直接点出条目里的事实、数字、产品、人名、结论；禁止「值得关注」「引发热议」「备受瞩目」「值得一读」「很有价值」这类空话。
    - 只依据输入，不要编造；信息不足就少写。
    - 每个来源都要覆盖到，不要只写篇数多的来源。
    严格按这个格式输出，不要任何其他内容：
    盘点：
    - 来源名（与条目分组名一致）｜这个来源今天（周刊就是本期）有什么：点出 2 到 3 个具体主题或事实，不超过 70 字
    必读：
    依据：用一句话说明今天挑选必读的总标准，例如「优先选和你在做的审计项目直接相关、且带一手数据的」，不超过 40 字
    - 条目编号｜这篇具体讲了什么（数据、结论或做法，不超过 30 字）｜为什么先读它：要和其他条目比较着说，例如「本期主打」「别的条目都在引它」「直接关系到你的某个项目或待办」「时效最强」，不超过 35 字
    场景：
    - 场景名（2 到 6 字，例如「做产品」「看宏观」「学技术」）｜这一类今天的具体内容，点出 2 到 3 个具体事实，不超过 60 字｜涉及的条目编号，用英文逗号分隔
    洞察：
    - 把多条内容放在一起得出的判断：是什么趋势、对用户意味着什么，不超过 50 字
    「必读」挑 4 到 6 篇，按「先读」的顺序排，并尽量覆盖不同来源，周刊（财新周刊、三联）有的话每家至少选 1 篇；和用户在做的事有真实关联时才提关联，没有就不要硬扯，改说信息本身的价值；「场景」写 3 到 4 个；「洞察」写 2 到 3 条，只写真正有信息量的。
    """

    /// 开始生成。周刊还在载入时先等它们载入完，免得速览里少了财新 / 三联
    func generate(store: TodayStore) {
        guard !busy else { return }
        guard let m = AppModel.current, m.hasLlm else { error = "先到「设置」里填写 AI 模型的 API Key"; return }
        error = nil
        busy = true
        let llm = m.llm
        job = Task {
            if store.loading {
                waiting = true
                while store.loading && !Task.isCancelled { try? await Task.sleep(nanoseconds: 300_000_000) }
                waiting = false
            }
            guard !Task.isCancelled else { busy = false; return }
            var lines: [String] = []
            var ids: [String] = []
            var titles: [String] = []
            var sources: [String] = []
            for g in store.groups {
                var part: [String] = []
                var used = 0
                for e in g.entries.prefix(30) {
                    let brief = (e.brief.isEmpty ? e.sub : e.brief).trimmingCharacters(in: .whitespacesAndNewlines)
                        .replacingOccurrences(of: "\n", with: " ").prefix(110)
                    let tag = (e.sub == e.brief || e.sub.isEmpty) ? "" : "｜" + e.sub.prefix(24)
                    let line = "\(ids.count + 1). \(e.title)\(tag)" + (brief.isEmpty ? "" : "｜\(brief)")
                    if used + line.count > 3200 { break }   // 每个来源各有一份篇幅，周刊条数再多也不会把别的挤掉
                    used += line.count
                    ids.append(e.id)
                    titles.append(e.title)
                    sources.append(g.name)
                    part.append(line)
                }
                if !part.isEmpty {
                    lines.append("【\(g.name)" + (g.note.isEmpty ? "" : "｜\(g.note)") + "】")
                    lines += part
                }
            }
            guard !ids.isEmpty else { error = "今天还没有内容可以总结"; busy = false; return }
            var ctx: [String] = []
            let kws = m.projects.map(\.keyword).prefix(8)
            if !kws.isEmpty { ctx.append("- 项目：" + kws.joined(separator: "、")) }
            if let ov = m.overview {
                let tasks = (ov.overdue + ov.todayTasks()).map(\.cleanTitle).prefix(8)
                if !tasks.isEmpty { ctx.append("- 眼下的待办：" + tasks.joined(separator: "；")) }
            }
            let user = (ctx.isEmpty ? "" : "【用户当前在做的事】\n" + ctx.joined(separator: "\n") + "\n\n") + lines.joined(separator: "\n")
            let day = Day.today()
            var acc = ""
            do {
                for try await d in llm.streamText(system: Self.system, user: user) {
                    acc += d
                    digest = TodayDigest(day: day, raw: acc, ids: ids, titles: titles, sources: sources, at: Date())
                }
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
            busy = false
            if !acc.isEmpty, let d = digest, let data = try? JSONEncoder().encode(d), let text = String(data: data, encoding: .utf8) {
                LocalStore.write(Self.file, text)
            }
        }
    }

    func stop() {
        job?.cancel()
        busy = false
        waiting = false
    }

    /// 「盘点 / 必读 / 场景 / 洞察」四段 → 结构（流式生成时每来一段文字就解析一次，没写完的行也能先显示）
    static func parse(_ raw: String) -> ParsedDigest {
        enum Sec { case none, inventory, picks, scenes, insights }
        var out = ParsedDigest()
        var sec = Sec.none
        func ints(_ s: String) -> [Int] {
            s.components(separatedBy: CharacterSet(charactersIn: ",，、 ")).compactMap { Int($0.trimmingCharacters(in: CharacterSet(charactersIn: "#号 ."))) }
        }
        for rawLine in raw.components(separatedBy: "\n") {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            line = line.replacingOccurrences(of: "**", with: "")
            if line.range(of: "^[#\\s]*盘点[：:]?\\s*$", options: .regularExpression) != nil { sec = .inventory; continue }
            if line.range(of: "^[#\\s]*必读[：:]?\\s*$", options: .regularExpression) != nil { sec = .picks; continue }
            if line.range(of: "^[#\\s]*场景[：:]?\\s*$", options: .regularExpression) != nil { sec = .scenes; continue }
            if line.range(of: "^[#\\s]*洞察[：:]?\\s*$", options: .regularExpression) != nil { sec = .insights; continue }
            let bullet = ["- ", "• ", "· ", "* "].first { line.hasPrefix($0) }
            let body = bullet.map { String(line.dropFirst($0.count)).trimmingCharacters(in: .whitespaces) } ?? line
            let parts = body.components(separatedBy: CharacterSet(charactersIn: "｜|")).map { $0.trimmingCharacters(in: .whitespaces) }
            switch sec {
            case .inventory:
                guard parts.count >= 1, !parts[0].isEmpty else { continue }
                out.inventory.append(.init(name: parts[0], text: parts.count > 1 ? parts[1...].joined(separator: " ") : ""))
            case .picks:
                if let r = line.range(of: "^[#\\s]*依据[：:]\\s*", options: .regularExpression) {
                    out.criterion = String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                    continue
                }
                guard let n = ints(parts[0]).first else { continue }
                out.picks.append(.init(ref: n, what: parts.count > 1 ? parts[1] : "", why: parts.count > 2 ? parts[2...].joined(separator: " ") : ""))
            case .scenes:
                guard !parts.isEmpty, !parts[0].isEmpty else { continue }
                out.scenes.append(.init(name: parts[0], desc: parts.count > 1 ? parts[1] : "", refs: parts.count > 2 ? ints(parts[2]) : []))
            case .insights:
                out.insights.append(body)
            case .none:
                break
            }
        }
        return out
    }
}
