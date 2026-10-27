import Foundation
import AppKit
import ApplicationServices
import IOKit.hid
import Combine

enum MicFlowState {
    case idle        // 待机
    case recording   // 录音中(语音键按住)
    case review      // 已停止,文字在输入框里等待确认
}

enum MicGesture: String {
    case single, double, triple
    var title: String {
        switch self {
        case .single: return "单击"
        case .double: return "双击"
        case .triple: return "三击"
        }
    }
}

struct MicGestureEvent: Equatable {
    let id = UUID()
    let kind: MicGesture
}

struct MicLogLine: Identifiable {
    let id = UUID()
    let time: Date
    let text: String
}

@MainActor
final class MicEngine: ObservableObject {
    static let shared = MicEngine(settings: .shared)
    let settings: MicSettingsStore

    // 对 UI 暴露的状态
    @Published private(set) var connected = false
    /// 已枚举到接收器(但不一定有心跳回应)
    @Published private(set) var attached = false
    @Published private(set) var heart = MicHeart()
    @Published private(set) var firmware = ""
    @Published private(set) var state: MicFlowState = .idle
    @Published private(set) var lastEvent = "—"
    @Published private(set) var accessibilityOK = false
    @Published private(set) var inputMonitoringOK = false
    @Published private(set) var lastGesture: MicGestureEvent?
    @Published private(set) var eventLog: [MicLogLine] = []
    @Published private(set) var rxID = ""
    @Published private(set) var txSerial = ""
    @Published private(set) var consumerSeized = false
    @Published private(set) var micActive = false

    private let link = MicHIDLink()
    private let injector = MicInjector()
    private let hud = MicHUD()
    private let audio = MicAudioWatcher()
    private var busy = false

    private var cfg: MicConfig { settings.cfg }
    private var pollTimer: Timer?
    private var permTimer: Timer?
    private var haveHeart = false
    private var lastReopenAt = Date.distantPast
    private var sendFailures = 0
    private var lastSendAt = Date.distantPast
    private var lastHeartAt = Date()
    private var initialNoise = 0
    private var cancellables = Set<AnyCancellable>()

    // 事件检测
    private var pendingClick: (t: Date, old: Int, new: Int)?
    private var suppressClickUntil = Date.distantPast
    private var noiseSelfUntil = Date.distantPast

    // 语音流程
    private var chain: Task<Void, Never>?
    private var recordTimer: Task<Void, Never>?
    private var reviewTimer: Task<Void, Never>?
    private var stopAt: Date?

    init(settings: MicSettingsStore) {
        self.settings = settings
    }

    // MARK: - 生命周期

    private var started = false

