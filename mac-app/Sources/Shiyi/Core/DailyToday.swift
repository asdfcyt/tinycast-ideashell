import Foundation

/// 本机留存的「今天的 Daily Note」，下次启动先显示
struct DailyTodayCache: Codable {
    var day: String
    var data: DailyDay?
}

extension AppModel {
    /// 读今天的 Daily Note。和热力图、往日回顾一样：先显示缓存，3 分钟内不重读；
    /// 自己写了 / 删了日记、或者笔记列表变了的时候用 `ifStale: false` 强制读一次（读的时候旧内容一直留在界面上，不闪）
    func loadDailyToday(ifStale: Bool = true) async {
        guard hasIdeashell else { dailyToday = nil; return }
        let key = Day.today()
        if dailyTodayDay != key { dailyToday = nil; dailyTodayDay = key }   // 过了零点，昨天的不再显示
        if ifStale, isFresh("dailyToday", key: key, within: 180) { return }
        guard beginLoad("dailyToday", ifStale: ifStale) else { return }
        defer { endLoad("dailyToday") }
        do {
            let d = try await daily.days(from: key, to: key)
            dailyToday = d[key]
            Self.writeCache("daily-today.json", DailyTodayCache(day: key, data: d[key]))
            stamp("dailyToday", key: key)
        } catch {
            // 读失败就沿用上次的，不打扰
        }
    }
}
