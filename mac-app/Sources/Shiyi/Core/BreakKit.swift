import AppKit
import ApplicationServices
import AVFoundation
import Combine
import Foundation
import IOKit.pwr_mgt

// MARK: - 休息时做什么：内置的微运动库（离线、中文）

/// 一个适合在工位旁做的小动作。`long` = 只在长休息里推荐（要走动 / 出汗的）
struct BreakMove: Identifiable, Equatable {
    let id: String
    let icon: String
    let title: String
    /// 锻炼的部位 / 用途，显示成小标签
    let area: String
    let seconds: Int
    let steps: [String]
    var long = false
}

enum BreakMoves {
    static let all: [BreakMove] = [
        BreakMove(id: "neck", icon: "figure.mind.and.body", title: "颈部侧拉", area: "颈肩", seconds: 60,
                  steps: ["坐直，左手放在身侧，右手轻扶左耳上方", "头慢慢向右肩倾，感觉左侧脖子拉开，保持 15 秒", "换边再来一次，全程不要耸肩"]),
        BreakMove(id: "shoulder", icon: "figure.arms.open", title: "肩部绕环", area: "颈肩", seconds: 45,
                  steps: ["双手自然下垂，肩膀向上耸到耳边", "再向后画一个大圆，慢慢落下，做 10 次", "再向前绕 10 次"]),
        BreakMove(id: "chest", icon: "figure.arms.open", title: "扩胸展臂", area: "胸背", seconds: 45,
                  steps: ["站起来，双手在背后十指交扣", "挺胸，手臂向后向上抬，保持 15 秒", "放松，重复 2 次，边做边深呼吸"]),
        BreakMove(id: "blade", icon: "figure.cooldown", title: "夹背挤肩胛", area: "肩背", seconds: 30,
                  steps: ["坐直，双臂弯曲，手肘向后拉", "像要夹住一支笔一样挤压两侧肩胛骨，保持 5 秒", "放松，重复 6 次"]),
        BreakMove(id: "catcow", icon: "figure.flexibility", title: "坐姿猫牛式", area: "脊柱", seconds: 60,
                  steps: ["双手扶膝，坐在椅子前半部", "吸气，挺胸抬头、腰微微前凸", "呼气，含胸低头、背向后拱，各 6 次，节奏放慢"]),
        BreakMove(id: "twist", icon: "figure.core.training", title: "坐姿转体", area: "腰背", seconds: 60,
                  steps: ["坐直，右手扶住左膝外侧，左手放到椅背", "呼气，上身慢慢向左后方转，保持 15 秒", "换边，各做 2 次，髋部保持朝前"]),
        BreakMove(id: "wrist", icon: "hand.raised", title: "手腕拉伸", area: "手腕", seconds: 45,
                  steps: ["右臂向前伸直，掌心向前，左手把手指向身体方向轻拉 10 秒", "再把手掌向下压，拉伸手腕背面 10 秒", "换手，再做一遍，最后甩甩双手"]),
        BreakMove(id: "finger", icon: "hand.raised.fingers.spread", title: "手指操", area: "手腕", seconds: 30,
                  steps: ["用力握拳 3 秒，再突然张开十指撑到最大", "重复 10 次", "逐根手指轻轻向后掰，每根 2 秒"]),
        BreakMove(id: "far", icon: "eye", title: "20-20-20 远眺", area: "眼睛", seconds: 20,
                  steps: ["起身看向窗外 6 米（20 英尺）以外的地方", "盯着一个远处的点看 20 秒", "眨眨眼，不要再看屏幕"]),
        BreakMove(id: "palming", icon: "eye.slash", title: "搓手捂眼", area: "眼睛", seconds: 30,
                  steps: ["双手用力搓热", "轻轻捂住闭着的眼睛，不要压眼球", "保持黑暗，缓慢呼吸 30 秒"]),
        BreakMove(id: "eyes", icon: "eye", title: "眼球转圈", area: "眼睛", seconds: 30,
                  steps: ["头不动，眼睛看向最上方，再顺时针慢慢转一圈", "转 3 圈后，换逆时针 3 圈", "最后用力眨眼 10 次"]),
        BreakMove(id: "stretch", icon: "figure.arms.open", title: "站起来伸懒腰", area: "全身", seconds: 30,
                  steps: ["站起来，双手十指交叉，掌心向上推过头顶", "踮起脚尖，身体尽量向上拉长 10 秒", "放松，左右各侧弯一次"]),
        BreakMove(id: "wall", icon: "figure.stand", title: "靠墙站立", area: "体态", seconds: 60,
                  steps: ["后脑勺、肩胛、臀部、脚跟都贴住墙", "收下巴，腹部微收，保持 1 分钟", "感受一下脊柱真正站直的样子"]),
        BreakMove(id: "calf", icon: "figure.stairs", title: "小腿提踵", area: "下肢", seconds: 45,
                  steps: ["双脚与肩同宽，手扶桌沿", "慢慢踮起脚尖，顶端停 2 秒，再慢慢放下", "做 15 次，促进久坐后的血液回流"]),
        BreakMove(id: "squat", icon: "figure.strengthtraining.functional", title: "坐站练习", area: "下肢", seconds: 60,
                  steps: ["坐在椅子前半部，双臂交叉抱胸", "不借手的力量站起来，再慢慢坐回去", "连续做 10～12 次，膝盖朝脚尖方向"]),
        BreakMove(id: "hamstring", icon: "figure.flexibility", title: "腿后侧拉伸", area: "下肢", seconds: 60,
                  steps: ["站立，右脚跟放在前方一步远的位置、脚尖朝上", "背保持平直，髋向后坐，上身微微前倾", "每条腿保持 20 秒，感觉大腿后侧被拉开"]),
        BreakMove(id: "lunge", icon: "figure.flexibility", title: "弓步拉伸", area: "髋部", seconds: 60,
                  steps: ["右脚向前一大步成弓步，后腿膝盖轻轻着地（可垫个垫子）", "骨盆向前下方压，上身挺直，保持 20 秒", "换边，久坐会让髋前侧很紧，这个动作很解压"]),
        BreakMove(id: "breath", icon: "lungs", title: "腹式深呼吸", area: "放松", seconds: 60,
                  steps: ["坐直，一只手放在腹部", "用鼻子吸气 4 秒，感觉肚子鼓起", "屏住 4 秒，再用嘴慢慢呼气 6 秒，重复 5 轮"]),
        BreakMove(id: "march", icon: "figure.run", title: "原地高抬腿", area: "有氧", seconds: 60,
                  steps: ["站直，交替把膝盖抬到腰的高度", "配合摆臂，保持轻快的节奏", "做 1 分钟，微微出汗最好"], long: true),
        BreakMove(id: "jack", icon: "figure.jumprope", title: "开合跳", area: "有氧", seconds: 45,
                  steps: ["双脚并拢站立，跳起时双脚分开、双臂举过头顶", "再跳回并拢，节奏均匀", "30～40 次，注意落地轻一点（楼下邻居）"], long: true),
        BreakMove(id: "water", icon: "drop", title: "喝水 + 走一走", area: "补水", seconds: 120,
                  steps: ["去接一杯水，边走边喝", "到窗边或走廊站一会儿，看看远处", "回来之前，把水杯带回工位"], long: true),
        BreakMove(id: "stairs", icon: "figure.stairs", title: "走走楼梯", area: "有氧", seconds: 180,
                  steps: ["走到楼梯间，上下走两三层", "保持能说话的强度，扶好扶手", "回来前再做几次深呼吸"], long: true),
    ]

