import AppKit
import Combine
import CryptoKit
import Foundation
import IOKit.pwr_mgt

// MARK: - 整个屏幕变黑白

/// 系统「辅助功能 → 显示 → 色彩滤镜 → 灰度」的开关。作用在所有显示器、所有 App 上，不是盖一层窗口，也不挡操作。
/// 用的是 MediaAccessibility 里没公开声明的函数，运行时按名字取，取不到就当作不支持（不会崩）。
enum ScreenGrayscale {
    private typealias SetFn = @convention(c) (Int32, Bool) -> Void
    private typealias GetFn = @convention(c) (Int32) -> Bool

    private static let handle = dlopen("/System/Library/Frameworks/MediaAccessibility.framework/MediaAccessibility", RTLD_NOW)
    private static let setFn: SetFn? = handle.flatMap { dlsym($0, "MADisplayFilterPrefSetCategoryEnabled") }.map { unsafeBitCast($0, to: SetFn.self) }
    private static let getFn: GetFn? = handle.flatMap { dlsym($0, "MADisplayFilterPrefGetCategoryEnabled") }.map { unsafeBitCast($0, to: GetFn.self) }
    /// 滤镜类别 1 = 灰度
    private static let grayscale: Int32 = 1

    /// 灰度强度（系统里 0 = 没效果，1 = 完全灰度；没设置过就是 1）
    private typealias IntensityGet = @convention(c) () -> Double
    private typealias IntensitySet = @convention(c) (Double) -> Void
    private static let intensityGet: IntensityGet? = handle.flatMap { dlsym($0, "MADisplayFilterPrefGetGrayscaleCorrectionIntensity") }.map { unsafeBitCast($0, to: IntensityGet.self) }
    private static let intensitySet: IntensitySet? = handle.flatMap { dlsym($0, "MADisplayFilterPrefSetGrayscaleCorrectionIntensity") }.map { unsafeBitCast($0, to: IntensitySet.self) }
    /// 打开黑白前强度不是 1 时，原来的值记在这里，关掉时还原
    private static let savedIntensityKey = "sedentary.savedIntensity"

    static var available: Bool { setFn != nil && getFn != nil }
    static var isOn: Bool { getFn?(grayscale) ?? false }
    /// 开着、而且强度是满的（用户在系统设置里把滤镜关掉 / 调淡，这里会是 false）
    static var isFullyOn: Bool {
        guard isOn else { return false }
        if let get = intensityGet { let v = get(); return v >= 0.999 || v < 0 }
        return true
    }

    static func set(_ on: Bool) {
        let ud = UserDefaults.standard
        if on {
            // 强度被改低过的话，滤镜只是淡淡的灰，不是黑白：先拉满
            if let get = intensityGet, let put = intensitySet {
                let cur = get()
                if cur < 0.999, cur >= 0 {
                    if ud.object(forKey: savedIntensityKey) == nil { ud.set(cur, forKey: savedIntensityKey) }
                    put(1.0)
                }
            }
            setFn?(grayscale, true)
        } else {
            setFn?(grayscale, false)
            if let saved = ud.object(forKey: savedIntensityKey) as? Double {
                intensitySet?(saved)
                ud.removeObject(forKey: savedIntensityKey)
            }
        }
    }
}

// MARK: - 久坐提醒

/// 设置页读写同一批键
enum SedentaryPrefs {
    static let enabled = "sedentary.enabled"
    /// 连续使用多少分钟后提醒
    static let interval = "sedentary.interval"
    /// 离开电脑（键鼠没动）多少分钟算「起身休息了」，黑白就恢复
    static let restIdle = "sedentary.restIdle"
    /// 黑白前 1 分钟先发一条通知（可以「再等 5 分钟」）
    static let warn = "sedentary.warn"
    /// 正在专注计时、或有 App 在播视频 / 开会（占着屏幕不休眠）时不打扰，等空下来再提醒
    static let respectBusy = "sedentary.respectBusy"
    /// 黑白是我们打开的：记在本机，应用异常退出后下次启动会据此恢复
    static let grayOn = "sedentary.grayOn"

    static func register() {
        UserDefaults.standard.register(defaults: [
            enabled: true, interval: 45, restIdle: 3, warn: true, respectBusy: true,
        ])
    }
}

/// 提前退出黑白用的解锁口令：只存加盐哈希。设置 / 修改 / 清除都要先输对旧口令；连续输错 3 次，口令入口锁 5 分钟（只能走挑战）。
enum SedentaryPin {
    private static let hashKey = "sedentary.pinHash"
    private static let saltKey = "sedentary.pinSalt"
    private static var fails = 0
    private(set) static var lockedUntil: Date?

    static var isSet: Bool { UserDefaults.standard.string(forKey: hashKey) != nil }
    static var isLocked: Bool { (lockedUntil ?? .distantPast) > Date() }

