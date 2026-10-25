import AppKit
import AVFoundation
import Speech

struct VoiceError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// 麦克风 / 语音识别权限
enum VoicePermission {
    static var micAuthorized: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }
    static var micDenied: Bool { [.denied, .restricted].contains(AVCaptureDevice.authorizationStatus(for: .audio)) }
    static var speechAuthorized: Bool { SFSpeechRecognizer.authorizationStatus() == .authorized }
    static var speechDenied: Bool { [.denied, .restricted].contains(SFSpeechRecognizer.authorizationStatus()) }

    static func ensureMic() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    static func ensureSpeech() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return true
        case .notDetermined:
            return await withCheckedContinuation { c in
                SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
            }
        default: return false
        }
    }

    static func openPrivacySettings(_ pane: String) {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_\(pane)") { NSWorkspace.shared.open(u) }
    }
}

/// 音频线程上的收集器：同时把音频喂给系统识别、转成 16k 单声道 16 位 PCM 存起来（腾讯云用）、算音量
private final class AudioSink: @unchecked Sendable {
    static let maxBytes = 16_000 * 2 * 60   // 最长 60 秒（一句话识别的上限）

    private let lock = NSLock()
    private var pcm = Data()
    private var converter: AVAudioConverter?
    private var hitLimit = false
    private let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!

    private var _request: SFSpeechAudioBufferRecognitionRequest?
    /// 识别请求会在录音中途换新（见 VoiceRecorder.startTask），音频线程和主线程都会碰它，所以加锁
    var request: SFSpeechAudioBufferRecognitionRequest? {
        get { lock.withLock { _request } }
        set { lock.withLock { _request = newValue } }
    }
    private var _modernFeed: (@Sendable (AVAudioPCMBuffer) -> Void)?
    /// 新版识别（macOS 26+）的音频入口
    var modernFeed: (@Sendable (AVAudioPCMBuffer) -> Void)? {
        get { lock.withLock { _modernFeed } }
        set { lock.withLock { _modernFeed = newValue } }
    }
    var onLevel: (@Sendable (Float) -> Void)?
    var onLimit: (@Sendable () -> Void)?

    func configure(input: AVAudioFormat) {
        lock.withLock {
            pcm = Data()
            hitLimit = false
            converter = AVAudioConverter(from: input, to: target)
        }
    }

    func handle(_ buffer: AVAudioPCMBuffer) {
        request?.append(buffer)
        modernFeed?(buffer)

        if let ch = buffer.floatChannelData?[0], buffer.frameLength > 0 {
            var sum: Float = 0
            for i in 0 ..< Int(buffer.frameLength) { sum += ch[i] * ch[i] }
            onLevel?(min(1, (sum / Float(buffer.frameLength)).squareRoot() * 9))
        }

        lock.lock()
        defer { lock.unlock() }
        guard let converter, pcm.count < Self.maxBytes else { return }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let cap = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: cap) else { return }
        var supplied = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        if err == nil, let p = out.int16ChannelData?[0], out.frameLength > 0 {
            pcm.append(Data(bytes: p, count: Int(out.frameLength) * 2))
        }
        if pcm.count >= Self.maxBytes, !hitLimit {
            hitLimit = true
            onLimit?()
        }
    }

    func takePCM() -> Data { lock.withLock { pcm } }
}

/// 录音 + 系统离线识别（实时出字）。腾讯云模式只录音，识别由调用方拿 PCM 去做。
@MainActor
final class VoiceRecorder {
    struct Output {
        /// 系统识别的最终（或最后一次中间）文字；没开系统识别为空
        var text: String
        /// 16k / 单声道 / 16 位 PCM
        var pcm: Data
    }

    var onPartial: ((String) -> Void)?
    var onLevel: ((Float) -> Void)?
    var onLimit: (() -> Void)?

    private let engine = AVAudioEngine()
    private let sink = AudioSink()
    private var task: SFSpeechRecognitionTask?
    private var partial = ""
    // 系统识别在停顿 / 一段话结束后会「另起一段」，新结果只含最新这一段；
    // 所以把已经结束的段落累积到 committed，当前这一段放 current，对外的文字 = committed + current
    private var recognizer: SFSpeechRecognizer?
    private var hotwords: [String] = []
    private var committed = ""
    private var current = ""
    private var gen = 0
    private var emptyRestarts = 0
    private var taskStartedAt = Date()
    private var finished = false
    /// 新版识别会话（ModernSession，macOS 26+）；非 nil 时不用 SFSpeechRecognizer
    private var modern: AnyObject?
    private var waiter: CheckedContinuation<Void, Never>?
    private(set) var running = false