    /// 短休息只推荐短小、不出汗的；长休息所有动作都可以
    static func pool(long: Bool) -> [BreakMove] { long ? all : all.filter { !$0.long } }

    /// 今天这一次休息从哪个动作开始（同一天同一个番茄稳定，不会一重绘就换）
    static func startIndex(cycle: Int) -> Int {
        let day = Day.cal.ordinality(of: .day, in: .year, for: Date()) ?? 1
        return day &* 7 &+ cycle &* 3
    }
}

// MARK: - 环境音：真实录音（CC0，来自 BigSoundBank / LaSonotheque），打包在应用里，离线可用

enum AmbientKind: String, CaseIterable, Identifiable {
    case rain, waves, forest, fire
    var id: String { rawValue }
    var label: String {
        switch self {
        case .rain: return "雨声"
        case .waves: return "海浪"
        case .forest: return "林间溪流"
        case .fire: return "篝火"
        }
    }
    var icon: String {
        switch self {
        case .rain: return "cloud.rain"
        case .waves: return "water.waves"
        case .forest: return "leaf"
        case .fire: return "flame"
        }
    }
    /// 打包进应用的音频文件（已做过响度平衡，首尾做过交叉淡化，可以无缝循环）
    var file: URL? { Bundle.main.url(forResource: rawValue, withExtension: "m4a", subdirectory: "Ambient") ?? Bundle.main.url(forResource: rawValue, withExtension: "m4a") }
}

