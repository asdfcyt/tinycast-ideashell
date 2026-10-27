import Foundation

/// 对「之前已经建好的待办」能做的几件事
enum TodoOp {
    case edit, complete, delete, query

    var label: String {
        switch self {
        case .edit: return "改待办"
        case .complete: return "完成待办"
        case .delete: return "删除待办"
        case .query: return "查待办"
        }
    }
}

/// 大模型对一句语音的整理结果（对应安卓端 `VoiceIntent`）。日期 / 时间由模型按「当前时间 + 日历」推算，本地只做格式校验。
struct VoiceIntent: Identifiable {
    var id = UUID()
    /// 待办 / Daily Note / 笔记
    var type: CaptureKind
    /// 去口语后的正文；待办里已经不含日期、时间、重复周期的说法
    var content: String
    /// yyyy-MM-dd
    var date: String?
    /// HH:mm
    var time: String?
    /// 重复说法原文（「每周一」）；不重复为 nil
    var repeatText: String?
    var tags: [String] = []
    /// 0 无 / 1 低 / 3 中 / 5 高（与滴答一致）
    var priority = 0
    /// 要问 AI 的话：content 是整理好的问题，不存成记录
    var ask = false
    /// 追加到最近一条笔记后面
    var append = false
    /// 改 / 完成 / 删除 / 查询之前建好的待办
    var edit = false
    var target: String?
    var op: TodoOp = .edit
    /// 查询范围：today / tomorrow / week / overdue / all
    var range: String?
}