    /// 系统识别是否能离线用（设置页显示）
    static var appleOnDevice: Bool { SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))?.supportsOnDeviceRecognition ?? false }

    func start(liveText: Bool, hotwords: [String]) throws {
        guard !running else { return }
        partial = ""
        finished = false
        let input = engine.inputNode
        let fmt = input.outputFormat(forBus: 0)
        guard fmt.sampleRate > 0, fmt.channelCount > 0 else { throw VoiceError(message: "没有可用的麦克风") }
        sink.configure(input: fmt)
        sink.request = nil

        recognizer = nil
        modern = nil
        sink.modernFeed = nil
        committed = ""
        current = ""
        emptyRestarts = 0
        self.hotwords = hotwords
        if liveText {
            if #available(macOS 26, *), ModernSpeech.ready, let loc = ModernSpeech.locale {
                // 新版系统识别：停顿多久都在同一个会话里，不会被「断句」
                let s = ModernSession(locale: loc, hotwords: hotwords)
                s.onText = { [weak self] t in Task { @MainActor in self?.modernText(t) } }
                s.begin(inputFormat: fmt)
                modern = s
                sink.modernFeed = { [s] b in s.feed(b) }
            } else {
                guard let rec = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN")), rec.isAvailable else {
                    throw VoiceError(message: "系统语音识别暂时不可用（中文）")
                }
                recognizer = rec
                startTask()
            }
        }

        sink.onLevel = { [weak self] v in Task { @MainActor in self?.onLevel?(v) } }
        sink.onLimit = { [weak self] in Task { @MainActor in self?.onLimit?() } }
        input.installTap(onBus: 0, bufferSize: 4096, format: fmt) { [sink] buf, _ in sink.handle(buf) }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            task?.cancel(); task = nil
            sink.request = nil
            sink.modernFeed = nil
            if #available(macOS 26, *) { (modern as? ModernSession)?.cancel() }
            modern = nil
            throw VoiceError(message: "无法开始录音：\(error.localizedDescription)")
        }
        running = true
    }

    private func modernText(_ t: String) {
        guard running, modern != nil else { return }
        partial = t
        onPartial?(t)
    }

    /// 开一个新的识别任务（录音开始时一次；之后系统结束了当前任务但还在录音时，再接一个）
    private func startTask() {
        guard let rec = recognizer else { return }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if rec.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        req.addsPunctuation = true
        req.contextualStrings = hotwords
        gen += 1
        let g = gen
        current = ""
        taskStartedAt = Date()
        sink.request = req
        task = rec.recognitionTask(with: req) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let final = result?.isFinal ?? false
            let failed = error != nil
            Task { @MainActor in self?.recognized(text, final: final, failed: failed, gen: g) }
        }
    }

    private func recognized(_ text: String?, final: Bool, failed: Bool, gen g: Int) {
        guard g == gen else { return }   // 已经被换掉的旧任务
        if let text, !text.isEmpty {
            emptyRestarts = 0
            // 系统另起了一段：把上一段收进 committed，不然会被新结果整个覆盖，只剩最后一句
            if Self.isNewSegment(old: current, new: text) { committed = Self.join(committed, current) }
            current = text
            partial = Self.join(committed, current)
            onPartial?(partial)
        }
        if final || failed {
            // 任务活了一阵才结束（停顿太久被系统判定「没在说话」/ 一段话说完）是正常的，不计入失败；
            // 只有一开就立刻结束（识别坏了）才计数，连续几次就放弃，免得死循环
            if Date().timeIntervalSince(taskStartedAt) > 1.5 { emptyRestarts = 0 }
            if running, recognizer != nil, emptyRestarts < 4 {
                // 录音还在继续，识别任务却结束了（长时间说话 / 停顿 / 系统超时 / 报错）：接一个新任务，停顿后接着说的话不能丢
                if current.isEmpty { emptyRestarts += 1 } else {
                    committed = Self.join(committed, current)
                    current = ""
                }
                task?.cancel()
                task = nil
                startTask()
            } else {
                finished = true
                resumeWaiter()
            }
        }
    }

    private static func sig(_ s: String) -> [Character] { s.filter { $0.isLetter || $0.isNumber } }

    /// 新结果和上一次结果开头对不上，就是另起了一段（同一段内的修正只会改个别字，开头不会整个换掉）
    private static func isNewSegment(old: String, new: String) -> Bool {
        let a = sig(old), b = sig(new)
        guard a.count >= 4, b.count >= 2 else { return false }
        return Array(a.prefix(2)) != Array(b.prefix(2))
    }

    private static func join(_ a: String, _ b: String) -> String {
        if a.isEmpty { return b }
        if b.isEmpty { return a }
        let tail = a.last!
        return "。，！？；,.!?;、…\n ".contains(tail) ? a + b : a + "，" + b
    }

    private func resumeWaiter() {
        waiter?.resume()
        waiter = nil
    }

    /// 结束录音，等系统识别给出最终结果（最多 2.5 秒，超时就用最后一次中间结果）
    func stop() async -> Output {
        guard running else { return Output(text: partial, pcm: sink.takePCM()) }
        running = false
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        if #available(macOS 26, *), let m = modern as? ModernSession {
            sink.modernFeed = nil
            let t = await m.finish()
            modern = nil
            if !t.isEmpty { partial = t }
            return Output(text: partial, pcm: sink.takePCM())
        }
        sink.request?.endAudio()
        if task != nil, !finished {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                waiter = c
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in self?.resumeWaiter() }
            }
        }
        task?.cancel()
        task = nil
        sink.request = nil
        return Output(text: partial, pcm: sink.takePCM())
    }

    func cancel() {
        if running {
            running = false
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        sink.modernFeed = nil
        if #available(macOS 26, *) { (modern as? ModernSession)?.cancel() }
        modern = nil
        sink.request?.endAudio()
        task?.cancel()
        task = nil
        sink.request = nil
        resumeWaiter()
    }
}