@MainActor
final class AmbientSound: ObservableObject {
    static let shared = AmbientSound()

    @Published private(set) var current: AmbientKind?
    @Published var volume: Double = 0.7 { didSet { player?.volume = Float(volume) } }

    private var player: AVAudioPlayer?
    private var bag = Set<AnyCancellable>()
    private var attached = false

    /// 休息结束（开始专注或休息走完）时自动停止
    func attach(_ focus: FocusStore) {
        guard !attached else { return }
        attached = true
        focus.$run.combineLatest(focus.$pendingBreak)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] run, pending in
                let resting = run.map { $0.kind.isBreak } ?? (pending != nil)
                if !resting { self?.stop() }
            }
            .store(in: &bag)
    }

    func toggle(_ k: AmbientKind) {
        if current == k { stop() } else { play(k) }
    }

    func play(_ k: AmbientKind) {
        guard let url = k.file, let p = try? AVAudioPlayer(contentsOf: url) else { return }
        // 切换时旧的淡出、新的淡入
        let old = player
        old?.setVolume(0, fadeDuration: 0.6)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { old?.stop() }
        p.numberOfLoops = -1
        p.volume = 0
        p.prepareToPlay()
        p.play()
        p.setVolume(Float(volume), fadeDuration: 1.0)
        player = p
        current = k
    }

    func stop() {
        guard current != nil else { return }
        current = nil
        let p = player
        player = nil
        p?.setVolume(0, fadeDuration: 1.0)
        // 留一点淡出的时间再停
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { p?.stop() }
    }
}

// MARK: - 听歌：遥控本机的「音乐」「Spotify」，其他播放器只能一键打开

struct MusicApp: Identifiable, Equatable {
    let bundleId: String
    let name: String
    /// AppleScript 里的应用名；nil = 没有脚本接口，只能打开
    let script: String?
    var id: String { bundleId }
}

struct MusicTrack: Equatable {
    var app: MusicApp
    var title: String
    var artist: String
    var playing: Bool
    var album = ""
    /// 总时长（秒），0 = 未知
    var duration: Double = 0
    /// 在 `timestamp` 那一刻已播放的秒数
    var elapsed: Double = 0
    /// `elapsed` 的采样时刻（Unix 时间，秒）
    var timestamp: Double = 0
    var rate: Double = 0

    var key: String { "\(title)|\(artist)" }

    /// 此刻的播放位置（秒）：暂停时是定格的位置，播放时按采样时刻往后推
    func position(at date: Date = Date()) -> Double {
        var p = elapsed
        if playing, timestamp > 0 { p += max(date.timeIntervalSince1970 - timestamp, 0) * (rate > 0 ? rate : 1) }
        return duration > 0 ? min(max(p, 0), duration) : max(p, 0)
    }
}

/// 一句歌词：从 `t` 秒开始
struct LyricLine: Equatable {
    var t: Double
    var text: String
}

@MainActor
final class MusicRemote: ObservableObject {
    static let apps = [
        MusicApp(bundleId: "com.apple.Music", name: "音乐", script: "Music"),
        MusicApp(bundleId: "com.spotify.client", name: "Spotify", script: "Spotify"),
        MusicApp(bundleId: "com.netease.163music", name: "网易云音乐", script: nil),
        MusicApp(bundleId: "com.tencent.QQMusicMac", name: "QQ 音乐", script: nil),
    ]

    @Published private(set) var installed: [MusicApp] = []
    @Published private(set) var track: MusicTrack?
    /// 能遥控的播放器正开着，但里面没在播（可以给个播放按钮）
    @Published private(set) var idleApp: MusicApp?
    @Published private(set) var denied = false
    /// 各播放器的应用图标（按需读取并缓存）
    private(set) var icons: [String: NSImage] = [:]

    init() { refresh() }