    private static func digest(_ pin: String, salt: String) -> String {
        SHA256.hash(data: Data((salt + pin).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func set(_ pin: String) {
        let salt = UUID().uuidString
        UserDefaults.standard.set(salt, forKey: saltKey)
        UserDefaults.standard.set(digest(pin, salt: salt), forKey: hashKey)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: hashKey)
        UserDefaults.standard.removeObject(forKey: saltKey)
    }

    /// 不计入输错次数（改口令时校验旧口令用）
    static func matches(_ pin: String) -> Bool {
        let ud = UserDefaults.standard
        guard let h = ud.string(forKey: hashKey), let salt = ud.string(forKey: saltKey) else { return false }
        return digest(pin, salt: salt) == h
    }

    /// 解锁时校验：输错累计，3 次锁 5 分钟
    static func verify(_ pin: String) -> Bool {
        if isLocked { return false }
        if matches(pin) { fails = 0; return true }
        fails += 1
        if fails >= 3 { fails = 0; lockedUntil = Date().addingTimeInterval(5 * 60) }
        return false
    }

    /// 设置页里的「设置 / 修改 / 清除」：弹系统对话框。返回口令是否有变化。
    @MainActor
    static func edit(clear wantsClear: Bool) -> Bool {
        if isSet {
            guard let old = ask(title: wantsClear ? "清除解锁口令" : "修改解锁口令", info: "先输入当前口令。", labels: ["当前口令"]) else { return false }
            guard matches(old[0]) else {
                let a = NSAlert(); a.messageText = "口令不对"; a.addButton(withTitle: "好"); a.runModal()
                return false
            }
            if wantsClear { clear(); return true }
        }
        guard let new = ask(title: "设置解锁口令", info: "4–12 位。黑白期间提前退出时输入它，忘了只能等黑白自然结束。", labels: ["新口令", "再输一次"]) else { return false }
        guard new[0].count >= 4, new[0].count <= 12, new[0] == new[1] else {
            let a = NSAlert(); a.messageText = "两次输入要一致，长度 4–12 位"; a.addButton(withTitle: "好"); a.runModal()
            return false
        }
        set(new[0])
        return true
    }

    @MainActor
    private static func ask(title: String, info: String, labels: [String]) -> [String]? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = info
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        var fields: [NSSecureTextField] = []
        for l in labels {
            let f = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
            f.placeholderString = l
            stack.addArrangedSubview(f)
            fields.append(f)
        }
        stack.frame = NSRect(x: 0, y: 0, width: 240, height: CGFloat(labels.count) * 30)
        alert.accessoryView = stack
        alert.window.initialFirstResponder = fields.first
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return fields.map(\.stringValue)
    }
}

/// 久坐提醒：连续使用电脑满设定时间 → 整个屏幕变黑白；真的离开电脑一阵子（键鼠没动）才恢复彩色。
/// - 「连续使用」：键盘鼠标有动静就累计，歇一会儿不清零，离开 5 分钟以上（或睡眠 / 锁屏）才重新计时；
/// - 黑白前可以「再等 5 分钟」（每轮最多 2 次）；黑白期间提前退出要输解锁口令或完成挑战；
/// - 退出应用 / 睡眠时一定恢复彩色，异常退出的话下次启动也会恢复。
@MainActor
final class SedentaryReminder: ObservableObject {
    static let shared = SedentaryReminder()

    enum Phase: Equatable { case counting, gray }

    @Published private(set) var phase: Phase = .counting
    /// 已经连续使用的秒数
    @Published private(set) var activeSeconds: Double = 0
    /// 时间到了但在专注 / 看视频，先推迟
    @Published private(set) var deferred = false
    @Published private(set) var previewing = false
    /// 键鼠已经多久没动（黑白期间，卡片上用来显示「离开了多久」）
    @Published private(set) var idle: Double = 0
    /// 触发黑白时已经连续用了多少分钟（卡片上显示）
    @Published private(set) var usedMinutes = 0
    /// 卡片上推荐的休息动作：起点随机，「换一个」往后翻
    @Published private(set) var moveOffset = 0
    /// 这一轮已经推迟了几次
    @Published private(set) var postponed = 0
    static let maxPostpones = 2
    var canPostpone: Bool { phase == .counting && !previewing && postponed < Self.maxPostpones }
    private var moveSeed = 0

    var currentMove: BreakMove {
        let pool = BreakMoves.pool(long: true)
        return pool[(moveSeed + moveOffset) % pool.count]
    }

    func nextMove() { moveOffset += 1 }

