import Foundation

/// 语音转写的本地清洗（没配 AI 或 AI 失败时用，对应安卓端 `SpeechCleaner`）：只做稳妥的几件事，不改写意思。
/// - 去掉独立成句的语气词（嗯、呃、额、啊）和句首的「那个，」「就是，」「然后，」；
/// - 单句末尾的句号去掉（待办标题带个句号很怪）。
/// 日期 / 时间不在这里处理，交给后面的 TodoParser。
enum SpeechCleaner {
    private static let reFiller = RX(#"(?:^|(?<=[，。,.！？!?、\s]))(?:嗯+|呃+|额+|唔+|啊+)(?:[，。,.、\s]+|$)"#, multiline: false)
    private static let reLeading = RX(#"^(?:那个|这个|就是|然后|就是说)[，,、]\s*"#, multiline: false)
    private static let reSpaces = RX(#"[ \t]{2,}"#, multiline: false)

    static func clean(_ raw: String) -> String {
        var s = raw.trimmed
        s = reFiller.replace(in: s, with: "")
        s = reLeading.replace(in: s, with: "")
        s = reSpaces.replace(in: s, with: " ").trimmed
        if s.hasSuffix("。"), s.filter({ $0 == "。" }).count == 1 { s.removeLast() }
        return s.isEmpty ? raw.trimmed : s
    }

    private static let target = #"(?:上一条|上一个|上个|上一篇|最近一条|最近的|刚才那条|刚才那个|刚才的|刚刚那条)"#
    private static let reAppendHead = RX(
        #"^[，,。\s]*(?:请|麻烦)?(?:帮我)?(?:把(?:下面|这句话|这段话|这个|以下)?)?(?:追加|补充|接着写|续写|加)(?:到|在|进|入)"# + target + #"(?:笔记|记录|日记)?(?:里面|里|中|后面)?[，,：:。\s]*"#,
        multiline: false
    )
    private static let reAppendTail = RX(
        #"[，,。\s]*(?:请|麻烦)?(?:帮我)?(?:追加|补充|续写)(?:到|在|进|入)"# + target + #"(?:笔记|记录|日记)?(?:里面|里|中|后面)?[。\s]*$"#,
        multiline: false
    )

    /// 转写开头 / 结尾有「追加到上一条笔记」这类口令时，返回去掉口令后的正文；没有口令返回 nil。
    static func stripAppendCommand(_ raw: String) -> String? {
        let ns = raw as NSString
        let rest: String
        if let head = reAppendHead.first(in: raw) {
            rest = ns.substring(from: head.range.location + head.range.length)
        } else if let tail = reAppendTail.first(in: raw) {
            rest = ns.substring(to: tail.range.location)
        } else {
            return nil
        }
        let t = rest.trimmed
        return t.isEmpty ? nil : t
    }
}
