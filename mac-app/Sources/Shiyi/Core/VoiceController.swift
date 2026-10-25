import AppKit
import ApplicationServices
import CoreAudio
import Foundation

// MARK: - 设置项

/// 语音输入的偏好（UserDefaults）
enum VoiceSettings {
    static let modeKey = "voice.mode"
    static let engineKey = "voice.engine"
    static let polishKey = "voice.polish"
    static let directKey = "voice.direct"
    static let countdownKey = "voice.countdown"
    static let pasteKey = "voice.paste"
    static let autoStopKey = "voice.autostop"
    static let soundKey = "voice.sound"
    static let duckKey = "voice.duck"

    static var mode: VoiceMode { VoiceMode(rawValue: UserDefaults.standard.string(forKey: modeKey) ?? "") ?? .toggle }
    static var engine: VoiceEngine { VoiceEngine(rawValue: UserDefaults.standard.string(forKey: engineKey) ?? "") ?? .apple }
    static var polish: Bool { UserDefaults.standard.object(forKey: polishKey) as? Bool ?? true }
    /// 说完直接入库（不预览）
    static var direct: Bool { UserDefaults.standard.object(forKey: directKey) as? Bool ?? false }
    /// 预览后倒计时自动入库
    static var countdown: Bool { UserDefaults.standard.object(forKey: countdownKey) as? Bool ?? true }
    /// 保存后同时把文字输入到光标处
    static var paste: Bool { UserDefaults.standard.object(forKey: pasteKey) as? Bool ?? false }
    /// 「按一下开始」模式下，说完停顿一会儿自动结束
    static var autoStop: Bool { UserDefaults.standard.object(forKey: autoStopKey) as? Bool ?? true }
    /// 开始 / 结束时的提示音
    static var sound: Bool { UserDefaults.standard.object(forKey: soundKey) as? Bool ?? true }
    /// 录音时把系统音量压低，免得把正在播的声音录进去
    static var duck: Bool { UserDefaults.standard.object(forKey: duckKey) as? Bool ?? true }
    static let silenceSeconds = 2.5
}

enum VoiceMode: String, CaseIterable, Identifiable {
    case toggle, hold
    var id: String { rawValue }
    var label: String { self == .toggle ? "按一下开始，再按一下结束" : "按住说话，松手结束" }
}

enum VoiceEngine: String, CaseIterable, Identifiable {
    case apple, tencent
    var id: String { rawValue }
    var label: String { self == .apple ? "系统离线识别（实时出字，不上传音频）" : "腾讯云一句话识别（松手后出字）" }
    var short: String { self == .apple ? "系统" : "腾讯云" }
}

/// 语音输入的全局快捷键：几个预设 + 自定义录制。默认 ⌃⌥ V。
enum VoiceHotkey: String, CaseIterable, Identifiable {
    case off, ctrlOptV, optCmdV, ctrlOptM, holdOption, holdRightOption, holdRightCommand, holdFn, custom

    static let key = "voice.hotkey"
    static let customCodeKey = "voice.hotkey.code"
    static let customModsKey = "voice.hotkey.mods"
    static let customNameKey = "voice.hotkey.name"

    var id: String { rawValue }

    static var current: VoiceHotkey { VoiceHotkey(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .ctrlOptV }

    var label: String {
        switch self {
        case .off: return "关闭"
        case .ctrlOptV: return "⌃⌥ V"
        case .optCmdV: return "⌥⌘ V"
        case .ctrlOptM: return "⌃⌥ M"
        case .holdOption: return "只按住 ⌥ Option"
        case .holdRightOption: return "只按住右 ⌥ Option"
        case .holdRightCommand: return "只按住右 ⌘ Command"
        case .holdFn: return "只按住 fn"
        case .custom: return "自定义…"
        }
    }

    /// 单个修饰键的「按住说话」：按住不到 0.25 秒不触发，松开结束
    var modifierKey: ModifierHotkey.Key? {
        switch self {
        case .holdOption: return ModifierHotkey.option
        case .holdRightOption: return ModifierHotkey.rightOption
        case .holdRightCommand: return ModifierHotkey.rightCommand
        case .holdFn: return ModifierHotkey.fn
        default: return nil
        }
    }

    var combo: HotkeyCombo? {
        let co = HotkeyCombo.Mod.control | HotkeyCombo.Mod.option
        switch self {
        case .off: return nil
        case .ctrlOptV: return HotkeyCombo(code: 9, mods: co, name: "V")
        case .optCmdV: return HotkeyCombo(code: 9, mods: HotkeyCombo.Mod.option | HotkeyCombo.Mod.cmd, name: "V")
        case .ctrlOptM: return HotkeyCombo(code: 46, mods: co, name: "M")
        case .custom: return Self.savedCustom
        default: return nil
        }
    }

    static var savedCustom: HotkeyCombo? {
        let d = UserDefaults.standard
        guard d.object(forKey: customCodeKey) != nil else { return nil }
        return HotkeyCombo(
            code: UInt32(max(d.integer(forKey: customCodeKey), 0)),
            mods: UInt32(max(d.integer(forKey: customModsKey), 0)),
            name: d.string(forKey: customNameKey) ?? "?"
        )
    }

    static func saveCustom(_ c: HotkeyCombo) {
        let d = UserDefaults.standard
        d.set(Int(c.code), forKey: customCodeKey)
        d.set(Int(c.mods), forKey: customModsKey)
        d.set(c.name, forKey: customNameKey)
    }
}

// MARK: - 草稿

/// 预览卡片里的一条：要新建的待办 / 日记 / 笔记，或对已有待办 / 笔记的操作
struct VoiceDraft: Identifiable {
    enum Action { case create, append, edit, complete, delete }
    var id = UUID()
    var action: Action = .create
    var kind: CaptureKind = .daily
    var content: String
    /// 整理出来的原文，用来和手改后的比（纠错学习）
    var original = ""
    var date: String?
    var time: String?
    var priority = 0
    var tags: [String] = []
    var repeatText: String?
    /// 改 / 完成 / 删除 的目标待办
    var task: DidaTask?
    /// 找不到目标等：不会保存
    var problem: String?
    var keep = true