    /// 正在休息（黑白中 / 预览中）：灵动岛上显示休息进度
    var resting: Bool { phase == .gray || previewing }
    /// 离恢复彩色还差多少秒（按键鼠实时空闲时间算，给灵动岛每秒刷新用）
    func restRemaining() -> Double { max(Double(restIdleMin * 60) - Self.idleSeconds(), 0) }
    func restProgress() -> Double { min(Self.idleSeconds() / Double(restIdleMin * 60), 1) }

    nonisolated static let warnCategory = "shiyi.sedentary.warn"
    nonisolated static let snoozeAction = "sedentary.snooze"
    private static let awayResetSeconds: Double = 5 * 60

    private var timer: Timer?
    private var lastTick = Date()
    private var warned = false
    private var grayStartedAt: Date?
    private var previewTask: Task<Void, Never>?
    /// 黑白期间盯着系统滤镜：用户去系统设置里关掉 / 调淡，立刻重新打开
    private var guardTimer: Timer?
    private var terminating = false
    private weak var focus: FocusStore?
    private let ud = UserDefaults.standard

    var enabled: Bool { ud.bool(forKey: SedentaryPrefs.enabled) }
    var intervalMin: Int { max(ud.integer(forKey: SedentaryPrefs.interval), 5) }
    var restIdleMin: Int { max(ud.integer(forKey: SedentaryPrefs.restIdle), 1) }
    var limitSeconds: Double { Double(intervalMin * 60) }
    /// 离黑白还有多少秒（已经在黑白 / 没开启时为 nil）
    var secondsLeft: Double? {
        guard enabled, phase == .counting else { return nil }
        return max(limitSeconds - activeSeconds, 0)
    }

