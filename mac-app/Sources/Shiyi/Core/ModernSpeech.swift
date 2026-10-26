import AVFoundation
import Foundation
import Speech

/// macOS 26+ 的新一代系统识别（SpeechAnalyzer + SpeechTranscriber）。
/// 比老的 SFSpeechRecognizer 好在：本地模型、不会因为停顿几秒就把一段识别「结束」，长时间连续说话 / 中间停顿都在同一个会话里。
/// 语言模型要先下载好才能用：启动时在后台准备，准备好之前（或系统不支持）自动用老的识别。
/// 新版识别的准备状态（设置页显示当前用的是哪个引擎）
@MainActor
final class ModernSpeechState: ObservableObject {
    static let shared = ModernSpeechState()
    enum Phase { case unsupported, preparing, ready }
    @Published fileprivate(set) var phase: Phase = .unsupported
    fileprivate(set) var locale: Locale?
}

enum ModernSpeech {
    @MainActor static var ready: Bool { ModernSpeechState.shared.phase == .ready }
    @MainActor static var locale: Locale? { ModernSpeechState.shared.locale }

    /// 后台检查并安装中文识别模型
    @MainActor static func warmUp() {
        guard #available(macOS 26, *) else { return }
        let st = ModernSpeechState.shared
        guard st.phase == .unsupported else { return }
        st.phase = .preparing
        Task { @MainActor in
            let loc = await ModernSession.prepare()
            st.locale = loc
            st.phase = loc != nil ? .ready : .unsupported
        }
    }
}

@available(macOS 26, *)
final class ModernSession: @unchecked Sendable {
    private let locale: Locale
    private let hotwords: [String]
    private let raw: AsyncStream<AVAudioPCMBuffer>
    private let rawCont: AsyncStream<AVAudioPCMBuffer>.Continuation

    private let lock = NSLock()
    private var finalText = ""
    private var volatile = ""
    private var done = false
    private var analyzer: SpeechAnalyzer?
    private var task: Task<Void, Never>?

    var onText: (@Sendable (String) -> Void)?

    init(locale: Locale, hotwords: [String]) {
        self.locale = locale
        self.hotwords = hotwords
        (raw, rawCont) = AsyncStream.makeStream(of: AVAudioPCMBuffer.self, bufferingPolicy: .unbounded)
    }

    /// 能用就返回识别用的 locale；模型没装就下载安装
    static func prepare() async -> Locale? {
        guard SpeechTranscriber.isAvailable,
              let loc = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "zh-CN")) else { return nil }
        let t = SpeechTranscriber(locale: loc, preset: .progressiveTranscription)
        var status = await AssetInventory.status(forModules: [t])
        if status == .unsupported { return nil }
        if status < .installed {
            if let req = try? await AssetInventory.assetInstallationRequest(supporting: [t]) {
                try? await req.downloadAndInstall()
            }
            status = await AssetInventory.status(forModules: [t])
        }
        return status == .installed ? loc : nil
    }

    /// 麦克风的音频线程调用：先攒进队列，识别器准备好后再按顺序送进去，开头不丢
    func feed(_ buffer: AVAudioPCMBuffer) {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return }
        copy.frameLength = buffer.frameLength
        let channels = Int(buffer.format.channelCount)
        if let src = buffer.floatChannelData, let dst = copy.floatChannelData {
            for c in 0 ..< channels { memcpy(dst[c], src[c], Int(buffer.frameLength) * MemoryLayout<Float>.size) }
        } else if let src = buffer.int16ChannelData, let dst = copy.int16ChannelData {
            for c in 0 ..< channels { memcpy(dst[c], src[c], Int(buffer.frameLength) * MemoryLayout<Int16>.size) }
        } else {
            return
        }
        rawCont.yield(copy)
    }

    func begin(inputFormat: AVAudioFormat) {
        task = Task { [self] in
            await run(inputFormat: inputFormat)
            lock.withLock { done = true }
        }
    }

    private func run(inputFormat: AVAudioFormat) async {
        do {
            let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            lock.withLock { self.analyzer = analyzer }
            if !hotwords.isEmpty {
                let ctx = AnalysisContext()
                ctx.contextualStrings[.general] = hotwords
                try await analyzer.setContext(ctx)
            }
            guard let fmt = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber], considering: inputFormat) else { return }
            try await analyzer.prepareToAnalyze(in: fmt)
            let converter: AVAudioConverter? = fmt == inputFormat ? nil : AVAudioConverter(from: inputFormat, to: fmt)

            let (inputs, inputCont) = AsyncStream.makeStream(of: AnalyzerInput.self, bufferingPolicy: .unbounded)
            let results = Task { [self] in
                do {
                    for try await r in transcriber.results {
                        handle(text: String(r.text.characters), final: r.isFinal)
                    }
                } catch {}
            }
            try await analyzer.start(inputSequence: inputs)

            for await buf in raw {
                if let out = Self.convert(buf, with: converter, to: fmt) { inputCont.yield(AnalyzerInput(buffer: out)) }
            }
            inputCont.finish()
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            await results.value
        } catch {
            // 识别出错：用已经拿到的文字
        }
    }

    private func handle(text: String, final: Bool) {
        let all: String = lock.withLock {
            if final {
                finalText = Self.join(finalText, text)
                volatile = ""
            } else {
                volatile = text
            }
            return Self.join(finalText, volatile)
        }
        onText?(all)
    }

    private static func convert(_ buf: AVAudioPCMBuffer, with converter: AVAudioConverter?, to fmt: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let converter else { return buf }
        let ratio = fmt.sampleRate / buf.format.sampleRate
        let cap = AVAudioFrameCount(Double(buf.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: cap) else { return nil }
        var supplied = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return buf
        }
        return err == nil && out.frameLength > 0 ? out : nil
    }

    private static func join(_ a: String, _ b: String) -> String {
        if a.isEmpty { return b }
        if b.isEmpty { return a }
        let tail = a.last!
        return "。，！？；,.!?;、…\n ".contains(tail) ? a + b : a + "，" + b
    }

    /// 松手 / 停止：把剩下的音频识别完，返回完整文字（最多等 4 秒，超时用已有的）
    func finish() async -> String {
        rawCont.finish()
        for _ in 0 ..< 80 {
            if lock.withLock({ done }) { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        if !lock.withLock({ done }) {
            let a = lock.withLock { analyzer }
            await a?.cancelAndFinishNow()
        }
        return lock.withLock { Self.join(finalText, volatile) }
    }

    func cancel() {
        rawCont.finish()
        task?.cancel()
        let a = lock.withLock { analyzer }
        Task { await a?.cancelAndFinishNow() }
    }
}