    var isDestructive: Bool { action == .delete }
}

/// 只展示不保存的结果：查询待办的列表、问 AI 的回答
struct VoiceInfo: Identifiable {
    var id = UUID()
    var title: String
    var lines: [String]
    var answer: String?
    /// 问 AI 时的问题（存成笔记时用）
    var question: String?
}

enum VoicePhase: Equatable { case idle, listening, organizing, preview, info, failed }

// MARK: - 控制器

/// 语音输入：热键 → 录音 → 识别 → AI 整理 → 预览（倒计时）→ 入库。任何一步失败都回退到「原始转写 + 本地规则」。
@MainActor
final class VoiceController: ObservableObject {
    static let shared = VoiceController()

    @Published private(set) var phase: VoicePhase = .idle
    @Published private(set) var liveText = ""
    @Published private(set) var levels: [Float] = Array(repeating: 0, count: 30)
    @Published private(set) var rawText = ""
    @Published var drafts: [VoiceDraft] = []
    @Published private(set) var infos: [VoiceInfo] = []
    @Published private(set) var notice: String?
    @Published private(set) var errorText: String?
    @Published private(set) var errorAction: (label: String, run: () -> Void)?
    /// 预览倒计时剩余秒数；nil = 没有倒计时（暂停或不自动）
    @Published private(set) var countdown: Double?
    /// 鼠标在预览卡片上：倒计时暂停
    @Published private(set) var hovering = false
    @Published private(set) var engineLabel = ""
    @Published private(set) var registerError: String?
    /// 正在用语音下「修改指令」（预览里的记录先保存着，说完按指令改）
    @Published private(set) var refining = false
    private var savedDrafts: [VoiceDraft] = []
    private var savedInfos: [VoiceInfo] = []
    private var savedRaw = ""
    private var savedNotice: String?

    private weak var model: AppModel?
    private let recorder = VoiceRecorder()
    private var observer: NSObjectProtocol?
    private var applied: HotkeyCombo?
    private var suspended = false
    private let modifier = ModifierHotkey()
    private var requestedPermissionFor: ModifierHotkey.Key?
    private var modifierHolding = false
    private var heardSpeech = false
    private var lastVoice = Date()

    private var session = UUID()
    private var starting = false
    private var pendingStop = false
    private var holdStart: Date?
    private var tick: Timer?
    private var historyId: UUID?
    static let countdownSeconds = 5.0

    // MARK: 启动 / 热键