    func start(focus: FocusStore) {
        guard timer == nil else { return }
        self.focus = focus
        SedentaryPrefs.register()
        // 上次异常退出时留下的黑白：先恢复
        if ud.bool(forKey: SedentaryPrefs.grayOn) {
            ScreenGrayscale.set(false)
            ud.set(false, forKey: SedentaryPrefs.grayOn)
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { SedentaryReminder.shared.terminating = true; SedentaryReminder.shared.restoreColor() }
        }
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { SedentaryReminder.shared.leftDesk() }
            }
        }
        // 系统设置里改了滤镜会发这个通知：黑白期间立刻改回来
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), nil, { _, _, _, _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { SedentaryReminder.shared.enforceGray() } }
        }, "com.apple.mediaaccessibility.displayFilterSettingsChanged" as CFString, nil, .deliverImmediately)
        lastTick = Date()
        let t = Timer(timeInterval: 5, repeats: true) { _ in
            MainActor.assumeIsolated { SedentaryReminder.shared.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: 计时

    private func tick() {
        let now = Date()
        let dt = min(now.timeIntervalSince(lastTick), 30)
        lastTick = now

        guard enabled else {
            if phase == .gray { endGray() }
            activeSeconds = 0; warned = false; deferred = false
            return
        }
        let idle = Self.idleSeconds()
        self.idle = idle

        if phase == .gray {
            // 真的离开了一阵子：恢复彩色，重新计时
            if idle >= Double(restIdleMin * 60) { endGray() }
            return
        }
        if previewing { return }

        // 番茄钟的休息时段本来就是在休息：算起身了，重新计时，不再变黑白
        if let r = focus?.run, r.kind.isBreak {
            activeSeconds = 0; warned = false; deferred = false; postponed = 0
            return
        }

        if idle >= Self.awayResetSeconds {
            activeSeconds = 0; warned = false; deferred = false; postponed = 0
            return
        }
        activeSeconds += dt

        let limit = limitSeconds
        if ud.bool(forKey: SedentaryPrefs.warn), !warned, activeSeconds >= limit - 60, activeSeconds < limit, !isBusy() {
            warned = true
            Notifier.post(id: "shiyi.sedentary.warn", title: "1 分钟后屏幕变黑白", body: "已经连续使用 \(Int(activeSeconds / 60)) 分钟，该起来动一动了。",
                          category: Self.warnCategory)
        }
        if activeSeconds >= limit {
            if isBusy() { deferred = true; return }
            deferred = false
            beginGray()
        }
    }

    /// 睡眠 / 锁屏 / 合盖：算离开了
    private func leftDesk() {
        if phase == .gray { endGray() } else { activeSeconds = 0; warned = false; deferred = false; postponed = 0 }
        previewTask?.cancel()
        if previewing { previewing = false; restoreColor(); SedentaryCardController.shared.hide() }
    }

    static func idleSeconds() -> Double {
        guard let any = CGEventType(rawValue: ~0) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: any)
    }

    // MARK: 黑白

    private func beginGray() {
        warned = false
        guard ScreenGrayscale.available else {
            // 系统不支持：退回成一条通知
            Notifier.post(id: "shiyi.sedentary", title: "该起来活动了", body: "已经连续使用 \(Int(activeSeconds / 60)) 分钟，站起来走一走、看看远处。")
            activeSeconds = 0
            return
        }
        phase = .gray
        grayStartedAt = Date()
        usedMinutes = Int(activeSeconds / 60)
        newMove()
        if !ScreenGrayscale.isOn {
            ScreenGrayscale.set(true)
            ud.set(true, forKey: SedentaryPrefs.grayOn)
        }
        startGuard()
        SedentaryCardController.shared.show()
        Notifier.post(id: "shiyi.sedentary", title: "该起来活动了", body: "已经连续使用 \(Int(activeSeconds / 60)) 分钟，屏幕变黑白了。离开电脑 \(restIdleMin) 分钟，就会恢复彩色。")
    }

    private func newMove() {
        moveSeed = Int.random(in: 0 ..< 1000)
        moveOffset = 0
    }

    private func startGuard() {
        guardTimer?.invalidate()
        let t = Timer(timeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { SedentaryReminder.shared.enforceGray() }
        }
        RunLoop.main.add(t, forMode: .common)
        guardTimer = t
    }

    /// 黑白期间系统滤镜被关掉 / 调淡了（多半是去系统设置里绕过）：改回来
    private func enforceGray() {
        guard phase == .gray, !terminating, !ScreenGrayscale.isFullyOn else { return }
        ScreenGrayscale.set(true)
        ud.set(true, forKey: SedentaryPrefs.grayOn)
    }

    private func endGray() {
        guardTimer?.invalidate()
        guardTimer = nil
        SedentaryCardController.shared.hide()
        restoreColor()
        phase = .counting
        activeSeconds = 0
        warned = false
        deferred = false
        postponed = 0
        grayStartedAt = nil
        Notifier.cancel(["shiyi.sedentary"])
    }

    /// 只把我们打开的黑白关掉（用户原本就开着灰度的不动）
    private func restoreColor() {
        if ud.bool(forKey: SedentaryPrefs.grayOn) {
            ScreenGrayscale.set(false)
            ud.set(false, forKey: SedentaryPrefs.grayOn)
            // 偶尔系统没响应：稍后确认一次，没关掉就再关
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                MainActor.assumeIsolated {
                    let r = SedentaryReminder.shared
                    if r.phase != .gray, !r.previewing, ScreenGrayscale.isOn { ScreenGrayscale.set(false) }
                }
            }
        }
    }

    // MARK: 操作

    /// 黑白期间想提前退出：弹出解锁窗口（口令 / 挑战），通过后才恢复彩色
    func requestEarlyExit() {
        guard phase == .gray else { return }
        SedentaryUnlockController.shared.show()
    }

    /// 解锁窗口验证通过后调用
    func earlyExitGranted() {
        guard phase == .gray else { return }
        endGray()
    }

    /// 「再等 5 分钟」：把已用时间拨回到离黑白还剩 5 分钟；每轮最多 maxPostpones 次
    func snooze() {
        guard canPostpone else { return }
        postponed += 1
        activeSeconds = max(limitSeconds - 5 * 60, 0)
        warned = false
        deferred = false
        Notifier.cancel(["shiyi.sedentary.warn"])
    }

    /// 设置页的「预览」：整个屏幕变黑白 6 秒再恢复
    func preview() {
        guard phase == .counting, !previewing, ScreenGrayscale.available else { return }
        previewing = true
        usedMinutes = intervalMin
        newMove()
        SedentaryCardController.shared.show()
        let wasOn = ScreenGrayscale.isOn
        if !wasOn { ScreenGrayscale.set(true); ud.set(true, forKey: SedentaryPrefs.grayOn) }
        previewTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard let self, self.previewing else { return }
            self.previewing = false
            self.restoreColor()
            SedentaryCardController.shared.hide()
        }
    }

    // MARK: 「不打扰」条件

    private func isBusy() -> Bool {
        // 专注计时中一律不打扰（不受设置开关影响）
        if let r = focus?.run, !r.kind.isBreak { return true }
        guard ud.bool(forKey: SedentaryPrefs.respectBusy) else { return false }
        return Self.displayHeldAwake()
    }

    /// 有别的进程（播视频、开会、演示）申请了「不让显示器休眠」
    private static func displayHeldAwake() -> Bool {
        var raw: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&raw) == kIOReturnSuccess, let dict = raw?.takeRetainedValue() as NSDictionary? else { return false }
        let me = NSNumber(value: ProcessInfo.processInfo.processIdentifier)
        for (pid, value) in dict {
            if let p = pid as? NSNumber, p == me { continue }
            for item in (value as? [[String: Any]]) ?? [] {
                let type = item["AssertType"] as? String ?? ""
                let level = (item["AssertLevel"] as? NSNumber)?.intValue ?? 0
                if level == 1, type == "PreventUserIdleDisplaySleep" || type == "NoDisplaySleepAssertion" { return true }
            }
        }
        return false
    }
}
