import Foundation
import Combine

enum MicButtonAction: String, Codable, CaseIterable, Identifiable {
    case voiceToggle, send, redo, clear, refine, route, quickAdd, customKey, none
    var id: String { rawValue }
    var title: String {
        switch self {
        case .voiceToggle: return "开始 / 停止语音输入"
        case .send: return "发送 / 确认保存(必要时先停止录音)"
        case .redo: return "删除并重说"
        case .clear: return "取消 / 清除文字"
        case .refine: return "智能单击(录音取消 · 预览修改 · 待机开万能输入)"
        case .route: return "切换去向(录音中:纯语音 ↔ 万能输入框 · 预览中:说话修改)"
        case .quickAdd: return "打开 / 收起万能输入"
        case .customKey: return "自定义组合键"
        case .none: return "无动作"
        }
    }
    var shortTitle: String {
        switch self {
        case .voiceToggle: return "语音开始 / 停止"
        case .send: return "发送 / 确认保存"
        case .redo: return "删除并重说"
        case .clear: return "取消 / 清除"
        case .refine: return "智能单击"
        case .route: return "切换去向"
        case .quickAdd: return "万能输入"
        case .customKey: return "自定义组合键"
        case .none: return "仅硬件功能"
        }
    }
    /// 各后端能用的动作:外部输入法只能靠模拟按键,没有拾忆内部的「说话修改 / 万能输入」
    static func available(for backend: MicBackend) -> [MicButtonAction] {
        switch backend {
        case .shiyi: return [.route, .refine, .voiceToggle, .send, .clear, .redo, .quickAdd, .customKey, .none]
        case .external: return [.voiceToggle, .send, .redo, .clear, .customKey, .none]
        }
    }

    var symbol: String {
        switch self {
        case .voiceToggle: return "mic.fill"
        case .send: return "paperplane.fill"
        case .redo: return "arrow.counterclockwise"
        case .clear: return "trash"
        case .refine: return "text.bubble"
        case .route: return "arrow.triangle.branch"
        case .quickAdd: return "square.and.pencil"
        case .customKey: return "keyboard"
        case .none: return "nosign"
        }
    }
}

/// 麦克风按键驱动的对象:拾忆自带语音输入,或外部输入法(模拟按键)。
enum MicBackend: String, Codable, CaseIterable, Identifiable {
    case shiyi, external
    var id: String { rawValue }
    var title: String { self == .shiyi ? "拾忆语音输入" : "外部输入法(豆包等,模拟按键)" }
}

enum MicVoiceMode: String, Codable, CaseIterable, Identifiable {
    case hold, tap
    var id: String { rawValue }
    var title: String { self == .hold ? "长按模式(按住说话,松开结束)" : "免按模式(按一下开始,再按一下结束)" }
}

enum MicNoiseLock: String, Codable, CaseIterable, Identifiable {
    case off, keepInitial, forceOff, forceOn
    var id: String { rawValue }
    var title: String {
        switch self {
        case .off: return "不干预(固件原行为:单击会切换降噪)"
        case .keepInitial: return "保持连接时的降噪状态(推荐)"
        case .forceOff: return "始终关闭降噪"
        case .forceOn: return "始终开启降噪(中档)"
        }
    }
}

/// 三个手势的动作 + 各自的自定义组合键。拾忆和外部输入法各存一份,互不影响。
struct MicMapping: Codable, Equatable {
    var single: MicButtonAction
    var double: MicButtonAction
    var triple: MicButtonAction
    var singleKey = ""
    var doubleKey = ""
    var tripleKey = ""

    static let shiyiDefault = MicMapping(single: .route, double: .voiceToggle, triple: .send)
    static let externalDefault = MicMapping(single: .redo, double: .voiceToggle, triple: .send)
}