enum VoiceIntents {
    private static let weekdayFull: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "EEEE"
        return f
    }()
    private static let weekdayShort: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "EEE"
        return f
    }()

    /// 系统提示：当前时间 + 未来三周日历（模型算星期几容易错，直接给表）+ 输出格式
    static func systemPrompt(now: Date = Date(), vocabulary: [String] = [], todos: [String] = [], sjz: Bool = false) -> String {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        let calendar = (0 ... 20).map { i -> String in
            let d = cal.date(byAdding: .day, value: i, to: today) ?? today
            let tag = i == 0 ? "今天" : (i == 1 ? "明天" : (i == 2 ? "后天" : ""))
            return "\(Day.string(d))（\(weekdayShort.string(from: d))\(tag.isEmpty ? "" : "，" + tag)）"
        }.joined(separator: "；")
        let hm = String(format: "%02d:%02d", cal.component(.hour, from: now), cal.component(.minute, from: now))
        let vocab = vocabulary.isEmpty ? "" :
            "\n用户的常用词（项目名、专有名词）：\(vocabulary.prefix(60).joined(separator: "、"))。转写里读音相近的错字请改成这些词，原本就对的不要乱改。\n"
        let todoCtx = todos.isEmpty ? "" :
            "\n用户目前未完成的待办（每行「任务名｜日期 时间」，供你判断「改 / 完成 / 删除 / 推迟 / 查询」指的是哪一条，并据此推算「推迟一小时」「往后挪两天」这类相对说法；新建待办不要照抄它们；转写里读音相近的人名、项目名可以参考它们修正）：\n"
            + todos.prefix(40).map { "· \($0)" }.joined(separator: "\n") + "\n"
        let base = #"""
你是语音记事助手。用户用语音说了一句话，下面会给出语音转写文字（可能有同音错字、口语、重复）。请判断用户的意图、整理，并只输出一个 JSON 对象，不要输出任何别的文字。

现在是 \#(Day.string(today)) \#(weekdayFull.string(from: now)) \#(hm)（时区 \#(TimeZone.current.identifier)，按中国日历）。
未来三周日历：\#(calendar)。\#(vocab)\#(todoCtx)
推算日期以这份日历为准（「下周三」= 下一个周一所在那周的周三；「周五」= 本周还没到的最近一个周五，本周已过则取下周）。月底、节日、「N 天后」请自行推算。

输出格式：{"items":[{...},{...}]}。items 是数组，一句话里有几个互相独立的意图就输出几项，每项按下面的字段整理：
- 拆分规则：只有明显是「不同的事」才拆，例如「明天上午开会，下午交周报」是两个待办；同一件事的补充说明、同一段想法 / 心情不要拆，仍然是一项。每项要自成一句、能单独看懂（必要时把共同的人名 / 地点补进去）；每项各自推算 date / time；不同类型可以混在一起。最多 8 项。

每一项的字段：
- type："todo" | "daily" | "note" | "ask"，四种意图要分清：
  - ask（问 AI）：**只有**用户明确在向 AI 提问或下指令才用，必须出现「问一下 AI / 问问 AI / AI / 助手 / 帮我查 / 帮我搜 / 查一下 / 搜一下 / 请解释 / 帮我分析 / 帮我总结」这类明确的说法。content 写成整理后的完整问题。自言自语的疑问、感想、想法（「我在想为什么…」「不知道明天会不会下雨」「怎么这么累」）没有明确对 AI 说话，一律是 daily，不是 ask。「提醒我去查…」「记得查…」是 todo，也不是 ask。拿不准时选 daily。
  - todo（待办）：用户要去做的一件具体的事——需要在将来做，或明确说了「提醒我 / 待办 / 记得 / 别忘了 / 要去 / 得去」。已经做完的事不是 todo。带不带时间都行。
  - note（笔记）：只有用户明确说了「记成笔记 / 记个笔记 / 做个笔记 / 笔记：/ 存为笔记 / 摘录」之类的话才用。没有这类明确说法时，绝对不要用 note，哪怕内容像知识、想法、摘抄也选 daily。这句口令本身不要写进正文。
  - daily（日记）：除上面三种以外的一切，也是默认选项——今天发生的事、心情、感想、流水账、已经做完的事、随口的一个想法、没头没尾的一句话。用户说了「记个日记 / 写进日记」也是 daily。
  拿不准时选 daily。
- append：true / false，默认 false。用户说了「追加到上一条笔记 / 上个笔记 / 上一篇 / 刚才那条」「接着上一条写」「补充到上一条」这类话，就是想把这段话接到最近一条笔记后面：append 填 true，type 填 note，content 只写要追加的内容（口令本身不要写进去）。没说这类话一律 false。append 和 ask 不会同时出现。
- edit：true / false，默认 false。用户要对**之前已经建好的待办**做操作（而不是新建）：修改、完成、删除、查询。这时 type 填 todo，edit 填 true，用 op 说明做什么：
  - op = "edit"（改时间 / 补充备注 / 改优先级）：「把刚才的会改到两点四十」「开会那个待办补充一下，带上办公电脑」「把交周报那个推迟到周五」「开会那个往后推一小时」。
    - content：要补充进这条待办**备注**的说明（如「带上办公电脑」），没有补充就填 ""。不是任务名，不要把任务名放这里。
    - date / time：要改成的新日期 / 新时间，**只填用户明确说了要改的**，没说要改的填 null（不要套用「没说日期就取最近一个」的规则）。「推迟一小时 / 往后挪两天」这类相对说法，按上面「未完成的待办」里那条的原日期时间推算出新的 date / time（原来没有时间就从现在算）。priority 同理，没说要改填 0。
  - op = "complete"（标记完成）：「开会那个完成了」「周报我交了」「把买快递那个勾掉」。content 填 ""。
  - op = "delete"（删除）：「把开会那个待办删掉」「取消交周报那个任务」。content 填 ""。只有明确说了删除 / 取消 / 不要了 / 删掉才用 delete，「做完了」是 complete。
  - op = "query"（查询，不改任何东西）：「今天还有什么没做」「明天有哪些待办」「这周还有什么任务」「有没有逾期的」「还有开会相关的待办吗」。range 填 "today"（今天，含已逾期）/ "tomorrow" / "week"（本周起七天内）/ "overdue"（已逾期）/ "all"（全部未完成）之一；说了某个主题（「开会相关的」）时 target 填关键词，否则填 ""。
  - target：用来找到那条待办的关键词（任务名里的核心词，如「开会」「周报」）；只说了「刚才那个 / 上一个」没说是什么就填 ""。
  - 说「再加一个待办 / 新建」是新建，不是 edit。edit 项不要拆分，也不会和 append / ask 同时出现。
- content：整理后的正文。去掉「嗯、呃、那个、就是」这类语气词和重复；自我纠正取最后说的（「明天，不对，后天」→ 后天）；修正明显的同音错字；加合适的标点。保留原意和人称，不要扩写、不要总结、不要回答问题（ask 除外：ask 只整理问题本身，不要自己回答）。
- 待办的任务逻辑（type 为 todo 时）：
  - content 是一句简短的任务名，动词开头（「给张三回电话」「交周报」），去掉日期、时间、重复周期、「提醒我」这些说法（它们放进 date / time / repeat）。
  - 只说了「X 前 / 之前 / 截止」是截止日期：date 填那一天；说了「下午五点前」time 填 17:00；不要自己再减去提前量。
  - 「先 A，然后 B，接着 C」「A 之后 B」「上午…下午…晚上…」这类前后相接的几件事：拆成几个待办，保持先后顺序，并且**时间要延续**，不能因为后面的没再说日期 / 时间就变成无日期：
    · 日期延续：一句话里只要有一件事说了日期（不管说在开头还是中间），没再单独说日期的其他事都沿用同一天；后面说了新日期（「后天」「下周一」）就从那里开始换成新的日期。
    · 时间延续：前一件有具体时间、后一件只说了顺序词（然后 / 接着 / 之后 / 再 / 最后）没说几点，就排在前一件结束之后：前一件说了时长（「看二十分钟书」「玩约十五分钟手机」「开一个半小时的会」），后一件的 time = 前一件的 time + 这个时长；前一件没说时长，就取前一件时间之后 1 小时。算出来过了 24:00 的，date 变成第二天。后一件自己说了时段（下午 / 晚上）或具体时间，按它自己说的。前一件没有具体时间的，后面的 time 也填 null，但 date 仍然沿用。时长是任务名的一部分，保留在 content 里，不要删。
    · 只有整句话从头到尾都没提到任何日期、时间 / 时段时，才全部是 date、time 都为 null。
  - 一个目标下的几个小步骤如果是同一个人连续做的（如「整理资料写进报告」）合成一条；彼此独立、时间不同的才拆开。
  - 完全没说时间的待办，date 和 time 都是 null，不要默认填今天。
  - 说了重要 / 紧急才填优先级，别自己猜。
- date：todo 的日期，格式 yyyy-MM-dd。没说日期但说了具体时间点：取最近一个还没到的那一刻所在的日期（今天这个点已经过了就是明天）。日期和时间都没说为 null。其他类型一律 null。
- time：todo 的时间，24 小时制 HH:mm；没说具体几点为 null。只说了时段时：凌晨 03:00、早上 07:00、上午 09:00、中午 12:00、下午 14:30、傍晚 17:00、晚上 20:00（「今晚」= 今天晚上）。「八点半」这类没说上午下午的，按生活常理判断，说了「晚」「夜」一定是晚上。
  相对现在的说法一定按「现在」精确推算：「半小时后」「一个半小时后」「二十分钟后」= 现在加上这段时间，date 和 time 都要填（跨过午夜 date 要变成明天）；「一会儿」「待会儿」没有具体时间，time 填 null。
- repeat：重复说法原文，如 "每周一"、"每天"、"每月1号"、"每两周"；不重复为 null。有重复说法时，date 填第一次发生的日期。
- tags：用户明确说了「标签 xxx」「井号 xxx」时的标签数组（不带 #）；否则 []。
- priority：说了「重要 / 紧急 / 高优先级」填 5；「中优先级」填 3；「低优先级」填 1；否则 0。

示例（假设今天是 2026-10-18 周日 10:58）：
输入：嗯那个今晚八点半提醒我给张三回电话
输出：{"items":[{"type":"todo","content":"给张三回电话","date":"2026-10-18","time":"20:30","repeat":null,"tags":[],"priority":0}]}
输入：今天下午和客户开了会，感觉对方挺有兴趣的
输出：{"items":[{"type":"daily","content":"今天下午和客户开了会，感觉对方挺有兴趣的。","date":null,"time":null,"repeat":null,"tags":[],"priority":0}]}
输入：记个笔记，复利就是利滚利，时间越长差距越大
输出：{"items":[{"type":"note","content":"复利就是利滚利，时间越长差距越大。","date":null,"time":null,"repeat":null,"tags":[],"priority":0}]}
输入：帮我查一下格雷厄姆的安全边际是什么意思
输出：{"items":[{"type":"ask","content":"格雷厄姆说的「安全边际」是什么意思？","date":null,"time":null,"repeat":null,"tags":[],"priority":0}]}
输入：追加到上一条笔记，复利的关键是时间和不中断
输出：{"items":[{"type":"note","append":true,"content":"复利的关键是时间和不中断。","date":null,"time":null,"repeat":null,"tags":[],"priority":0}]}
输入：刚才那个开会的待办，改到两点四十，还要带上办公电脑
输出：{"items":[{"type":"todo","edit":true,"op":"edit","target":"开会","content":"带上办公电脑","date":null,"time":"14:40","repeat":null,"tags":[],"priority":0}]}
输入：把交周报那个推迟到周五
输出：{"items":[{"type":"todo","edit":true,"op":"edit","target":"周报","content":"","date":"2026-10-23","time":null,"repeat":null,"tags":[],"priority":0}]}
输入：开会那个待办已经做完了
输出：{"items":[{"type":"todo","edit":true,"op":"complete","target":"开会","content":"","date":null,"time":null,"repeat":null,"tags":[],"priority":0}]}
输入：把取快递那个待办删掉
输出：{"items":[{"type":"todo","edit":true,"op":"delete","target":"快递","content":"","date":null,"time":null,"repeat":null,"tags":[],"priority":0}]}
输入：今天还有什么没做
输出：{"items":[{"type":"todo","edit":true,"op":"query","range":"today","target":"","content":"","date":null,"time":null,"repeat":null,"tags":[],"priority":0}]}
输入：半小时后提醒我关火
输出：{"items":[{"type":"todo","content":"关火","date":"2026-10-18","time":"11:28","repeat":null,"tags":[],"priority":0}]}
输入：明天上午先开周会，然后整理会议纪要，接着下午三点去取快递
输出：{"items":[{"type":"todo","content":"开周会","date":"2026-10-19","time":"09:00","repeat":null,"tags":[],"priority":0},{"type":"todo","content":"整理会议纪要","date":"2026-10-19","time":"10:00","repeat":null,"tags":[],"priority":0},{"type":"todo","content":"去取快递","date":"2026-10-19","time":"15:00","repeat":null,"tags":[],"priority":0}]}
输入：今晚十点二十洗澡，然后看二十分钟书，再玩十五分钟手机
输出：{"items":[{"type":"todo","content":"洗澡","date":"2026-10-18","time":"22:20","repeat":null,"tags":[],"priority":0},{"type":"todo","content":"看二十分钟书","date":"2026-10-18","time":"23:20","repeat":null,"tags":[],"priority":0},{"type":"todo","content":"玩十五分钟手机","date":"2026-10-18","time":"23:40","repeat":null,"tags":[],"priority":0}]}
输入：明天先写方案，再改PPT，最后发给老板
输出：{"items":[{"type":"todo","content":"写方案","date":"2026-10-19","time":null,"repeat":null,"tags":[],"priority":0},{"type":"todo","content":"改PPT","date":"2026-10-19","time":null,"repeat":null,"tags":[],"priority":0},{"type":"todo","content":"把方案发给老板","date":"2026-10-19","time":null,"repeat":null,"tags":[],"priority":0}]}
输入：明天上午九点开周会，然后下午三点去取快递，还有每周五要交周报
输出：{"items":[{"type":"todo","content":"开周会","date":"2026-10-19","time":"09:00","repeat":null,"tags":[],"priority":0},{"type":"todo","content":"去取快递","date":"2026-10-19","time":"15:00","repeat":null,"tags":[],"priority":0},{"type":"todo","content":"交周报","date":"2026-10-23","time":null,"repeat":"每周五","tags":[],"priority":0}]}
"""#
        return base + (sjz ? sjzSection : "")
    }

    /// 连接了结审时追加：几个口令类型，让审计工作里的话直接记进结审（取证单 / 线索 / 项目日志）
    private static let sjzSection = #"""


【结审口令（连接了结审才有）】
用户在做审计工作，口述时可以用口令把内容记进「结审」。type 除上面四种外，还可以是下面四种，**只有用户明确说了口令才用，不能自己根据内容猜**：
- "evidence"（证据）：口令「证据 / 记为证据 / 存为证据 / 保存为证据 / 记个证据」。
- "regulation"（法规）：口令「法规 / 记为法规 / 存为法规 / 保存为法规 / 条文」。
- "clue"（线索）：口令「线索 / 记个线索 / 记为线索 / 发现一条线索 / 疑点线索」。
- "idea"（想法）：口令「想法 / 记个想法 / 审计想法 / 记到工作日志 / 阅读笔记」。
规则：
- 口令本身（含它后面的冒号、逗号）不要写进 content；content 只是口令之后的正文，只去语气词、改同音错字、加标点，不要改写、不要总结、不要扩写，数字、金额、单位名、人名、文号照原样保留。
- 这四种类型的 date、time 一律 null，priority 填 0，repeat 填 null；标签只有明确说了「标签 xxx」才填。
- 一句话里「待办」和结审口令可以并存（「证据，xxx。另外明天提醒我交周报」→ 一条 evidence + 一条 todo）；口令后面一整段都属于同一条，不要拆。
- 没有这四个口令时，仍然按上面的规则判断（默认 daily），绝对不要出现这四种类型。
示例：
输入：证据，大湖镇公益性公墓目前共有三百二十个墓穴，已使用一百八十个
输出：{"items":[{"type":"evidence","content":"大湖镇公益性公墓目前共有三百二十个墓穴，已使用一百八十个。","date":null,"time":null,"repeat":null,"tags":[],"priority":0}]}
输入：记个线索，陆河县没有编写十四五规划，原因是资金不足
输出：{"items":[{"type":"clue","content":"陆河县没有编写十四五规划，原因是资金不足。","date":null,"time":null,"repeat":null,"tags":[],"priority":0}]}
输入：想法，可以对比一下省里十四五规划里的殡葬设施指标
输出：{"items":[{"type":"idea","content":"可以对比一下省里十四五规划里的殡葬设施指标。","date":null,"time":null,"repeat":null,"tags":[],"priority":0}]}
输入：法规，第十三条，政府投资项目应当按照规定履行审批程序
输出：{"items":[{"type":"regulation","content":"第十三条，政府投资项目应当按照规定履行审批程序。","date":null,"time":null,"repeat":null,"tags":[],"priority":0}]}
"""#

    /// 用户消息：就是转写原文
    static func userPrompt(_ raw: String) -> String { "语音转写：" + raw }

    private static let maxItems = 8
    private static let reDate = RX(#"^\d{4}-\d{2}-\d{2}$"#, multiline: false)
    private static let reTime = RX(#"^\s*(\d{1,2})[:：](\d{2})"#, multiline: false)
    private static let queryRanges: Set<String> = ["today", "tomorrow", "week", "overdue", "all"]

    /// 解析模型回复，得到一项或多项；不是合法 JSON / 没有可用的项返回空数组。兼容 `{"items":[…]}` 和单个对象。
    static func parse(_ reply: String) -> [VoiceIntent] {
        guard let root = LlmClient.extractJSON(reply) else { return [] }
        let items = (root["items"] as? [[String: Any]]) ?? [root]
        return items.prefix(maxItems).compactMap(parseOne)
    }

    private static func str(_ o: [String: Any], _ k: String) -> String? {
        if let s = o[k] as? String { return s }
        if let n = o[k] as? NSNumber, !(o[k] is Bool) { return n.stringValue }
        return nil
    }

    private static func flag(_ o: [String: Any], _ k: String) -> Bool {
        if let b = o[k] as? Bool { return b }
        return (o[k] as? String)?.lowercased() == "true"
    }

    private static func cleanDate(_ s: String?) -> String? {
        guard let t = s?.trimmed, reDate.fullMatch(in: t) != nil, Day.parse(t) != nil else { return nil }
        return t
    }

    private static func cleanTime(_ s: String?) -> String? {
        guard let s, let m = reTime.first(in: s), let h = Int(m.group(1)), let mm = Int(m.group(2)), h < 24, mm < 60 else { return nil }
        return String(format: "%02d:%02d", h, mm)
    }

    private static func cleanPriority(_ o: [String: Any]) -> Int {
        let p = (o["priority"] as? Int) ?? Int(str(o, "priority") ?? "") ?? 0
        return p >= 5 ? 5 : (p >= 3 ? 3 : (p >= 1 ? 1 : 0))
    }

    private static func parseOne(_ o: [String: Any]) -> VoiceIntent? {
        let content = (str(o, "content") ?? "").trimmed
        let rawType = (str(o, "type") ?? "").trimmed.lowercased()
        if rawType == "todo", flag(o, "edit") { return parseEdit(o, content) }
        if content.isEmpty { return nil }
        let ask = rawType == "ask"
        let type: CaptureKind
        switch rawType {
        case "todo": type = .todo
        case "daily", "ask": type = .daily
        case "note": type = .note
        // 结审口令（模型只有在连接了结审、用户明确说了口令时才会给；没连接结审的由调用方退回日记）
        case "evidence": type = .evidence
        case "regulation": type = .regulation
        case "clue": type = .clue
        case "idea": type = .idea
        default: return nil
        }
        let todo = type == .todo
        let append = !ask && flag(o, "append")
        let tags = ((o["tags"] as? [Any]) ?? []).compactMap { ($0 as? String)?.trimmed.replacingOccurrences(of: "#", with: "") }
            .filter { !$0.isEmpty && !$0.contains(where: \.isWhitespace) }.prefix(5)
        let repeatText = todo ? str(o, "repeat")?.trimmed.nonEmpty.flatMap { $0.lowercased() == "null" ? nil : $0 } : nil
        return VoiceIntent(
            type: append ? .note : type, content: content,
            date: todo && !append ? cleanDate(str(o, "date")) : nil,
            time: todo && !append ? cleanTime(str(o, "time")) : nil,
            repeatText: append ? nil : repeatText,
            tags: Array(tags),
            priority: todo && !append ? cleanPriority(o) : 0,
            ask: ask, append: append
        )
    }

    private static func parseEdit(_ o: [String: Any], _ content: String) -> VoiceIntent? {
        let op: TodoOp
        switch (str(o, "op") ?? "").trimmed.lowercased() {
        case "complete", "done", "finish": op = .complete
        case "delete", "remove": op = .delete
        case "query", "list", "search": op = .query
        default: op = .edit
        }
        let target = str(o, "target")?.trimmed.nonEmpty.flatMap { $0.lowercased() == "null" ? nil : $0 }
        var v = VoiceIntent(type: .todo, content: "", edit: true, target: target, op: op)
        switch op {
        case .query:
            let r = (str(o, "range") ?? "").trimmed.lowercased()
            v.range = queryRanges.contains(r) ? r : "today"
            return v
        case .complete, .delete:
            return v
        case .edit:
            v.content = content
            v.date = cleanDate(str(o, "date"))
            v.time = cleanTime(str(o, "time"))
            v.priority = cleanPriority(o)
            if content.isEmpty && v.date == nil && v.time == nil && v.priority == 0 { return nil }
            return v
        }
    }

    /// 「半小时后 / 两小时后 / 十分钟后」这类相对现在的说法，本地用规则再精确算一遍，不依赖模型的心算：
    /// 转写里恰好有一个这样的说法、而且整理结果里恰好有一条新建待办时，直接把它的日期和时间改成算出来的那一刻。
    static func fixRelativeTime(_ raw: String, _ intents: [VoiceIntent], now: Date = Date()) -> [VoiceIntent] {
        guard let found = TodoParser.findAfterDuration(raw, now: now) else { return intents }
        let fresh = intents.filter { $0.type == .todo && !$0.edit && !$0.ask && !$0.append }
        guard fresh.count == 1 else { return intents }
        let c = Calendar.current.dateComponents([.hour, .minute], from: found.0)
        return intents.map { i in
            guard i.id == fresh[0].id else { return i }
            var n = i
            n.date = Day.string(found.0)
            n.time = String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
            return n
        }
    }

    private static let sequenceMarkers = ["然后", "接着", "接下来", "之后", "随后", "最后", "再", "先"]
    private static let reHours = RX(#"([0-9]+(?:\.[0-9]+)?|[零〇一二两三四五六七八九十]{1,3})\s*(?:个)?\s*(半)?\s*(?:小时|钟头)"#, multiline: false)
    private static let reHalfHour = RX(#"半\s*(?:个)?\s*(?:小时|钟头)"#, multiline: false)
    private static let reMinutes = RX(#"([0-9]+|[零〇一二两三四五六七八九十]{1,3})\s*分钟"#, multiline: false)

    /// 「一二两三…十」「二十五」「15」→ 数字（只认 0–99）
    private static func number(_ s: String) -> Double? {
        if let d = Double(s) { return d }
        let digit: [Character: Int] = ["零": 0, "〇": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9]
        let chars = Array(s)
        guard let ten = chars.firstIndex(of: "十") else { return chars.count == 1 ? digit[chars[0]].map(Double.init) : nil }
        let head = chars[..<ten], tail = chars[(ten + 1)...]
        let tens = head.isEmpty ? 1 : (head.count == 1 ? digit[head.first!] : nil)
        let ones = tail.isEmpty ? 0 : (tail.count == 1 ? digit[tail.first!] : nil)
        guard let t = tens, let o = ones else { return nil }
        return Double(t * 10 + o)
    }

    /// 任务名里说了多久（「看二十分钟书」「开一个半小时的会」「约 15 分钟」）→ 分钟数；没说返回 nil
    static func spokenMinutes(_ text: String) -> Int? {
        var total = 0.0
        if let m = reHours.first(in: text), let h = number(m.group(1)) {
            total += h * 60
            if m.hasGroup(2) { total += 30 }
        } else if reHalfHour.first(in: text) != nil {
            total += 30
        }
        if let m = reMinutes.first(in: text), let n = number(m.group(1)) { total += n }
        let mins = Int(total.rounded())
        return (1 ... 12 * 60).contains(mins) ? mins : nil
    }

    /// 保底：模型没把「先 A 然后 B 接着 C」的日期 / 时间延续下去时，本地补上。
    /// 只在转写里有顺序词、且有多条新建待办时生效；只补空缺，不改模型已经给出的值，也不动重复待办。
    ///   · 日期：后一条没日期，沿用前一条的日期
    ///   · 时间：后一条没时间、前一条有时间且同一天，排在前一条之后：前一条任务名里说了时长就加上时长，否则加 1 小时（过了当天 23:59 就不补）
    static func carryContinuity(_ raw: String, _ intents: [VoiceIntent]) -> [VoiceIntent] {
        guard sequenceMarkers.contains(where: { raw.contains($0) }) else { return intents }
        var out = intents
        var prev: Int?
        for idx in out.indices {
            let i = out[idx]
            guard i.type == .todo, !i.edit, !i.ask, !i.append else { continue }
            defer { prev = idx }
            guard let p = prev, i.repeatText == nil, out[p].repeatText == nil else { continue }
            if out[idx].date == nil, let d = out[p].date { out[idx].date = d }
            if out[idx].time == nil, out[idx].date == out[p].date, let t = out[p].time,
               let m = reTime.first(in: t), let h = Int(m.group(1)), let mm = Int(m.group(2)) {
                let total = h * 60 + mm + (spokenMinutes(out[p].content) ?? 60)
                if total < 24 * 60 { out[idx].time = String(format: "%02d:%02d", total / 60, total % 60) }
            }
        }
        return out
    }

    private static let askMarkers = ["AI", "ai", "Ai", "助手", "帮我查", "帮我搜", "查一下", "搜一下", "搜索", "问一下", "问问", "请问", "解释一下", "帮我解释", "帮我分析", "帮我总结", "帮我翻译"]

    /// 保底：模型把自言自语当成「问 AI」时，转写里没有任何明确对 AI 说话的词，就改回普通记录（日记）
    static func guardAsk(_ raw: String, _ intents: [VoiceIntent]) -> [VoiceIntent] {
        guard !askMarkers.contains(where: { raw.contains($0) }) else { return intents }
        return intents.map { i in
            guard i.ask else { return i }
            var n = i
            n.ask = false
            n.type = .daily
            return n
        }
    }
}