    func start() {
        guard !started else { return }
        started = true
        refreshPermissions()
        link.onConnect = { [weak self] in self?.deviceConnected() }
        link.onDisconnect = { [weak self] in self?.deviceDisconnected() }
        link.onPacket = { [weak self] cmd, dev, payload in self?.handlePacket(cmd, dev, payload) }
        link.onConsumerKey = { [weak self] usage, down in self?.handleConsumerKey(usage, down) }
        link.start()

        audio.onChange = { [weak self] running in
            Task { @MainActor in self?.micChanged(running) }
        }
        audio.start()
        micActive = audio.isRunning

        restartPolling()
        bindShiyiVoice()
        settings.$cfg.map(\.pollMs).removeDuplicates().sink { [weak self] _ in
            Task { @MainActor in self?.restartPolling() }
        }.store(in: &cancellables)

        permTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshPermissions() }
        }

        let nc = NotificationCenter.default
        nc.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.abortAll(quiet: true) }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.abortAll(quiet: true) }
        }
    }

    // MARK: - 拾忆语音(默认后端)

    private var voice: VoiceController { VoiceController.shared }
    private var usesShiyi: Bool { cfg.backend == .shiyi }

    /// 订阅拾忆语音阶段:按键状态与拾忆自己的状态始终一致(拾忆自行停止/失败/超时也会同步)。
    private func bindShiyiVoice() {
        voice.$phase.removeDuplicates().sink { [weak self] phase in
            guard let self, self.usesShiyi else { return }
            switch phase {
            case .listening: self.state = .recording
            case .preview: self.state = .review
            default: self.state = .idle
            }
        }.store(in: &cancellables)
        settings.$cfg.map(\.backend).removeDuplicates().sink { [weak self] _ in
            guard let self else { return }
            // 切换后端:收尾上一个后端的状态
            self.injector.releaseAll()
            self.recordTimer?.cancel()
            self.reviewTimer?.cancel()
            if self.usesShiyi {
                self.state = self.voice.phase == .listening ? .recording : (self.voice.phase == .preview ? .review : .idle)
            } else {
                self.state = .idle
            }
        }.store(in: &cancellables)
    }

    private func restartPolling() {
        pollTimer?.invalidate()
        let interval = Double(max(20, cfg.pollMs)) / 1000
        pollTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func refreshPermissions() {
        accessibilityOK = AXIsProcessTrusted()
        inputMonitoringOK = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    func requestAccessibility() {
        let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    func requestInputMonitoring() {
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        // 权限刚授予时需要重新打开 HID 管理器
        link.stop()
        link.start()
    }

    // MARK: - 设备

    private func deviceConnected() {
        micDebug("inputMonitoring=\(IOHIDCheckAccess(kIOHIDRequestTypeListenEvent).rawValue) (0=granted 1=denied 2=unknown) AX=\(AXIsProcessTrusted())")
        micDebug("attached; seized=\(link.consumerSeized) openStatus=\(String(format: "0x%x", link.openStatus))")
        // 只有收到心跳回包才算「已连接」,避免枚举到设备但它没有回应时界面反复闪烁
        attached = true
        haveHeart = false
        lastHeartAt = Date()
        consumerSeized = link.consumerSeized
        sendFailures = 0
        note("接收器已枚举")
        // 刚插入时只发心跳(由定时器发送),等收到第一个回包再查询版本/序列号,
        // 避免在设备还没就绪时连发多条命令。
    }

    /// 收到第一个心跳回包后,再查一次固件版本与序列号(发射器没开机时不去问它)。
    private func queryInfoOnce(_ h: MicHeart) {
        note("接收器已连接")
        link.send(cmd: MicProto.cmdVersion)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, self.connected else { return }
            self.link.send(cmd: MicProto.cmdSerial, dev: MicProto.devRX)
            self.consumerSeized = self.link.consumerSeized
            if h.tx1Online {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                    guard let self, self.connected else { return }
                    self.link.send(cmd: MicProto.cmdSerial, dev: MicProto.devTX1)
                }
            }
        }
    }

    private func deviceDisconnected() {
        micDebug("detached")
        attached = false
        connected = false
        haveHeart = false
        heart = MicHeart()
        note("接收器已断开")
        if usesShiyi, voice.phase == .listening { voice.finish() }
        abortAll(quiet: false)
    }

    private func tick() {
        guard link.isAttached else { return }
        // 连续写入失败(设备通道卡住)时不要每 40ms 去敲它:降到每 2 秒试一次,给它恢复的机会
        if sendFailures >= 5, Date().timeIntervalSince(lastSendAt) < 2 {
            flushPending(Date())
            return
        }
        lastSendAt = Date()
        if link.send(cmd: MicProto.cmdHeart) {
            if sendFailures > 0 { micDebug("send ok again after \(sendFailures) failures") }
            sendFailures = 0
        } else {
            sendFailures += 1
            if sendFailures == 5 { micDebug("send failing; backing off to 2s") }
        }
        flushPending(Date())
        let silent = Date().timeIntervalSince(lastHeartAt)
        if connected && silent > 3 {
            micDebug("watchdog: no heartbeat for >3s")
            connected = false
            haveHeart = false
            abortAll(quiet: false)
        }
        // 已枚举但一直没有回应:每 6 秒重新打开一次 HID 通道(处理占用被释放、通道卡住等情况)
        if !connected, silent > 3, Date().timeIntervalSince(lastReopenAt) > 6 {
            lastReopenAt = Date()
            micDebug("reopen HID (silent \(Int(silent))s)")
            link.stop()
            link.start()
        }
    }

    private func handleConsumerKey(_ usage: Int, _ down: Bool) {
        // 三击:接收器发送一次「音量+」(0x00E9)。按下沿触发即可。
        guard usage == 0xE9, down else { return }
        fire(.triple)
        lastEvent = "三击"
        onTripleClick()
    }

    private func handlePacket(_ cmd: UInt8, _ dev: UInt8, _ payload: [UInt8]) {
        switch cmd {
        case MicProto.cmdSerial:
            let text = MicProto.ascii(payload)
            if dev == 0x80 { rxID = text } else if dev == 0x81 { txSerial = text }
        case MicProto.cmdHeart:
            lastHeartAt = Date()
            if !connected { micDebug("heartbeat resumed"); connected = true }
            processHeart(MicHeart(payload: payload))
        case MicProto.cmdVersion:
            if payload.count >= 6 {
                firmware = "\(payload[0]).\(payload[1]).\(payload[2]).\(payload[3...5].map(String.init).joined())"
            }
        default:
            break
        }
    }

    // MARK: - 事件检测(单击 / 双击)

    private func processHeart(_ new: MicHeart) {
        guard haveHeart else {
            haveHeart = true
            heart = new
            initialNoise = new.noise
            queryInfoOnce(new)
            return
        }
        let old = heart
        guard new != old else { return }
        heart = new
        detect(old: old, new: new)
    }

    /// 固件行为(实测):
    ///  - 单击 Mic / 单击 RX:降噪位 p[6] 翻转(0<->2)
    ///  - 双击 Mic:对应 TX 的静音位翻转,并且**顺带**翻转一次降噪位
    /// 所以降噪位变化先挂起一个去抖窗口,窗口内若出现静音位翻转则判定为双击,不触发单击。
    private func detect(old: MicHeart, new: MicHeart) {
        let now = Date()
        let debounce = Double(cfg.clickDebounceMs) / 1000

        var double = false
        let mutedChanged1 = old.tx1Online && new.tx1Online && old.tx1Muted != new.tx1Muted
        let mutedChanged2 = old.tx2Online && new.tx2Online && old.tx2Muted != new.tx2Muted
        if mutedChanged1 || mutedChanged2 { double = true }

        if double {
            suppressClickUntil = now.addingTimeInterval(debounce)
            if pendingClick != nil {
                pendingClick = nil
                enforceNoiseLock()
            }
        }
        if new.noise != old.noise && now >= noiseSelfUntil {
            if now < suppressClickUntil || double {
                enforceNoiseLock()
            } else if pendingClick == nil {
                pendingClick = (now, old.noise, new.noise)
            } else {
                pendingClick?.new = new.noise
            }
        }

        // TX 掉线:立刻释放语音键,避免 Fn 卡住
        if (old.tx1Online && !new.tx1Online) || (old.tx2Online && !new.tx2Online) {
            if !new.anyOnline {
                if usesShiyi, voice.phase == .listening { voice.finish() }
                abortAll(quiet: false)
            }
        }

        if double {
            let nowMuted = new.anyMuted
            lastEvent = nowMuted ? "双击(已静音)" : "双击(已解除静音)"
            fire(.double)
            note(lastEvent)
            onDoubleClick(nowMuted: nowMuted)
        }
    }

    private func flushPending(_ now: Date) {
        guard let p = pendingClick else { return }
        if now.timeIntervalSince(p.t) >= Double(cfg.clickDebounceMs) / 1000 {
            pendingClick = nil
            enforceNoiseLock()
            lastEvent = "单击"
            fire(.single)
            onSingleClick()
        }
    }

    // MARK: - 降噪锁定(让单击不再改变麦克风降噪)

    private func enforceNoiseLock() {
        let target: Int
        switch cfg.noiseLock {
        case .off: return
        case .keepInitial: target = initialNoise
        case .forceOff: target = 0
        case .forceOn: target = 2
        }
        setNoise(target)
    }

    func setNoise(_ level: Int) {
        let level = max(0, min(3, level))
        let current = heart.noise
        guard level != current else { return }
        noiseSelfUntil = Date().addingTimeInterval(1.5)
        if current == 0 && level > 0 {
            link.send(cmd: MicProto.cmdNoiseSwitchSet, payload: [0x02])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                self?.link.send(cmd: MicProto.cmdNoiseLevelSet, payload: [UInt8(level)])
            }
        } else if current > 0 && level == 0 {
            link.send(cmd: MicProto.cmdNoiseSwitchSet, payload: [0x02])
        } else {
            link.send(cmd: MicProto.cmdNoiseLevelSet, payload: [UInt8(level)])
        }
    }

    // MARK: - 按键映射入口

    private func onSingleClick() {
        let action = cfg.singleAction
        let custom = cfg.singleCustomKey
        enqueue { [weak self] in await self?.perform(action, custom: custom) }
    }

    private func onTripleClick() {
        let action = cfg.tripleAction
        let custom = cfg.tripleCustomKey
        enqueue { [weak self] in await self?.perform(action, custom: custom) }
    }

    private func fire(_ g: MicGesture) {
        lastGesture = MicGestureEvent(kind: g)
        note("\(g.title)")
    }

    func note(_ text: String) {
        eventLog.append(MicLogLine(time: Date(), text: text))
        if eventLog.count > 60 { eventLog.removeFirst(eventLog.count - 60) }
    }

    /// 结束录音的手势提示(双击=静音即停止)。
    private var stopHint: String {
        if cfg.doubleAction == .voiceToggle { return "双击结束" }
        if cfg.singleAction == .voiceToggle { return "单击停止" }
        if cfg.tripleAction == .voiceToggle { return "三击停止" }
        return "菜单停止"
    }

    /// 继续说话的手势提示。
    private var resumeHint: String {
        if cfg.doubleAction == .voiceToggle { return "双击" }
        if cfg.singleAction == .voiceToggle { return "单击" }
        if cfg.tripleAction == .voiceToggle { return "三击" }
        return "菜单"
    }

    /// 当前负责「发送」的手势名称(用于提示文案)。
    private var sendHint: String {
        if cfg.tripleAction == .send { return "三击发送" }
        if cfg.doubleAction == .send { return "双击发送" }
        if cfg.singleAction == .send { return "单击发送" }
        return "菜单发送"
    }

    /// 方案 A:双击同时承担「发送」与「解除静音」。
    /// 若这次双击只是把静音解除(待机、没有待发送内容),不执行动作,避免误发送。
    private func onDoubleClick(nowMuted: Bool) {
        if usesShiyi, cfg.doubleAction == .voiceToggle {
            // 拾忆:未静音=开始说话(预览中则「说话修改」),静音=结束
            enqueue { [weak self] in
                guard let self else { return }
                if nowMuted {
                    if self.voice.phase == .listening {
                        self.voice.finish()
                    } else if self.voice.phase == .idle {
                        self.toast("已静音 · 双击解除静音并开始说话", .info, 1.6)
                    }
                } else {
                    switch self.voice.phase {
                    case .idle: self.voice.toggleFromMenu()   // 万能输入窗开着时,说的话会进输入框
                    case .preview: self.voice.refineByVoice()
                    default: break
                    }
                }
            }
            return
        }
        // 双击 = 语音开关:以硬件静音位为准。解除静音 -> 开始说话;静音 -> 停止(待机时保持静音即可)
        if cfg.doubleAction == .voiceToggle {
            enqueue { [weak self] in
                guard let self else { return }
                if nowMuted {
                    if self.state == .recording {
                        await self.stopRecording()
                    } else {
                        self.toast("已静音 · 双击解除静音并开始说话", .info, 1.6)
                    }
                } else if self.state != .recording {
                    await self.startRecording()
                }
            }
            return
        }
        if !nowMuted && state == .idle && cfg.unmuteDoubleSkipsAction {
            toast("已解除静音", .success)
            return
        }
        let action = cfg.doubleAction
        let custom = cfg.doubleCustomKey
        if action == .none {
            toast(nowMuted ? "麦克风已静音 · 再次双击解除" : "已解除静音", nowMuted ? .warning : .success, 1.8)
            return
        }
        enqueue { [weak self] in
            guard let self else { return }
            await self.perform(action, custom: custom)
            if nowMuted && action == .send {
                self.toast("已发送 · 麦克风已静音,下次请先双击解除", .warning, 2.8)
            }
        }
    }

    /// UI / 菜单手动触发(测试用)。
    func trigger(_ action: MicButtonAction) {
        enqueue { [weak self] in await self?.perform(action, custom: "") }
    }

    // MARK: - 语音流程

    private func enqueue(_ work: @escaping @MainActor () async -> Void) {
        let prev = chain
        chain = Task { @MainActor in
            await prev?.value
            await work()
        }
    }

    private func perform(_ action: MicButtonAction, custom: String) async {
        if usesShiyi, action != .customKey, action != .none {
            await performShiyi(action)
            return
        }
        switch action {
        case .none:
            break
        case .voiceToggle:
            if state == .recording { await stopRecording() } else { await startRecording() }
        case .send:
            await sendNow()
        case .redo:
            await stopIfRecording()
            await clearText()
            await startRecording()
        case .clear:
            await stopIfRecording()
            await clearText()
            state = .idle
            reviewTimer?.cancel()
            toast("已清除", .info)
        case .quickAdd:
            QuickAddPanelController.shared.toggle()
        case .refine:
            // 外部输入法没有「说话修改」:当作「停止并清除」
            await stopIfRecording()
            await clearText()
            state = .idle
            reviewTimer?.cancel()
        case .customKey:
            await pressSequence(custom)
        }
    }

    /// 拾忆语音:把按键动作翻译成 VoiceController 的操作。
    private func performShiyi(_ action: MicButtonAction) async {
        let v = voice
        switch action {
        case .none, .customKey:
            break
        case .voiceToggle:
            switch v.phase {
            case .idle: v.toggleFromMenu()
            case .listening: v.finish()
            case .preview: v.refineByVoice()
            default: break
            }
        case .send:
            switch v.phase {
            case .listening: v.finish()
            case .preview: v.confirm()
            case .info, .failed: v.dismiss()
            case .idle:
                // 万能输入窗开着:三击 = 提交输入框里的内容
                if QuickAddPanelController.shared.isVisible {
                    NotificationCenter.default.post(name: .micQuickAddSubmit, object: nil)
                }
            default: break
            }
        case .quickAdd:
            QuickAddPanelController.shared.toggle()
        case .refine:
            switch v.phase {
            case .preview: v.refineByVoice()
            case .listening, .organizing: v.cancel()
            case .info, .failed: v.dismiss()
            case .idle: QuickAddPanelController.shared.toggle()   // 待机:开 / 关万能输入
            }
        case .clear:
            if v.phase != .idle { v.cancel() }
        case .redo:
            if v.phase != .idle { v.cancel() }
            try? await Task.sleep(nanoseconds: 250_000_000)
            if v.phase == .idle { v.toggleFromMenu() }
        }
    }

    private func voiceChord() -> MicChord? { MicKeys.parse(cfg.voiceKey) }

    /// 系统麦克风使用状态变化(豆包真正开始/结束收音)。
    private func micChanged(_ running: Bool) {
        micActive = running
        note(running ? "系统开始录音" : "系统停止录音")
        guard !usesShiyi, cfg.syncWithMic, !busy else { return }
        // 豆包自己结束了录音(静音超时、手动按了键等):同步到「待确认」,并释放可能按住的语音键
        if !running && state == .recording {
            recordTimer?.cancel()
            injector.up(id: "voice")
            enterReview()
            toast("豆包已停止录音 · \(sendHint) / \(resumeHint)继续说", .info, 2.5)
        }
    }

    private func enterReview() {
        state = .review
        stopAt = Date()
        let t = max(10, cfg.reviewTimeoutSeconds)
        reviewTimer?.cancel()
        reviewTimer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(t) * 1_000_000_000)
            if !Task.isCancelled, let self, self.state == .review { self.state = .idle }
        }
    }

    /// 等待系统麦克风使用状态变为 target;超时返回 false。
    private func waitMic(_ target: Bool, timeout: Double) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if micActive == target { return true }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        return micActive == target
    }

    private func startRecording() async {
        guard state != .recording else { return }
        guard accessibilityOK else {
            toast("缺少「辅助功能」权限,请在设置里授权", .warning, 3)
            return
        }
        if heart.anyMuted {
            toast("麦克风已静音 · 请先双击解除静音(解除后会自动开始)", .warning, 2.8)
            return
        }
        guard let chord = voiceChord() else {
            toast("语音键设置无效:\(cfg.voiceKey)", .warning, 3)
            return
        }
        reviewTimer?.cancel()
        busy = true
        defer { busy = false }

        switch cfg.voiceMode {
        case .hold: injector.down(chord, id: "voice")
        case .tap: await injector.tap(chord, holdMs: max(30, cfg.tapHoldMs))
        }

        if cfg.syncWithMic {
            // 豆包从按键到真正开始收音大约有 0.2 秒延迟:等到系统确认在录音再提示「现在可以说话」
            toast("准备中…", .info, nil)
            let ok = await waitMic(true, timeout: 1.8)
            if !ok {
                injector.up(id: "voice")
                state = .idle
                toast("豆包没有开始录音 · 请检查语音键与触发方式(或在设置里关闭「同步系统录音状态」)", .warning, 4)
                return
            }
        }
        state = .recording
        toast("录音中 · 现在可以说话 · \(stopHint) · \(sendHint)", .recording, nil)
        let limit = max(5, cfg.maxRecordSeconds)
        recordTimer?.cancel()
        recordTimer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(limit) * 1_000_000_000)
            if !Task.isCancelled { self?.enqueue { [weak self] in await self?.stopRecording() } }
        }
    }

    private func stopRecording() async {
        guard state == .recording else { return }
        busy = true
        defer { busy = false }
        recordTimer?.cancel()
        switch cfg.voiceMode {
        case .hold: injector.up(id: "voice")
        case .tap:
            if let chord = voiceChord() { await injector.tap(chord, holdMs: max(30, cfg.tapHoldMs)) }
        }
        enterReview()
        toast("正在识别…", .info, nil)
        if cfg.syncWithMic {
            // 以系统确认停止收音的时刻作为「识别提交」的起点
            _ = await waitMic(false, timeout: 1.5)
            stopAt = Date()
        }
        toast("已停止 · \(sendHint) / \(resumeHint)继续说", .info, 2.5)
    }

    private func stopIfRecording() async {
        if state == .recording {
            await stopRecording()
            try? await Task.sleep(nanoseconds: UInt64(max(300, cfg.sendDelayMs / 2)) * 1_000_000)
        }
    }

    private func sendNow() async {
        guard accessibilityOK else {
            toast("缺少「辅助功能」权限,请在设置里授权", .warning, 3)
            return
        }
        if state == .recording { await stopRecording() }
        // 等豆包把最后一段识别结果提交到输入框
        let since = Date().timeIntervalSince(stopAt ?? .distantPast)
        let wait = max(0, Double(cfg.sendDelayMs) / 1000 - since)
        if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
        await pressSequence(cfg.sendKey)
        state = .idle
        reviewTimer?.cancel()
        stopAt = nil
        toast("已发送", .success)
    }

    private func clearText() async {
        await pressSequence(cfg.clearKeys)
        try? await Task.sleep(nanoseconds: 120_000_000)
    }

    private func pressSequence(_ text: String) async {
        guard let chords = MicKeys.parseSequence(text) else {
            toast("按键设置无效:\(text)", .warning, 3)
            return
        }
        for c in chords {
            await injector.tap(c)
            try? await Task.sleep(nanoseconds: 60_000_000)
        }
    }

    /// 紧急复位:释放按住的语音键并回到待机(退出、睡眠、TX 掉线、接收器拔出时调用)。
    func abortAll(quiet: Bool) {
        recordTimer?.cancel()
        reviewTimer?.cancel()
        pendingClick = nil
        injector.releaseAll()
        let wasActive = state != .idle
        state = .idle
        if wasActive && !quiet { toast("连接中断,已复位", .warning, 2.5) }
        else if quiet { hud.hide() }
    }

    /// 屏幕顶部的提示只保留「警告 / 出错」类;录音中、识别中、已停止这类状态不再弹出(状态看拾忆面板或输入法自身)。
    private func toast(_ text: String, _ style: MicHUD.Style, _ autoHide: TimeInterval? = 1.6) {
        guard cfg.showHUD else { return }
        guard style == .warning else { hud.hide(); return }
        hud.show(text, style: style, autoHide: autoHide)
    }

    // MARK: - UI 辅助

    var menuIcon: String {
        if !connected { return "mic.slash" }
        if state == .recording { return "record.circle.fill" }
        if heart.anyMuted { return "mic.slash.fill" }
        return "mic.fill"
    }

    var statusLine: String {
        if !inputMonitoringOK && !connected { return "未连接 · 需要「输入监控」权限" }
        if !connected { return attached ? "接收器没有响应(尝试重新连接中,不行请重新插拔接收器)" : "未连接接收器(请插入 USB 接收器)" }
        if !heart.anyOnline { return "接收器已连接 · 麦克风未开机" }
        switch state {
        case .recording: return "录音中"
        case .review: return usesShiyi ? "预览中(三击保存 / 单击说话修改)" : "待确认(\(sendHint))"
        case .idle: return heart.anyMuted ? "待机 · 麦克风已静音(双击解除)" : "待机"
        }
    }
}


func micDebug(_ text: String) {
    let line = "\(Date()) \(text)\n"
    let url = URL(fileURLWithPath: "/tmp/mic_debug.log")
    if let h = try? FileHandle(forWritingTo: url) {
        h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
    } else {
        try? line.write(to: url, atomically: false, encoding: .utf8)
    }
}

extension Notification.Name {
    /// 麦克风三击:请求提交万能输入框里的内容
    static let micQuickAddSubmit = Notification.Name("mic.quickAdd.submit")
}
