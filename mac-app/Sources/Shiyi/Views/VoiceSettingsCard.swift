import AppKit
import SwiftUI

/// 设置窗口「语音输入」一页：快捷键、识别引擎、整理 / 入库行为、权限、词库入口、历史
struct VoiceSettingsPane: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var voice = VoiceController.shared
    @ObservedObject private var lexicon = VoiceLexicon.shared
    @ObservedObject private var speech = ModernSpeechState.shared
    @ObservedObject private var nav = SettingsNav.shared

    @AppStorage(VoiceSettings.modeKey) private var mode: VoiceMode = .toggle
    @AppStorage(VoiceSettings.engineKey) private var engine: VoiceEngine = .apple
    @AppStorage(VoiceSettings.polishKey) private var polish = true
    @AppStorage(VoiceSettings.dictPolishKey) private var dictPolish = true
    @AppStorage(VoiceSettings.directKey) private var direct = false
    @AppStorage(VoiceSettings.countdownKey) private var countdown = true
    @AppStorage(VoiceSettings.pasteKey) private var paste = false
    @AppStorage(VoiceSettings.autoStopKey) private var autoStop = true
    @AppStorage(VoiceSettings.soundKey) private var sound = true
    @AppStorage(VoiceSettings.duckKey) private var duck = true
    @AppStorage(VoiceHotkey.key) private var hotkey: VoiceHotkey = .ctrlOptV

    @State private var permTick = 0

    /// 当前「系统」识别实际用的引擎
    private var appleEngineName: String {
        switch speech.phase {
        case .ready: return "新一代系统识别（SpeechTranscriber，本机离线）"
        case .preparing: return "识别模型下载中，暂用系统离线识别（SFSpeechRecognizer）"
        case .unsupported: return "系统离线识别（SFSpeechRecognizer）"
        }
    }

    private var tencentReady: Bool {
        !model.credentials.tencentId.trimmed.isEmpty && !model.credentials.tencentKey.trimmed.isEmpty
    }

    var body: some View {
        SPage {
            SGroup("快捷键", footer: "在任何 App 里按快捷键说话，AI 整理成待办 / 日记 / 笔记，确认后直接入库。") {
                VoiceHotkeyRow()
                if hotkey.modifierKey == nil {
                    SRow("触发方式", hint: mode == .hold ? "按住快捷键说话，松手结束" : "按一下开始，再按一下结束") {
                        SPick(selection: $mode, options: VoiceMode.allCases.map { ($0, $0.label) })
                    }
                }
            }

            SGroup("识别",
                   footer: engine == .apple
                       ? "系统识别在本机完成，音频不离开这台 Mac；开启 AI 整理时，识别后的文字会发给你配置的大模型。"
                       : "腾讯云识别：录音会上传到腾讯云；开启 AI 整理时，文字还会发给你配置的大模型。") {
                SRow("识别引擎") {
                    SPick(selection: $engine, options: VoiceEngine.allCases.map { ($0, $0.label) })
                }
                if engine == .apple {
                    SRow("当前使用", hint: appleEngineName) {
                        if speech.phase == .preparing { ProgressView().controlSize(.small) }
                    }
                } else {
                    SRow("腾讯云密钥", hint: tencentReady ? "已填写" : "还没填写，识别前需要先填") {
                        SAction(tencentReady ? "修改" : "去填写") { nav.tab = .account }
                    }
                }
            }

            SGroup("整理与入库") {
                SToggle("用 AI 整理",
                        model.hasLlm ? "拆成多条、识别日期时间、改 / 完成 / 删待办、问答" : "还没配置 AI 模型，目前只会用本地规则整理",
                        $polish)
                    .disabled(!model.hasLlm)
                SToggle("听写进万能输入框时 AI 润色",
                        model.hasLlm ? "在万能输入框里说话（含麦克风按钮、发射器）：只润色成通顺文字填进输入框，不拆待办、不入库" : "还没配置 AI 模型，听写只做词库替换和去语气词",
                        $dictPolish)
                    .disabled(!model.hasLlm)
                SToggle("说完直接入库", "不再预览；改 / 完成 / 删除类操作仍会先确认", $direct)
                SToggle("预览后 5 秒自动入库", "鼠标放在卡片上或修改内容就暂停", $countdown)
                    .disabled(direct)
                SToggle("同时输入到光标位置", "保存的同时，把文字打到你当前光标所在的地方", $paste)
                if paste {
                    let ok = AXIsProcessTrusted()
                    SRow(ok ? "辅助功能已授权" : "需要辅助功能权限", hint: ok ? nil : "到「系统设置 → 隐私与安全性 → 辅助功能」里允许拾忆") {
                        if ok {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.green)
                        } else {
                            SAction("打开") { VoicePermission.openPrivacySettings("Accessibility") }
                        }
                    }
                }
            }

            SGroup("录音体验") {
                SToggle("停顿自动结束", "停顿约 2.5 秒就结束录音（仅「按一下开始」模式）", $autoStop)
                    .disabled(mode != .toggle || hotkey.modifierKey != nil)
                SToggle("提示音", "开始 / 结束录音时播放", $sound)
                SToggle("录音时压低系统音量", "结束后自动恢复，避免背景音乐被识别进去", $duck)
            }

            SGroup("权限") {
                permRow("麦克风", ok: VoicePermission.micAuthorized, denied: VoicePermission.micDenied, pane: "Microphone") {
                    _ = await VoicePermission.ensureMic()
                }
                if engine == .apple {
                    permRow("语音识别", ok: VoicePermission.speechAuthorized, denied: VoicePermission.speechDenied, pane: "SpeechRecognition") {
                        _ = await VoicePermission.ensureSpeech()
                    }
                }
            }
            .id(permTick)

            SGroup("词库与历史") {
                SRow("词库", hint: "\(lexicon.data.hotwords.count) 个热词 · \(lexicon.data.replacements.count) 条替换") {
                    SAction("管理") { nav.tab = .lexicon }
                }
                SRow("识别历史", hint: "每次说的话、识别引擎和入库结果") {
                    SAction("查看") { nav.showVoiceHistory = true }
                }
            }
        }
        .sheet(isPresented: $nav.showVoiceHistory) { VoiceHistorySheet() }
    }

    // MARK: 权限

    private func permRow(_ name: String, ok: Bool, denied: Bool, pane: String, request: @escaping () async -> Void) -> some View {
        SRow(name, hint: ok ? "已授权" : (denied ? "已被拒绝，需要到系统设置里打开" : "未授权")) {
            if ok {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.green)
            } else if denied {
                SAction("打开系统设置") { VoicePermission.openPrivacySettings(pane) }
            } else {
                SAction("请求授权") { Task { await request(); permTick += 1 } }
            }
        }
    }
}

