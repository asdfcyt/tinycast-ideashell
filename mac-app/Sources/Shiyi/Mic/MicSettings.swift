import Foundation
import Combine

enum MicButtonAction: String, Codable, CaseIterable, Identifiable {
    case voiceToggle, send, redo, clear, refine, quickAdd, customKey, none
    var id: String { rawValue }
    var title: String {
        switch self {
        case .voiceToggle: return "开始 / 停止语音输入"
        case .send: return "发送 / 确认保存(必要时先停止录音)"
        case .redo: return "删除并重说"
        case .clear: return "取消 / 清除文字"
        case .refine: return "智能单击(录音取消 · 预览修改 · 待机开万能输入)"
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
        case .quickAdd: return "万能输入"
        case .customKey: return "自定义组合键"
        case .none: return "仅硬件功能"
        }
    }
    var symbol: String {
        switch self {
        case .voiceToggle: return "mic.fill"
        case .send: return "paperplane.fill"
        case .redo: return "arrow.counterclockwise"
        case .clear: return "trash"
        case .refine: return "text.bubble"
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

struct MicConfig: Codable, Equatable {
    // 按键映射
    // 语音后端
    var backend: MicBackend = .shiyi
    var singleAction: MicButtonAction = .refine
    var doubleAction: MicButtonAction = .voiceToggle
    var tripleAction: MicButtonAction = .send
    var singleCustomKey = ""
    var doubleCustomKey = ""
    var tripleCustomKey = ""
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

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = MicConfig()
        backend = (try? c.decode(MicBackend.self, forKey: .backend)) ?? d.backend
        singleAction = (try? c.decode(MicButtonAction.self, forKey: .singleAction)) ?? d.singleAction
        doubleAction = (try? c.decode(MicButtonAction.self, forKey: .doubleAction)) ?? d.doubleAction
        tripleAction = (try? c.decode(MicButtonAction.self, forKey: .tripleAction)) ?? d.tripleAction
        tripleCustomKey = (try? c.decode(String.self, forKey: .tripleCustomKey)) ?? d.tripleCustomKey
        singleCustomKey = (try? c.decode(String.self, forKey: .singleCustomKey)) ?? d.singleCustomKey
        doubleCustomKey = (try? c.decode(String.self, forKey: .doubleCustomKey)) ?? d.doubleCustomKey
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
            if c.singleAction == .redo || c.singleAction == .none { c.singleAction = .refine }
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