struct MicConfig: Codable, Equatable {
    // 语音后端
    var backend: MicBackend = .shiyi
    // 按键映射:每个后端一套
    var shiyiMap = MicMapping.shiyiDefault
    var externalMap = MicMapping.externalDefault
    // 豆包语音键
    var voiceKey = "fn"
    var voiceMode: MicVoiceMode = .hold
    // 发送 / 清除
    var sendKey = "enter"
    var clearKeys = "cmd+a, backspace"
    // 时序
    var clickDebounceMs = 140
    var sendDelayMs = 900
    var maxRecordSeconds = 120
    var reviewTimeoutSeconds = 90
    var pollMs = 40
    // 行为
    var noiseLock: MicNoiseLock = .keepInitial
    var unmuteDoubleSkipsAction = true
    var showHUD = true
    var syncWithMic = true
    var tapHoldMs = 80
    /// 独占打开接收器的 HID 接口：三击不会同时调高系统音量，但会占住整个接口（插在拓展坞上容易和别的设备抢）。默认共享
    var exclusiveHID = false

    /// 当前后端对应的那一套映射(下面的 singleAction 等都读写它)
    var map: MicMapping {
        get { backend == .shiyi ? shiyiMap : externalMap }
        set { if backend == .shiyi { shiyiMap = newValue } else { externalMap = newValue } }
    }
    var singleAction: MicButtonAction { get { map.single } set { map.single = newValue } }
    var doubleAction: MicButtonAction { get { map.double } set { map.double = newValue } }
    var tripleAction: MicButtonAction { get { map.triple } set { map.triple = newValue } }
    var singleCustomKey: String { get { map.singleKey } set { map.singleKey = newValue } }
    var doubleCustomKey: String { get { map.doubleKey } set { map.doubleKey = newValue } }
    var tripleCustomKey: String { get { map.tripleKey } set { map.tripleKey = newValue } }

    init() {}