    private func running(_ a: MusicApp) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: a.bundleId).isEmpty
    }

    func refresh() {
        let have = Self.apps.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleId) != nil }
        for a in have where icons[a.bundleId] == nil {
            if let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: a.bundleId) { icons[a.bundleId] = NSWorkspace.shared.icon(forFile: u.path) }
        }
        if have != installed { installed = have }
        // 只问已经在运行的：对没打开的应用发 AppleScript 会把它启动起来
        let live = installed.filter { $0.script != nil && running($0) }
        // 其余交给系统的「正在播放」（MediaRemote）：网易云音乐、QQ 音乐、浏览器等都能读到歌名；读不到时退回「防休眠断言」判断在不在播
        // 所有查询都在后台跑（osascript 子进程）：AppleScript 要等授权弹窗或目标应用响应，放在主线程上会把整个界面卡住、按钮点不动
        guard !polling else { return }
        polling = true
        Task { [weak self] in
            var found: MusicTrack?
            var idle: MusicApp?
            var blocked = false
            let sys = await Self.querySystem()
            // 系统「正在播放」已经读到歌就不再逐个问播放器了（少起几个 osascript 子进程）；读不到才去问 Music / Spotify，用来判断「开着但没在播」
            if sys == nil || sys?.title.isEmpty == true {
                for a in live {
                    switch await Self.queryApp(a) {
                    case let .track(t):
                        if found == nil || (t.playing && found?.playing == false) { found = t }
                    case .idle:
                        if idle == nil { idle = a }
                    case .denied:
                        blocked = true
                    case .failed:
                        break
                    }
                }
            }
            self?.apply(local: found, idle: idle, blocked: blocked, system: sys)
        }
    }

    private var polling = false
    private var systemOK = false

    /// 当前歌的封面和歌词（来自网易云公开的网页接口，按歌名 + 歌手匹配；匹配不到就没有）
    @Published private(set) var cover: NSImage?
    @Published private(set) var lyrics: [LyricLine] = []
    private var extrasKey = ""
    private var extrasCache: [String: (NSImage?, [LyricLine])] = [:]

    private func apply(local: MusicTrack?, idle: MusicApp?, blocked: Bool, system: SystemNowPlaying?) {
        polling = false
        systemOK = system != nil
        var found = local
        if let sys = system, !sys.title.isEmpty {
            let app = Self.app(forBundle: sys.bundle)
            // 系统给出的歌名和播放状态最准：同一个播放器时以它为准，不同播放器时只在它正在播、本地没有正在播的时候采用
            if found == nil || found?.app.bundleId == app.bundleId || (sys.playing && found?.playing != true) {
                found = MusicTrack(app: app, title: sys.title, artist: sys.artist, playing: sys.playing, album: sys.album,
                                   duration: sys.duration, elapsed: sys.elapsed, timestamp: sys.timestamp, rate: sys.rate)
                systemOK = true
            }
        } else if found?.playing != true {
            let sleepers = Self.sleepAssertionPids()
            for a in installed where a.script == nil {
                let pids = NSRunningApplication.runningApplications(withBundleIdentifier: a.bundleId).map { Int($0.processIdentifier) }
                if pids.contains(where: sleepers.contains) {
                    found = MusicTrack(app: a, title: a.name, artist: "正在播放", playing: true)
                    break
                }
            }
        }
        if track != found { track = found }
        loadExtras(for: found)
        let idleNow = found == nil ? idle : nil
        if idleApp != idleNow { idleApp = idleNow }
        if denied != blocked { denied = blocked }
    }

    private static func app(forBundle id: String) -> MusicApp {
        if let a = apps.first(where: { $0.bundleId == id }) { return a }
        let name = NSRunningApplication.runningApplications(withBundleIdentifier: id).first?.localizedName ?? id
        return MusicApp(bundleId: id, name: name, script: nil)
    }

    struct SystemNowPlaying { var title: String; var artist: String; var album: String; var playing: Bool; var bundle: String; var duration: Double; var elapsed: Double; var timestamp: Double; var rate: Double }

    /// 用 osascript 跑一段 JXA 读系统的「正在播放」。macOS 15.4 起 MediaRemote 只对 Apple 签名的程序开放，
    /// 所以借用系统自带的 /usr/bin/osascript（做法参考开源项目 kernoeb/mac-now-playing、ungive/mediaremote-adapter）。无需任何权限；读不到返回 nil。
    private static let jxa = #"""
    ObjC.import("Foundation");
    function run() {
      try {
        const MR = $.NSBundle.bundleWithPath("/System/Library/PrivateFrameworks/MediaRemote.framework/");
        MR.load;
        const Req = $.NSClassFromString("MRNowPlayingRequest");
        if (!Req) return JSON.stringify({ error: "no request" });
        const out = { isPlaying: Req.localIsPlaying ? true : false };
        const item = Req.localNowPlayingItem;
        if (item && item.nowPlayingInfo) {
          const d = item.nowPlayingInfo;
          const pre = "kMRMediaRemoteNowPlayingInfo";
          const str = (k) => { const v = d.objectForKey(pre + k); return v && !v.isNil() ? ObjC.unwrap(v) : undefined; };
          out.title = str("Title"); out.artist = str("Artist"); out.album = str("Album");
          out.duration = str("Duration"); out.elapsed = str("ElapsedTime"); out.rate = str("PlaybackRate");
          const ts = d.objectForKey(pre + "Timestamp");
          if (ts && !ts.isNil()) out.timestamp = ts.timeIntervalSince1970;
        }
        const pp = Req.localNowPlayingPlayerPath;
        if (pp && pp.client) {
          const c = pp.client;
          if (c.parentApplicationBundleIdentifier && !c.parentApplicationBundleIdentifier.isNil()) out.bundle = ObjC.unwrap(c.parentApplicationBundleIdentifier);
          else if (c.bundleIdentifier && !c.bundleIdentifier.isNil()) out.bundle = ObjC.unwrap(c.bundleIdentifier);
        }
        return JSON.stringify(out);
      } catch (e) { return JSON.stringify({ error: e.toString() }); }
    }
    """#

    nonisolated private static func querySystem() async -> SystemNowPlaying? {
        await withCheckedContinuation { (cont: CheckedContinuation<SystemNowPlaying?, Never>) in
            DispatchQueue.global(qos: .utility).async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                proc.arguments = ["-l", "JavaScript", "-e", jxa]
                let pipe = Pipe()
                proc.standardOutput = pipe
                proc.standardError = FileHandle.nullDevice
                do { try proc.run() } catch { cont.resume(returning: nil); return }
                // osascript 没有超时：卡住时 5 秒后杀掉，免得轮询永远停住
                let dog = DispatchWorkItem { proc.terminate() }
                DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: dog)
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                proc.waitUntilExit()
                dog.cancel()
                guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any], j["error"] == nil else {
                    cont.resume(returning: nil)
                    return
                }
                func num(_ k: String) -> Double { (j[k] as? NSNumber)?.doubleValue ?? 0 }
                cont.resume(returning: SystemNowPlaying(
                    title: (j["title"] as? String) ?? "", artist: (j["artist"] as? String) ?? "", album: (j["album"] as? String) ?? "",
                    playing: (j["isPlaying"] as? Bool) ?? false, bundle: (j["bundle"] as? String) ?? "",
                    duration: num("duration"), elapsed: num("elapsed"), timestamp: num("timestamp"), rate: num("rate")))
            }
        }
    }

    func toggle(_ a: MusicApp) { control(a, "playpause", key: 16) }
    func next(_ a: MusicApp) { control(a, "next track", key: 17) }
    func previous(_ a: MusicApp) { control(a, "previous track", key: 18) }

    /// 有脚本接口的直接发 AppleScript；其他播放器发系统媒体键（交给系统当前的「正在播放」应用）
    private func control(_ a: MusicApp, _ cmd: String, key: Int32) {
        // 网易云没有脚本接口，系统媒体命令和媒体键它也不响应：用辅助功能去点它菜单栏「控制」里的 暂停/播放、下一个、上一个
        if a.bundleId == Self.neteaseId, let idx = Self.menuIndex[key] {
            Self.pressMenu(bundle: a.bundleId, index: idx) { [weak self] ok in
                if !ok { self?.needsAccessibility = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { self?.refresh() }
            }
            return
        }
        // 优先走系统 MediaRemote 命令（发给当前「正在播放」的应用，对网易云也有效）
        if systemOK, let code = Self.commandCodes[key] {
            Self.runSystemCommand([String(code)])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.refresh() }
            return
        }
        if a.script != nil { send(a, cmd) } else {
            Self.mediaKey(key)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.refresh() }
        }
    }

    /// 辅助功能没授权时为 true（卡片上提示去授权）
    @Published var needsAccessibility = false
    private static let neteaseId = "com.netease.163music"
    /// 媒体键编号 → 网易云「控制」菜单里的第几项（暂停/播放、下一个、上一个）
    private static let menuIndex: [Int32: Int] = [16: 0, 17: 1, 18: 2]

    /// 点目标应用菜单栏里「控制」菜单的第 index 项（按有标题的项数，跳过分隔线）。需要「辅助功能」权限
    private static func pressMenu(bundle: String, index: Int, done: @escaping @MainActor (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = axPress(bundle: bundle, index: index)
            DispatchQueue.main.async { done(ok) }
        }
    }

    nonisolated private static func axPress(bundle: String, index: Int) -> Bool {
        let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(opts),
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first else { return false }
        func attr(_ e: AXUIElement, _ k: String) -> CFTypeRef? {
            var v: CFTypeRef?
            return AXUIElementCopyAttributeValue(e, k as CFString, &v) == .success ? v : nil
        }
        func kids(_ e: AXUIElement) -> [AXUIElement] { (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }
        func title(_ e: AXUIElement) -> String { (attr(e, kAXTitleAttribute) as? String) ?? "" }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        guard let bar = attr(root, kAXMenuBarAttribute) else { return false }
        let tops = kids(bar as! AXUIElement)
        let names = ["控制", "Controls", "Control", "播放控制", "Playback"]
        let top = tops.first { names.contains(title($0)) } ?? (tops.count > 3 ? tops[3] : nil)
        guard let top, let menu = kids(top).first else { return false }
        let entries = kids(menu).filter { !title($0).isEmpty }
        guard index < entries.count else { return false }
        return AXUIElementPerformAction(entries[index], kAXPressAction as CFString) == .success
    }

    private static func mediaKey(_ key: Int32) {
        for down in [true, false] {
            let state: Int32 = down ? 0xa00 : 0xb00
            let ev = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state)),
                                        timestamp: 0, windowNumber: 0, context: nil, subtype: 8,
                                        data1: Int((key << 16) | state), data2: -1)
            ev?.cgEvent?.post(tap: .cghidEventTap)
        }
    }

    /// 当前持有「防止空闲休眠」断言的进程（播放音乐的应用会申请）
    private static func sleepAssertionPids() -> Set<Int> {
        var out = Set<Int>()
        var ref: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&ref) == kIOReturnSuccess, let dict = ref?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return out }
        for (pid, list) in dict {
            if list.contains(where: { ($0["AssertType"] as? String) == "PreventUserIdleSystemSleep" }) { out.insert(pid.intValue) }
        }
        return out
    }

    func open(_ a: MusicApp) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: a.bundleId) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    func openAccessibilitySettings() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(u) }
    }

    /// 休息结束时调用：正在播就暂停一下（只在播放中才发「播放/暂停」，免得反而把它播起来）
    func pauseIfPlaying() {
        guard let t = track, t.playing else { return }
        toggle(t.app)
        // 先把界面状态标成暂停，随后一次轮询会校正
        track = MusicTrack(app: t.app, title: t.title, artist: t.artist, playing: false, album: t.album,
                           duration: t.duration, elapsed: t.position(at: Date()), timestamp: Date().timeIntervalSince1970, rate: 0)
    }

    func openAutomationSettings() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") { NSWorkspace.shared.open(u) }
    }

    private func send(_ a: MusicApp, _ cmd: String) {
        guard let s = a.script, running(a) else { return }
        Task { [weak self] in
            _ = await Self.osa("tell application \"\(s)\" to \(cmd)")
            // 播放状态要一会儿才更新
            try? await Task.sleep(nanoseconds: 400_000_000)
            self?.refresh()
        }
    }

    // MARK: 系统媒体命令

    /// 媒体键编号 → MediaRemote 命令编号（播放暂停 2、下一首 4、上一首 5）
    private static let commandCodes: [Int32: Int] = [16: 2, 17: 4, 18: 5]

    private static let commandJxa = #"""
    function run(argv) {
      const MR = $.NSBundle.bundleWithPath("/System/Library/PrivateFrameworks/MediaRemote.framework/"); MR.load;
      ObjC.bindFunction("MRMediaRemoteSendCommand", ["bool", ["int", "id"]]);
      const r = $.MRMediaRemoteSendCommand(parseInt(argv[0]), $());
      return String(r);
    }
    """#

    private static func runSystemCommand(_ args: [String]) {
        DispatchQueue.global(qos: .userInitiated).async {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            proc.arguments = ["-l", "JavaScript", "-e", commandJxa] + args
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
            try? proc.run()
            let dog = DispatchWorkItem { proc.terminate() }
            DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: dog)
            proc.waitUntilExit()
            dog.cancel()
        }
    }

    // MARK: 封面和歌词（网易云网页接口，无需登录）

    private func loadExtras(for t: MusicTrack?) {
        guard let t else {
            if !extrasKey.isEmpty { extrasKey = ""; cover = nil; lyrics = [] }
            return
        }
        let k = t.key
        guard k != extrasKey else { return }
        extrasKey = k
        if let hit = extrasCache[k] { cover = hit.0; lyrics = hit.1; return }
        cover = nil
        lyrics = []
        let title = t.title, artist = t.artist
        Task { [weak self] in
            let r = await NeteaseLookup.fetch(title: title, artist: artist)
            guard let self else { return }
            if r.0 == nil {
                // 没取到封面（网络抖动 / 暂时匹配不到）：不缓存，几秒后下一轮轮询再试
                if self.extrasKey == k { self.lyrics = r.1 }
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                if self.extrasKey == k { self.extrasKey = "" }
                return
            }
            self.extrasCache[k] = r
            if self.extrasKey == k { self.cover = r.0; self.lyrics = r.1 }
        }
    }

    /// 此刻该唱到哪一句
    func lyric(at pos: Double) -> String? {
        guard !lyrics.isEmpty else { return nil }
        var cur: String?
        for l in lyrics {
            if l.t <= pos + 0.3 { if !l.text.isEmpty { cur = l.text } } else { break }
        }
        return cur
    }

    private enum Reply { case track(MusicTrack), idle, denied, failed }

    nonisolated private static func queryApp(_ a: MusicApp) async -> Reply {
        guard let s = a.script else { return .failed }
        let src = """
        tell application "\(s)"
            set st to (player state as text)
            if st is "stopped" then return "stopped||"
            return st & "|" & (name of current track) & "|" & (artist of current track)
        end tell
        """
        let r = await osa(src)
        guard r.code == 0 else { return r.code == -1743 ? .denied : .failed }
        let p = r.out.components(separatedBy: "|")
        guard p.count >= 3, p[0] != "stopped" else { return .idle }
        return .track(MusicTrack(app: a, title: p[1], artist: p[2], playing: p[0] == "playing"))
    }

    /// 在后台用 /usr/bin/osascript 跑一段 AppleScript。返回 (输出, 错误码；0 = 成功)。超时 8 秒杀掉
    nonisolated private static func osa(_ source: String) async -> (out: String, code: Int) {
        await withCheckedContinuation { (cont: CheckedContinuation<(out: String, code: Int), Never>) in
            DispatchQueue.global(qos: .utility).async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                proc.arguments = ["-e", source]
                let out = Pipe(), err = Pipe()
                proc.standardOutput = out
                proc.standardError = err
                do { try proc.run() } catch { cont.resume(returning: ("", -1)); return }
                let dog = DispatchWorkItem { proc.terminate() }
                DispatchQueue.global().asyncAfter(deadline: .now() + 8, execute: dog)
                let data = out.fileHandleForReading.readDataToEndOfFile()
                let errData = err.fileHandleForReading.readDataToEndOfFile()
                proc.waitUntilExit()
                dog.cancel()
                if proc.terminationStatus == 0 {
                    cont.resume(returning: ((String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines), 0))
                } else {
                    let text = String(data: errData, encoding: .utf8) ?? ""
                    var code = -2
                    if let r = text.range(of: #"\((-?\d+)\)\s*$"#, options: .regularExpression) {
                        code = Int(text[r].trimmingCharacters(in: CharacterSet(charactersIn: "() \n"))) ?? -2
                    }
                    cont.resume(returning: ("", code))
                }
            }
        }
    }
}

// MARK: - 休息会话：休息页、灵动岛、菜单栏共用的状态

/// 休息时「当前推荐的动作 / 跟练倒计时 / 在听的歌 / 环境音」放在这里，计时条（今天页、菜单栏、灵动岛）就能同步显示。
@MainActor
final class BreakSession: ObservableObject {
    static let shared = BreakSession()

    /// 「换一个」换了几次（动作 = 起点 + offset）
    @Published var offset = 0
    /// 跟练的结束时间；nil = 没在跟练
    @Published var practiceEnd: Date?
    let music = MusicRemote()

    private var bag = Set<AnyCancellable>()
    private var attached = false
    private var loop: Task<Void, Never>?

    /// 当前休息推荐的动作（短休息只在轻量动作里选）
    func move(for focus: FocusStore) -> BreakMove {
        let p = BreakMoves.pool(long: focus.shownKind == .longBreak)
        let i = ((BreakMoves.startIndex(cycle: focus.cycle) + offset) % p.count + p.count) % p.count
        return p[i]
    }

    /// 开始监听专注状态：进入休息时开始轮询播放器，休息结束时清掉跟练和环境音
    func attach(_ focus: FocusStore) {
        guard !attached else { return }
        attached = true
        AmbientSound.shared.attach(focus)
        focus.$run.combineLatest(focus.$pendingBreak)
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak focus] _, _ in
                // 不用事件带来的值，而是到这里再读一次最终状态：开始休息时 pendingBreak 先变 nil、run 随后才有值，
                // 中间那一瞬会被当成「休息结束」，把刚点下的跟练倒计时清掉（要点第二次才开始）
                guard let focus else { return }
                let resting = focus.run.map { $0.kind.isBreak } ?? (focus.pendingBreak != nil)
                self?.setResting(resting)
            }
            .store(in: &bag)
    }

    private func setResting(_ on: Bool) {
        if on {
            guard loop == nil else { return }
            loop = Task { [weak self] in
                while !Task.isCancelled {
                    self?.music.refresh()
                    // 每一轮都要起 osascript 子进程（加载 MediaRemote，很吃 CPU）：
                    // 应用在前台、或正有歌在放时 6 秒一轮（进度条本身按采样时间推算，不依赖轮询）；在后台又没放歌时放慢到 20 秒
                    let lively = NSApp.isActive || self?.music.track?.playing == true
                    try? await Task.sleep(nanoseconds: lively ? 6_000_000_000 : 20_000_000_000)
                }
            }
        } else {
            // 休息结束（跑完、跳过或取消）：正在放的音乐暂停，环境音由 AmbientSound 自己停
            if loop != nil { music.pauseIfPlaying() }
            loop?.cancel()
            loop = nil
            offset = 0
            practiceEnd = nil
        }
    }
}

// MARK: - 网易云公开网页接口：按歌名 + 歌手找到歌曲，取封面和带时间轴的歌词

enum NeteaseLookup {
    private static func get(_ url: String) async -> [String: Any]? {
        guard let u = URL(string: url) else { return nil }
        var req = URLRequest(url: u, timeoutInterval: 8)
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)", forHTTPHeaderField: "User-Agent")
        req.setValue("https://music.163.com", forHTTPHeaderField: "Referer")
        guard let (data, _) = try? await URLSession.shared.data(for: req) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func fetch(title: String, artist: String) async -> (NSImage?, [LyricLine]) {
        let q = "\(title) \(artist)".trimmingCharacters(in: .whitespaces)
        guard let enc = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let search = await get("https://music.163.com/api/search/get/web?csrf_token=&s=\(enc)&type=1&offset=0&total=true&limit=5"),
              let songs = (search["result"] as? [String: Any])?["songs"] as? [[String: Any]], !songs.isEmpty else { return (nil, []) }
        // 歌名一致、歌手有重合的优先，否则取第一个
        let norm: (String) -> String = { $0.lowercased().filter { !$0.isWhitespace } }
        let pick = songs.first { s in
            let names = (s["artists"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
            return norm((s["name"] as? String) ?? "") == norm(title) && (artist.isEmpty || names.contains { norm(artist).contains(norm($0)) || norm($0).contains(norm(artist)) })
        } ?? songs.first { norm(($0["name"] as? String) ?? "") == norm(title) } ?? songs[0]
        guard let id = (pick["id"] as? NSNumber)?.intValue else { return (nil, []) }

        let detailTask = Task { await get("https://music.163.com/api/song/detail/?id=\(id)&ids=%5B\(id)%5D") }
        let lyricTask = Task { await get("https://music.163.com/api/song/lyric?id=\(id)&lv=1&kv=1&tv=-1") }
        var image: NSImage?
        if let d = await detailTask.value, let first = (d["songs"] as? [[String: Any]])?.first,
           let pic = (first["album"] as? [String: Any])?["picUrl"] as? String, let u = URL(string: pic + "?param=480y480"),
           let (data, _) = try? await URLSession.shared.data(from: u) {
            image = NSImage(data: data)
        }
        let lrc = ((await lyricTask.value)?["lrc"] as? [String: Any])?["lyric"] as? String ?? ""
        return (image, parse(lrc))
    }

    /// `[mm:ss.xx]歌词`（一行可以有多个时间标签）
    static func parse(_ lrc: String) -> [LyricLine] {
        var out: [LyricLine] = []
        for raw in lrc.components(separatedBy: "\n") {
            var rest = Substring(raw)
            var times: [Double] = []
            while rest.hasPrefix("["), let end = rest.firstIndex(of: "]") {
                let tag = rest[rest.index(after: rest.startIndex) ..< end].split(separator: ":")
                if tag.count == 2, let m = Double(tag[0]), let sec = Double(tag[1]) { times.append(m * 60 + sec) }
                rest = rest[rest.index(after: end)...]
            }
            let text = rest.trimmingCharacters(in: .whitespaces)
            for t in times { out.append(LyricLine(t: t, text: text)) }
        }
        return out.sorted { $0.t < $1.t }
    }
}