    func start(model: AppModel) {
        guard observer == nil else { return }
        self.model = model
        GlobalHotkey.voice.onPress = { [weak self] in self?.hotkeyDown() }
        GlobalHotkey.voice.onRelease = { [weak self] in self?.hotkeyUp() }
        modifier.onHold = { [weak self] in self?.modifierDown() }
        modifier.onRelease = { [weak self] in self?.modifierUp() }
        observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.applyHotkey() }
        }
        recorder.onPartial = { [weak self] t in self?.liveText = t }
        recorder.onLevel = { [weak self] v in
            guard let self else { return }
            self.levels.removeFirst()
            self.levels.append(v)
            self.checkSilence(v)
        }
        recorder.onLimit = { [weak self] in self?.finish() }
        ModernSpeech.warmUp()
        applyHotkey()
    }

    private func applyHotkey() {
        guard !suspended else { return }
        // 单个修饰键「按住说话」：走事件监听，不用 Carbon 热键
        if let mk = VoiceHotkey.current.modifierKey {
            if applied != nil { GlobalHotkey.voice.unregister(); applied = nil }
            modifier.start(mk)
            let err: String? = ModifierHotkey.permitted ? nil : "只按修饰键需要「输入监控」权限：到「系统设置 → 隐私与安全性 → 输入监控」里允许拾忆，授权后可能要重启拾忆"
            if registerError != err { registerError = err }
            // 只在换成这个键的那一次弹系统授权框：这里每次 UserDefaults 变化（包括关窗口存位置）都会进来，不能每次都弹
            if err != nil, requestedPermissionFor != mk {
                requestedPermissionFor = mk
                ModifierHotkey.requestPermission()
            }
            return
        }
        modifier.stop()
        let want = VoiceHotkey.current.combo
        if want == applied { return }
        applied = want
        guard let c = want else {
            GlobalHotkey.voice.unregister()
            registerError = nil
            return
        }
        if let why = c.problem {
            GlobalHotkey.voice.unregister()
            registerError = why
            return
        }
        if let q = QuickAddHotkey.current.combo, q.code == c.code, q.mods == c.mods {
            GlobalHotkey.voice.unregister()
            registerError = "和全局万能输入的快捷键相同，请换一个"
            return
        }
        let ok = GlobalHotkey.voice.register(keyCode: c.code, modifiers: c.mods)
        registerError = ok ? nil : "这个组合已被系统或其他 App 占用，换一个试试"
    }

    /// 设置页录制新组合时先停掉热键，免得按下同一个组合反而开始录音
    func suspendHotkey() {
        suspended = true
        applied = nil
        modifier.stop()
        GlobalHotkey.voice.unregister()
    }

    func resumeHotkey() {
        suspended = false
        applyHotkey()
    }

    private func hotkeyDown() {
        switch phase {
        case .idle:
            holdStart = VoiceSettings.mode == .hold ? Date() : nil
            begin()
        case .listening:
            holdStart = nil
            finish()
        case .preview: confirm()
        case .info, .failed: dismiss()
        case .organizing: break
        }
    }

    /// 只按修饰键：按住超过 0.25 秒开始录音（没在待机就忽略），松开结束
    /// 说过话之后连续静音一小段时间，就当说完了（只在「按一下开始」模式；按住说话由松手结束）
    private func checkSilence(_ v: Float) {
        guard phase == .listening, !starting else { return }
        if v > 0.12 {
            heardSpeech = true
            lastVoice = Date()
            return
        }
        guard heardSpeech, VoiceSettings.autoStop, VoiceSettings.mode == .toggle, !modifierHolding, holdStart == nil else { return }
        if Date().timeIntervalSince(lastVoice) > VoiceSettings.silenceSeconds { finish() }
    }

    private func modifierDown() {
        guard phase == .idle || phase == .preview else { return }
        modifierHolding = true
        holdStart = nil
        begin(refine: phase == .preview)
    }

    private func modifierUp() {
        guard modifierHolding else { return }
        modifierHolding = false
        if starting { pendingStop = true } else if phase == .listening { finish() }
    }

    private func hotkeyUp() {
        guard VoiceSettings.mode == .hold, let t = holdStart else { return }
        holdStart = nil
        // 很短的一下按键当成「点按」：继续录，等下一次按键结束；按住超过 0.4 秒才是「松手结束」
        if Date().timeIntervalSince(t) > 0.4 {
            if starting { pendingStop = true } else if phase == .listening { finish() }
        }
    }

    /// 面板上的回车
    func returnPressed() {
        switch phase {
        case .listening: finish()
        case .preview: confirm()
        case .info, .failed: dismiss()
        default: break
        }
    }

    // MARK: 录音

    /// 预览里按空格 / 点「说话修改」：再说一句话，按这句指令改现有的记录
    func refineByVoice() {
        guard phase == .preview else { return }
        begin(refine: true)
    }

    private func begin(refine: Bool = false) {
        guard let model, refine ? phase == .preview : phase == .idle else { return }
        let id = UUID()
        session = id
        if refine {
            stopTimer()
            savedDrafts = drafts
            savedInfos = infos
            savedRaw = rawText
            savedNotice = notice
            refining = true
            liveText = ""
            levels = Array(repeating: 0, count: levels.count)
        } else {
            resetState()
            refining = false
        }
        heardSpeech = false
        lastVoice = Date()
        let engine = VoiceSettings.engine
        engineLabel = engine == .apple ? (ModernSpeech.ready ? "系统·新版" : "系统·旧版") : engine.short
        phase = .listening
        starting = true
        pendingStop = false
        Task {
            guard await VoicePermission.ensureMic() else {
                guard session == id else { return }
                starting = false
                fail("需要麦克风权限：请到「系统设置 → 隐私与安全性 → 麦克风」里允许拾忆", action: ("打开设置", { VoicePermission.openPrivacySettings("Microphone") }))
                return
            }
            if engine == .apple, !(await VoicePermission.ensureSpeech()) {
                guard session == id else { return }
                starting = false
                fail("需要语音识别权限：请到「系统设置 → 隐私与安全性 → 语音识别」里允许拾忆，或在设置里改用腾讯云识别", action: ("打开设置", { VoicePermission.openPrivacySettings("SpeechRecognition") }))
                return
            }
            guard session == id else { return }
            if engine == .tencent, !TencentAsr(secretId: model.credentials.tencentId, secretKey: model.credentials.tencentKey).configured {
                starting = false
                fail("还没有填写腾讯云密钥：到「设置 → 语音输入」里填写，或改用系统识别")
                return
            }
            do {
                try recorder.start(liveText: engine == .apple, hotwords: VoiceLexicon.shared.hotwords())
                starting = false
                if VoiceSettings.sound { NSSound(named: "Tink")?.play() }
                VoiceDucker.begin()
                if pendingStop { pendingStop = false; finish() }
            } catch {
                starting = false
                fail(error.localizedDescription)
            }
        }
    }

    func finish() {
        guard phase == .listening, !starting else {
            if starting { pendingStop = true }
            return
        }
        phase = .organizing
        let id = session
        if VoiceSettings.sound { NSSound(named: "Pop")?.play() }
        VoiceDucker.end()
        Task {
            let out = await recorder.stop()
            guard session == id else { return }
            await process(out, id: id)
        }
    }

    /// 用留下的录音重新识别 + 整理
    private func retry(_ out: VoiceRecorder.Output, id: UUID) {
        guard phase == .failed, session == id else { return }
        errorText = nil
        errorAction = nil
        phase = .organizing
        Task { await process(out, id: id) }
    }

    /// 取消 / 关闭，不保存任何东西
    func cancel() {
        guard phase != .idle else { return }
        // 说修改指令时按 Esc：回到原来的预览，不是整个关掉
        if refining, phase == .listening || phase == .organizing {
            recorder.cancel()
            VoiceDucker.end()
            session = UUID()
            starting = false
            restorePreview(nil)
            return
        }
        if let h = historyId { VoiceHistory.shared.update(h) { if $0.status == "待确认" { $0.status = "已取消" } } }
        recorder.cancel()
        VoiceDucker.end()
        session = UUID()
        starting = false
        stopTimer()
        phase = .idle
        resetState()
    }

    func dismiss() { cancel() }

    private func resetState() {
        liveText = ""
        rawText = ""
        drafts = []
        infos = []
        notice = nil
        errorText = nil
        errorAction = nil
        countdown = nil
        historyId = nil
        levels = Array(repeating: 0, count: levels.count)
    }

    /// 修改指令没成功（没听清 / AI 没理解 / 出错）：回到原来的预览，附一句提示
    private func restorePreview(_ note: String?) {
        refining = false
        liveText = ""
        levels = Array(repeating: 0, count: levels.count)
        drafts = savedDrafts
        infos = savedInfos
        rawText = savedRaw
        notice = note ?? savedNotice
        phase = .preview
    }

    private func fail(_ text: String, action: (label: String, run: () -> Void)? = nil) {
        recorder.cancel()
        VoiceDucker.end()
        stopTimer()
        if refining {
            restorePreview(text)
            return
        }
        errorText = text
        errorAction = action
        phase = .failed
    }

    // MARK: 识别 + 整理

    private func process(_ out: VoiceRecorder.Output, id: UUID) async {
        guard let model else { return }
        let engine = VoiceSettings.engine
        var raw = out.text
        if engine == .tencent {
            guard out.pcm.count > 3_200 else { fail("没听清，再说一次"); return }
            let asr = TencentAsr(secretId: model.credentials.tencentId, secretKey: model.credentials.tencentKey)
            do {
                raw = try await asr.recognize(pcm: out.pcm, hotwords: VoiceLexicon.shared.hotwords())
            } catch {
                guard session == id else { return }
                // 录音还在手上：网络 / 服务的问题可以直接重试，不用重新说
                fail(error.localizedDescription, action: ("重新识别", { [weak self] in self?.retry(out, id: id) }))
                return
            }
            guard session == id else { return }
        }
        raw = raw.trimmed
        guard !raw.isEmpty else { fail("没听清，再说一次"); return }
        if refining {
            await applyRefine(VoiceLexicon.shared.apply(raw), id: id)
            return
        }
        rawText = raw
        // 话不丢：识别原文先落到历史里，后面任何一步失败都还在
        historyId = VoiceHistory.shared.add(raw: raw, engine: engineLabel.isEmpty ? engine.short : engineLabel)

        let text = VoiceLexicon.shared.apply(raw)
        var intents: [VoiceIntent] = []
        var polished = false
        if VoiceSettings.polish, model.hasLlm {
            do {
                let reply = try await model.llm.chatJSON(
                    system: VoiceIntents.systemPrompt(vocabulary: VoiceLexicon.shared.hotwords(), todos: openTaskLines(model)),
                    user: VoiceIntents.userPrompt(text), timeout: 15
                )
                guard session == id else { return }
                intents = VoiceIntents.parse(reply)
                polished = !intents.isEmpty
                if intents.isEmpty { notice = "AI 没有整理出结果，已按原文处理" }
            } catch {
                guard session == id else { return }
                notice = "AI 整理失败（\(error.localizedDescription)），已按原文处理"
            }
        }
        if intents.isEmpty { intents = localIntents(text, model: model) }
        intents = VoiceIntents.guardAsk(text, intents)
        intents = VoiceIntents.fixRelativeTime(text, intents)
        intents = VoiceIntents.carryContinuity(text, intents)

        var newDrafts: [VoiceDraft] = []
        var newInfos: [VoiceInfo] = []
        for i in intents {
            if i.ask {
                newInfos.append(await answer(i.content, model: model))
                guard session == id else { return }
            } else if i.edit {
                if i.op == .query { newInfos.append(queryInfo(i, model: model)) } else { newDrafts.append(opDraft(i, model: model)) }
            } else if i.append {
                var d = VoiceDraft(content: i.content)
                d.action = .append
                d.kind = .note
                d.original = i.content
                newDrafts.append(d)
            } else {
                var d = VoiceDraft(content: i.content)
                d.kind = i.type
                d.original = i.content
                d.date = i.date; d.time = i.time
                d.priority = i.priority; d.tags = i.tags; d.repeatText = i.repeatText
                newDrafts.append(d)
            }
        }
        guard session == id else { return }
        drafts = newDrafts
        infos = newInfos
        let summary = newDrafts.map(\.content) + newInfos.map(\.title)
        if let h = historyId { VoiceHistory.shared.update(h) { $0.items = summary; $0.polished = polished; $0.note = self.notice } }

        if newDrafts.isEmpty {
            if newInfos.isEmpty { fail("没有可保存的内容"); return }
            phase = .info
            return
        }
        phase = .preview
        let risky = newDrafts.contains { $0.isDestructive || $0.problem != nil }
        if VoiceSettings.direct, !risky, notice == nil, newInfos.isEmpty {
            confirm()
        } else if VoiceSettings.countdown, !risky {
            startCountdown()
        }
    }

    // MARK: 语音下指令修改

    private static let refineSuffix = """

【修改模式】
下面不是新的口述，而是「当前已经整理好的记录」和用户随后用语音说的一条「修改指令」。请按指令修改这些记录，仍然只输出 {"items":[...]}，字段与上面完全一致：
- 指令可能是：换语气 / 风格（「改正式一些」「口语一点」「简短些」「详细些」）、翻译（「翻译成英文」）、改某一条的文字 / 日期 / 时间 / 优先级 / 类型（「第二条改到明天下午三点」「把开会那条改成笔记」）、删掉某条、再加一条、合并几条。
- 只改指令涉及的内容；没涉及的条目、字段原样保留（content、type、date、time、repeat、tags、priority 都照抄）。没有指明哪一条时，语气 / 风格 / 翻译类指令作用于所有条目的 content。
- 改写或翻译时，todo 的 content 仍然是简短的任务名；日期、时间字段不要因为翻译而变。
- 删除某一条就不要输出它；全部删光输出 {"items":[]}。
- 输出里只用 todo / daily / note 三种新建项，不要出现 ask、edit、append，也不要输出别的文字。
"""

    private func refineJSON(_ list: [VoiceDraft]) -> String {
        let items: [[String: Any]] = list.filter { $0.action == .create }.map { d in
            let type: String
            switch d.kind {
            case .todo: type = "todo"
            case .note: type = "note"
            default: type = "daily"
            }
            return [
                "type": type, "content": d.content,
                "date": d.date ?? NSNull(), "time": d.time ?? NSNull(),
                "repeat": d.repeatText ?? NSNull(), "tags": d.tags, "priority": d.priority,
            ]
        }
        let data = (try? JSONSerialization.data(withJSONObject: ["items": items], options: [.withoutEscapingSlashes])) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{\"items\":[]}"
    }

    private func applyRefine(_ instruction: String, id: UUID) async {
        guard let model else { return }
        guard model.hasLlm else {
            restorePreview("语音修改需要 AI：到「设置 → AI 模型」里填写后再试")
            return
        }
        let base = savedDrafts
        guard base.contains(where: { $0.action == .create }) else {
            restorePreview("这些记录是对已有待办 / 笔记的操作，不能用语音改写")
            return
        }
        do {
            let reply = try await model.llm.chatJSON(
                system: VoiceIntents.systemPrompt(vocabulary: VoiceLexicon.shared.hotwords(), todos: openTaskLines(model)) + Self.refineSuffix,
                user: "当前记录：\n" + refineJSON(base) + "\n\n修改指令：" + instruction, timeout: 20
            )
            guard session == id else { return }
            var intents = VoiceIntents.parse(reply).filter { !$0.ask && !$0.edit && !$0.append }
            intents = VoiceIntents.fixRelativeTime(instruction, intents)
            guard !intents.isEmpty else {
                restorePreview("AI 没有理解这条修改指令（「\(instruction.prefix(20))」），原内容没变")
                return
            }
            let created: [VoiceDraft] = intents.map { i in
                var d = VoiceDraft(content: i.content)
                d.kind = i.type
                d.original = i.content   // 指令改写出来的，不拿去学「同音错字」
                d.date = i.date; d.time = i.time
                d.priority = i.priority; d.tags = i.tags; d.repeatText = i.repeatText
                return d
            }
            drafts = created + base.filter { $0.action != .create }
            infos = savedInfos
            rawText = savedRaw + "\n修改指令：" + instruction
            notice = "已按「\(instruction.prefix(24))」修改，确认没问题再保存"
            refining = false
            liveText = ""
            phase = .preview
            if let h = historyId {
                let items = drafts.map(\.content)
                VoiceHistory.shared.update(h) { $0.items = items; $0.note = "语音修改：" + instruction }
            }
        } catch {
            guard session == id else { return }
            restorePreview("AI 修改失败：" + error.localizedDescription)
        }
    }

    /// 没有 AI（或 AI 失败）时的本地整理：口令 + 清洗 + 现有的万能输入解析
    private func localIntents(_ text: String, model: AppModel) -> [VoiceIntent] {
        if let rest = SpeechCleaner.stripAppendCommand(text) {
            return [VoiceIntent(type: .note, content: rest, append: true)]
        }
        let a = CaptureParser.analyze(SpeechCleaner.clean(text), sjz: model.hasSjz)
        switch a.kind {
        case .todo:
            return [VoiceIntent(type: .todo, content: a.todo.content, date: a.todo.date, time: a.todo.time, tags: a.tags)]
        case .note:
            return [VoiceIntent(type: .note, content: a.body, tags: a.tags)]
        default:
            return [VoiceIntent(type: a.kind, content: a.text)]
        }
    }

    // MARK: 对已有待办的操作 / 查询 / 问 AI

    private func openTasks(_ model: AppModel) -> [DidaTask] {
        guard let ov = model.overview else { return [] }
        return ov.overdue + ov.upcoming + ov.undated
    }

    private func openTaskLines(_ model: AppModel) -> [String] {
        openTasks(model).prefix(40).map { t in
            let when = [t.date, t.time].compactMap { $0 }.joined(separator: " ")
            return t.cleanTitle + (when.isEmpty ? "" : "｜" + when)
        }
    }

    /// 按关键词找待办；没说是哪个（「刚才那个」）就取最近创建的一条
    private func findTask(_ keyword: String?, model: AppModel) -> DidaTask? {
        let open = openTasks(model)
        let k = keyword?.trimmed ?? ""
        let pool = k.isEmpty ? open : open.filter { $0.cleanTitle.localizedCaseInsensitiveContains(k) || k.localizedCaseInsensitiveContains($0.cleanTitle) }
        return pool.max { ($0.createdAt ?? 0) < ($1.createdAt ?? 0) }
    }

    private func opDraft(_ i: VoiceIntent, model: AppModel) -> VoiceDraft {
        var d = VoiceDraft(content: i.content)
        d.kind = .todo
        d.date = i.date; d.time = i.time; d.priority = i.priority
        switch i.op {
        case .complete: d.action = .complete
        case .delete: d.action = .delete
        default: d.action = .edit
        }
        if !model.hasDida {
            d.problem = "没有连接滴答清单，没法操作已有待办"
        } else if let t = findTask(i.target, model: model) {
            d.task = t
        } else {
            d.problem = (i.target?.isEmpty == false) ? "找不到包含「\(i.target!)」的未完成待办" : "找不到刚才建的待办"
        }
        d.original = d.content
        return d
    }

    private func queryInfo(_ i: VoiceIntent, model: AppModel) -> VoiceInfo {
        let today = Day.today()
        let range = i.range ?? "today"
        var pool = openTasks(model)
        let title: String
        switch range {
        case "tomorrow":
            pool = pool.filter { $0.date == Day.add(today, days: 1) }
            title = "明天的待办"
        case "week":
            let end = Day.add(today, days: 6)
            pool = pool.filter { ($0.date ?? "") >= today && ($0.date ?? "") <= end }
            title = "未来 7 天的待办"
        case "overdue":
            pool = pool.filter { ($0.date ?? "9999") < today }
            title = "已逾期的待办"
        case "all":
            title = "全部未完成的待办"
        default:
            pool = pool.filter { ($0.date ?? "9999") <= today }
            title = "今天的待办（含已逾期）"
        }
        if let k = i.target?.trimmed, !k.isEmpty {
            pool = pool.filter { $0.cleanTitle.localizedCaseInsensitiveContains(k) }
        }
        pool.sort { (($0.date ?? "9999") + ($0.time ?? "99:99")) < (($1.date ?? "9999") + ($1.time ?? "99:99")) }
        var lines = pool.prefix(12).map { t -> String in
            let when = t.date.map { d in (d < today ? "逾期 " : "") + Day.label(d) + (t.time.map { " " + $0 } ?? "") } ?? "无日期"
            return "\(t.cleanTitle)　\(when)"
        }
        if pool.count > 12 { lines.append("…还有 \(pool.count - 12) 条") }
        if lines.isEmpty { lines = ["没有符合的待办 🎉"] }
        return VoiceInfo(title: title + "（\(pool.count)）", lines: lines)
    }

    private func answer(_ question: String, model: AppModel) async -> VoiceInfo {
        guard model.hasLlm else {
            return VoiceInfo(title: "问 AI：" + question, lines: ["还没有配置 AI 模型，到「设置 → AI 模型」里填写后就能回答"], question: question)
        }
        do {
            let reply = try await model.llm.chatJSON(
                system: "你是简洁可靠的中文助手。直接回答用户的问题，控制在 200 字以内，不确定就直说不确定。只输出 JSON 对象：{\"answer\":\"回答\"}",
                user: question, timeout: 40
            )
            let text = (LlmClient.extractJSON(reply)?["answer"] as? String)?.trimmed ?? reply
            return VoiceInfo(title: "问 AI：" + question, lines: [], answer: text, question: question)
        } catch {
            return VoiceInfo(title: "问 AI：" + question, lines: ["回答失败：" + error.localizedDescription], question: question)
        }
    }

    /// 把问 AI 的问答存成一条笔记
    func saveInfoAsNote(_ info: VoiceInfo) {
        guard let model, let q = info.question, let a = info.answer else { return }
        var analysis = CaptureAnalysis(text: q, body: q + "\n\n" + a, tags: [], folderName: nil, todo: ParsedTodo(content: q), forced: .note, recommended: .note)
        analysis.text = q + "\n\n" + a
        do {
            let msg = try CaptureOutbox.shared.submit(analysis, kind: .note, priority: 0, defaultDate: nil, defaultTime: nil, model: model)
            finishWith(msg)
        } catch {
            QuickAddPanelController.shared.showResult(error.localizedDescription, ok: false)
        }
    }

    // MARK: 预览倒计时

    private func startCountdown() {
        stopTimer()
        countdown = Self.countdownSeconds
        let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let c = self.countdown else { return }
                // 鼠标在卡片上就暂停；移开时至少再留 2 秒，让人有时间反应
                let inside = VoicePanelHost.shared.mouseInside
                if inside != self.hovering {
                    self.hovering = inside
                    if !inside, c < 2 { self.countdown = 2 }
                }
                if inside { return }
                let n = c - 0.05
                if n <= 0 {
                    self.confirm()
                } else {
                    self.countdown = n
                }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        tick = t
    }

    private func stopTimer() {
        tick?.invalidate()
        tick = nil
        countdown = nil
        hovering = false
    }

    /// 用户在卡片上有任何操作（改字、换类型、悬停）：暂停自动入库，等回车
    func userTouched() {
        if tick != nil { stopTimer() }
    }

    func removeDraft(_ id: UUID) {
        userTouched()
        drafts.removeAll { $0.id == id }
        if drafts.isEmpty {
            if infos.isEmpty { cancel() } else { phase = .info }
        }
    }

    // MARK: 保存

    func confirm() {
        guard phase == .preview, let model else { return }
        stopTimer()
        _ = CaptureOutbox.shared.takeSubmitted()   // 撤销只针对这一次保存
        var messages: [String] = []
        var failed: [String] = []
        var pasteText: [String] = []
        let lexicon = VoiceLexicon.shared
        let apply = drafts.filter { $0.keep && $0.problem == nil }
        for d in apply {
            if d.content != d.original { lexicon.learnFromEdit(original: d.original, edited: d.content) }
            switch d.action {
            case .create:
                var text = d.content.trimmed
                guard !text.isEmpty else { continue }
                var analysis = CaptureAnalysis(text: text, body: text, tags: d.tags, folderName: nil, todo: ParsedTodo(content: text, date: d.date, time: d.time), forced: d.kind, recommended: d.kind)
                switch d.kind {
                case .todo:
                    // 滴答这边没有重复规则的接口：重复说法留在标题里，不丢
                    if let r = d.repeatText, !r.isEmpty { text += "（\(r)）" }
                    analysis.todo.content = text
                    analysis.text = text; analysis.body = text
                case .daily:
                    analysis.text = d.tags.isEmpty ? text : text + " " + d.tags.map { "#" + $0 }.joined(separator: " ")
                default: break
                }
                do {
                    messages.append(try CaptureOutbox.shared.submit(analysis, kind: d.kind, priority: d.priority, defaultDate: nil, defaultTime: nil, model: model))
                    pasteText.append(d.content.trimmed)
                } catch {
                    failed.append(error.localizedDescription)
                }
            case .append:
                messages.append("已追加到上一条笔记")
                pasteText.append(d.content.trimmed)
                Task { await self.appendToLastNote(d.content.trimmed, model: model) }
            case .complete:
                guard let t = d.task else { continue }
                messages.append("已完成「\(String(t.cleanTitle.prefix(16)))」")
                Task { await model.complete(t) }
            case .delete:
                guard let t = d.task else { continue }
                messages.append("已删除「\(String(t.cleanTitle.prefix(16)))」")
                Task { await model.deleteTask(t) }
            case .edit:
                guard let t = d.task else { continue }
                messages.append("已修改「\(String(t.cleanTitle.prefix(16)))」")
                Task { await self.applyEdit(d, to: t, model: model) }
            }
        }
        if let h = historyId {
            let items = apply.map(\.content)
            VoiceHistory.shared.update(h) { $0.items = items; $0.status = failed.isEmpty ? "已保存" : "部分失败" }
        }
        let msg: String
        if messages.count == 1 { msg = messages[0] } else if messages.count > 1 { msg = "已记下 \(messages.count) 条" } else { msg = failed.first ?? "没有保存任何内容" }
        let pasted = VoiceSettings.paste && !pasteText.isEmpty ? pasteText.joined(separator: "\n") : nil
        finishWith(msg, ok: messages.count > 0, paste: pasted)
        if !failed.isEmpty, !messages.isEmpty { QuickAddPanelController.shared.showResult(failed[0], ok: false) }
    }

    private func finishWith(_ message: String, ok: Bool = true, paste: String? = nil) {
        recorder.cancel()
        session = UUID()
        phase = .idle
        resetState()
        // 面板收起后再弹结果提示；要输入到光标处时，等面板让出焦点再粘贴
        QuickAddPanelController.shared.showResult(message, ok: ok, undoIds: ok ? CaptureOutbox.shared.takeSubmitted() : [])
        if let paste { DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { VoicePaster.paste(paste) } }
    }

    private func applyEdit(_ d: VoiceDraft, to t: DidaTask, model: AppModel) async {
        if d.date != nil || d.time != nil {
            let day = d.date ?? t.date ?? Day.today()
            await model.edit(t, .schedule(date: day, time: d.time ?? (d.date == nil ? nil : t.time)))
        }
        if d.priority != 0 { await model.edit(t, .priority(d.priority)) }
        let extra = d.content.trimmed
        if !extra.isEmpty {
            let latest = model.overview.flatMap { ov in (ov.overdue + ov.upcoming + ov.undated).first { $0.id == t.id } } ?? t
            let content = latest.content.trimmed.isEmpty ? extra : latest.content + "\n" + extra
            await model.edit(latest, .details(title: latest.title, content: content, tags: latest.tags))
        }
    }

    /// 追加到最近一条笔记（不含 Daily Note）
    private func appendToLastNote(_ text: String, model: AppModel) async {
        guard model.hasIdeashell, !text.isEmpty else { return }
        let dateRE = RX("[0-9]{4}-[0-9]{2}-[0-9]{2}", multiline: false)
        guard let note = model.timeline.first(where: { !dateRE.contains(in: $0.title) && !$0.title.lowercased().contains("daily") }) else {
            model.showNotice("没找到可以追加的上一条笔记")
            return
        }
        do {
            let detail = try await model.ideashell.noteFull(note.id)
            _ = try await model.ideashell.updateNoteBody(note.id, body: detail.content + "\n\n" + text)
            model.noteCache[note.id] = nil
            model.invalidateHistory()
            await model.loadTimeline(silent: true)
        } catch {
            model.showNotice("追加失败：" + error.localizedDescription)
        }
    }
}