// MARK: - 快捷键行（和万能输入那行同样的交互）

struct VoiceHotkeyRow: View {
    @AppStorage(VoiceHotkey.key) private var choice: VoiceHotkey = .ctrlOptV
    @AppStorage(VoiceHotkey.customCodeKey) private var customCode = -1
    @AppStorage(VoiceHotkey.customModsKey) private var customMods = 0
    @AppStorage(VoiceHotkey.customNameKey) private var customName = ""
    @ObservedObject private var voice = VoiceController.shared

    @State private var recording = false
    @State private var monitor: Any?
    @State private var hint: String?

    private var customLabel: String {
        _ = (customCode, customMods, customName)
        return VoiceHotkey.savedCustom?.label ?? "点击录制"
    }

    private var tip: String {
        if choice == .holdFn {
            return "按住说话，松开结束。需到「系统设置 → 键盘」把「按下 fn 键时」改成「不执行任何操作」"
        }
        if choice.modifierKey != nil {
            return "按住说话，松开结束。按住不到 0.15 秒、同时按了其它键或点击都不会触发"
        }
        return "按下开始说话；回车 / 再按一次结束，Esc 取消"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SRow("语音输入快捷键", hint: tip) {
                HStack(spacing: 10) {
                    if choice == .custom {
                        Button {
                            if recording { stopRecording() } else { startRecording() }
                        } label: {
                            Text(recording ? "按下新的组合键…（Esc 取消）" : customLabel)
                                .font(.system(size: 12, design: .monospaced).weight(.medium))
                        }
                        .buttonStyle(.bordered).controlSize(.small)
                        .tint(recording ? Color.accentColor : nil)
                    }
                    SPick(selection: $choice, options: VoiceHotkey.allCases.map { ($0, $0.label) })
                }
            }

            if choice.modifierKey != nil, !ModifierHotkey.permitted {
                HStack(spacing: 8) {
                    Label("需要「输入监控」权限才能识别单独的修饰键", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11.5)).foregroundStyle(Color.orange)
                    Spacer(minLength: 0)
                    SAction("打开设置") { VoicePermission.openPrivacySettings("ListenEvent") }
                }
            }

            if let msg = hint ?? voice.registerError {
                Label(msg, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11.5)).foregroundStyle(Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onChange(of: choice) { _, new in
            hint = nil
            if new == .custom {
                if VoiceHotkey.savedCustom == nil { startRecording() }
            } else {
                stopRecording()
            }
        }
        .onDisappear { stopRecording() }
    }

    private func startRecording() {
        stopRecording()
        hint = nil
        recording = true
        voice.suspendHotkey()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            handle(e)
            return nil
        }
    }

    private func stopRecording() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        if recording {
            recording = false
            voice.resumeHotkey()
        }
    }

    private func handle(_ e: NSEvent) {
        let flags = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if e.keyCode == 53, flags.isEmpty {
            stopRecording()
            return
        }
        let combo = HotkeyCombo(
            code: UInt32(e.keyCode),
            mods: HotkeyCombo.carbonMods(flags),
            name: HotkeyCombo.keyName(code: e.keyCode, chars: e.charactersIgnoringModifiers)
        )
        if let why = combo.problem {
            hint = why
            return
        }
        VoiceHotkey.saveCustom(combo)
        hint = nil
        stopRecording()
    }
}

// MARK: - 历史

struct VoiceHistorySheet: View {
    @ObservedObject private var history = VoiceHistory.shared
    @Environment(\.dismiss) private var dismiss

    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "M月d日 HH:mm"
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("识别历史").font(.headline)
                Spacer()
                if !history.records.isEmpty { Button("清空") { history.clear() }.buttonStyle(.borderless) }
                Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(16)
            Divider()
            if history.records.isEmpty {
                Text("还没有记录").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(history.records) { r in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Text(Self.fmt.string(from: r.at)).font(.caption).foregroundStyle(.secondary)
                                    TagChip(text: r.status, tint: r.status == "已保存" ? .green : .gray)
                                    TagChip(text: r.engine, tint: .blue)
                                    if r.polished { TagChip(text: "AI 整理", tint: .purple) }
                                }
                                Text(r.raw).font(.callout).textSelection(.enabled)
                                ForEach(r.items, id: \.self) { Text("→ " + $0).font(.callout).foregroundStyle(Brand.orangeDeep).textSelection(.enabled) }
                                if let n = r.note { Text(n).font(.caption).foregroundStyle(.secondary) }
                            }
                            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                    }
                    .padding(16)
                }
            }
        }
        .frame(width: 520, height: 520)
    }
}