    private enum CodingKeys: String, CodingKey {
        case backend, shiyiMap, externalMap
        case voiceKey, voiceMode, sendKey, clearKeys
        case clickDebounceMs, sendDelayMs, maxRecordSeconds, reviewTimeoutSeconds, pollMs
        case noiseLock, unmuteDoubleSkipsAction, showHUD, syncWithMic, tapHoldMs, exclusiveHID
        // 旧版(两个后端共用一套)的键,只在读取时用来迁移
        case singleAction, doubleAction, tripleAction, singleCustomKey, doubleCustomKey, tripleCustomKey
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = MicConfig()
        backend = (try? c.decode(MicBackend.self, forKey: .backend)) ?? d.backend
        if let sm = try? c.decode(MicMapping.self, forKey: .shiyiMap),
           let em = try? c.decode(MicMapping.self, forKey: .externalMap) {
            shiyiMap = sm
            externalMap = em
        } else {
            // 旧版迁移:原来共用的一套 → 拾忆那套沿用(智能单击升级成「切换去向」);外部那套能用就沿用,否则用默认
            var legacy = MicMapping.shiyiDefault
            if let v = try? c.decode(MicButtonAction.self, forKey: .singleAction) { legacy.single = v }
            if let v = try? c.decode(MicButtonAction.self, forKey: .doubleAction) { legacy.double = v }
            if let v = try? c.decode(MicButtonAction.self, forKey: .tripleAction) { legacy.triple = v }
            legacy.singleKey = (try? c.decode(String.self, forKey: .singleCustomKey)) ?? ""
            legacy.doubleKey = (try? c.decode(String.self, forKey: .doubleCustomKey)) ?? ""
            legacy.tripleKey = (try? c.decode(String.self, forKey: .tripleCustomKey)) ?? ""
            var ext = legacy
            let extOK = MicButtonAction.available(for: .external)
            if !extOK.contains(ext.single) { ext.single = MicMapping.externalDefault.single }
            if !extOK.contains(ext.double) { ext.double = MicMapping.externalDefault.double }
            if !extOK.contains(ext.triple) { ext.triple = MicMapping.externalDefault.triple }
            if legacy.single == .refine || legacy.single == .redo || legacy.single == .none { legacy.single = .route }
            shiyiMap = legacy
            externalMap = ext
        }
        voiceKey = (try? c.decode(String.self, forKey: .voiceKey)) ?? d.voiceKey
        voiceMode = (try? c.decode(MicVoiceMode.self, forKey: .voiceMode)) ?? d.voiceMode
        sendKey = (try? c.decode(String.self, forKey: .sendKey)) ?? d.sendKey
        clearKeys = (try? c.decode(String.self, forKey: .clearKeys)) ?? d.clearKeys
        clickDebounceMs = (try? c.decode(Int.self, forKey: .clickDebounceMs)) ?? d.clickDebounceMs
        sendDelayMs = (try? c.decode(Int.self, forKey: .sendDelayMs)) ?? d.sendDelayMs
        maxRecordSeconds = (try? c.decode(Int.self, forKey: .maxRecordSeconds)) ?? d.maxRecordSeconds
        reviewTimeoutSeconds = (try? c.decode(Int.self, forKey: .reviewTimeoutSeconds)) ?? d.reviewTimeoutSeconds
        pollMs = (try? c.decode(Int.self, forKey: .pollMs)) ?? d.pollMs
        noiseLock = (try? c.decode(MicNoiseLock.self, forKey: .noiseLock)) ?? d.noiseLock
        unmuteDoubleSkipsAction = (try? c.decode(Bool.self, forKey: .unmuteDoubleSkipsAction)) ?? d.unmuteDoubleSkipsAction
        showHUD = (try? c.decode(Bool.self, forKey: .showHUD)) ?? d.showHUD
        syncWithMic = (try? c.decode(Bool.self, forKey: .syncWithMic)) ?? d.syncWithMic
        tapHoldMs = (try? c.decode(Int.self, forKey: .tapHoldMs)) ?? d.tapHoldMs
        exclusiveHID = (try? c.decode(Bool.self, forKey: .exclusiveHID)) ?? d.exclusiveHID
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(backend, forKey: .backend)
        try c.encode(shiyiMap, forKey: .shiyiMap)
        try c.encode(externalMap, forKey: .externalMap)
        try c.encode(voiceKey, forKey: .voiceKey)
        try c.encode(voiceMode, forKey: .voiceMode)
        try c.encode(sendKey, forKey: .sendKey)
        try c.encode(clearKeys, forKey: .clearKeys)
        try c.encode(clickDebounceMs, forKey: .clickDebounceMs)
        try c.encode(sendDelayMs, forKey: .sendDelayMs)
        try c.encode(maxRecordSeconds, forKey: .maxRecordSeconds)
        try c.encode(reviewTimeoutSeconds, forKey: .reviewTimeoutSeconds)
        try c.encode(pollMs, forKey: .pollMs)
        try c.encode(noiseLock, forKey: .noiseLock)
        try c.encode(unmuteDoubleSkipsAction, forKey: .unmuteDoubleSkipsAction)
        try c.encode(showHUD, forKey: .showHUD)
        try c.encode(syncWithMic, forKey: .syncWithMic)
        try c.encode(tapHoldMs, forKey: .tapHoldMs)
        try c.encode(exclusiveHID, forKey: .exclusiveHID)
    }
}

final class MicSettingsStore: ObservableObject {
    static let shared = MicSettingsStore()

    private static let key = "mic.config.v1"
    /// 独立 App「猛犸语音按钮」的配置域(并入拾忆前使用),首次启动时一次性导入
    private static let oldDomain = "com.carpe.momamic"
    private static let oldKey = "MomaMic.config.v3"

    @Published var cfg: MicConfig {
        didSet { save() }
    }

    init() {
        let ud = UserDefaults.standard
        if let data = ud.data(forKey: Self.key), let c = try? JSONDecoder().decode(MicConfig.self, from: data) {
            cfg = c
        } else if let data = UserDefaults(suiteName: Self.oldDomain)?.data(forKey: Self.oldKey),
                  var c = try? JSONDecoder().decode(MicConfig.self, from: data) {
            // 从旧 App 导入:语音改走拾忆;单击改为「说话修改」(旧的「删除并重说」是给输入法用的)
            c.backend = .shiyi
            if c.singleAction == .redo || c.singleAction == .none { c.singleAction = .route }
            cfg = c
        } else {
            cfg = MicConfig()
        }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(cfg) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    func reset() { cfg = MicConfig() }
}