// MARK: - 输入到光标处

enum VoicePaster {
    /// 把文字粘贴到当前最前面的 App 的光标处（需要「辅助功能」权限）；先存下剪贴板，粘完恢复
    @MainActor
    static func paste(_ text: String) {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(opts) else {
            QuickAddPanelController.shared.showResult("要把文字输入到光标处，需要在「系统设置 → 隐私与安全性 → 辅助功能」里允许拾忆", ok: false)
            return
        }
        let pb = NSPasteboard.general
        let saved = pb.string(forType: .string)
        pb.clearContents()
        pb.setString(text, forType: .string)
        let src = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            pb.clearContents()
            if let saved { pb.setString(saved, forType: .string) }
        }
    }
}


// MARK: - 录音时压低系统音量

/// 录音开始把默认输出设备的音量压到原来的 20%，结束恢复（免得在放歌 / 视频时把声音录进去）。
/// 原音量先写进 UserDefaults：万一中途崩了，下次启动会补恢复。
@MainActor
enum VoiceDucker {
    private static let savedKey = "voice.duck.saved"
    private static let volumeSelector: AudioObjectPropertySelector = 0x766D_7663   // 'vmvc' = 虚拟主音量

    private static func device() -> AudioDeviceID? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr, id != 0 else { return nil }
        return id
    }

    private static func address() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: volumeSelector, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    }

    private static func volume(_ dev: AudioDeviceID) -> Float? {
        var addr = address()
        guard AudioObjectHasProperty(dev, &addr) else { return nil }
        var v = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &v) == noErr ? v : nil
    }

    private static func setVolume(_ dev: AudioDeviceID, _ v: Float) {
        var addr = address()
        var value = Float32(min(max(v, 0), 1))
        _ = AudioObjectSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
    }

    static func begin() {
        guard VoiceSettings.duck else { return }
        restore()   // 上次没恢复成的先恢复
        guard let dev = device(), let v = volume(dev), v > 0.05 else { return }
        UserDefaults.standard.set(Double(v), forKey: savedKey)
        setVolume(dev, v * 0.2)
    }

    static func end() { restore() }

    private static func restore() {
        guard let saved = UserDefaults.standard.object(forKey: savedKey) as? Double else { return }
        UserDefaults.standard.removeObject(forKey: savedKey)
        if let dev = device() { setVolume(dev, Float(saved)) }
    }
}
