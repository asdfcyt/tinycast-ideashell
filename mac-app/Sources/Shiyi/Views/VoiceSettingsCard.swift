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
            SGroup("识别") {
                SRow("识别引擎") {
                    SPick(selection: $engine, options: VoiceEngine.allCases.map { ($0, $0.label) })
                }
                if engine == .apple {
                    SRow("当前使用", hint: appleEngineName) {
                        if speech.phase == .preparing { ProgressView().controlSize(.small) }
                    }
                } else if !tencentReady {
                    SLinkRow("腾讯云密钥", hint: "还没填写") { nav.tab = .account }
                }
            }

            SGroup("整理与入库") {
                SToggle("用 AI 整理", model.hasLlm ? nil : "还没配置 AI 模型", $polish)
                    .disabled(!model.hasLlm)
                SToggle("听写进万能输入框时 AI 润色", model.hasLlm ? nil : "还没配置 AI 模型", $dictPolish)
                    .disabled(!model.hasLlm)
                SToggle("说完直接入库", nil, $direct)
                SToggle("预览后 5 秒自动入库", nil, $countdown)
                    .disabled(direct)
                SToggle("同时输入到光标位置", nil, $paste)
                if paste {
                    let ok = AXIsProcessTrusted()
                    SRow(ok ? "辅助功能已授权" : "需要辅助功能权限", hint: ok ? nil : "系统设置 → 隐私与安全性 → 辅助功能") {
                        if ok {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.green)
                        } else {
                            SIconButton(symbol: "gearshape", help: "打开系统设置") { VoicePermission.openPrivacySettings("Accessibility") }
                        }
                    }
                }
            }

            SGroup("录音体验") {
                SToggle("停顿自动结束", nil, $autoStop)
                    .disabled(mode != .toggle || hotkey.modifierKey != nil)
                SToggle("提示音", nil, $sound)
                SToggle("录音时压低系统音量", nil, $duck)
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

            LexiconGroups()

            SGroup {
                SLinkRow("识别历史") { nav.showVoiceHistory = true }
            }
        }
        .sheet(isPresented: $nav.showVoiceHistory) { VoiceHistorySheet() }
    }

    // MARK: 权限

    private func permRow(_ name: String, ok: Bool, denied: Bool, pane: String, request: @escaping () async -> Void) -> some View {
        SRow(name, hint: ok ? nil : (denied ? "已被拒绝，需要到系统设置里打开" : nil)) {
            if ok {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.green)
            } else if denied {
                SIconButton(symbol: "gearshape", help: "打开系统设置") { VoicePermission.openPrivacySettings(pane) }
            } else {
                SIconButton(symbol: "lock.open", help: "请求授权") { Task { await request(); permTick += 1 } }
            }
        }
    }
}

// MARK: - 快捷键行（放在「设置 → 通用 → 全局快捷键」）

struct VoiceHotkeyRow: View {
    @AppStorage(VoiceHotkey.key) private var choice: VoiceHotkey = .ctrlOptV
    @ObservedObject private var voice = VoiceController.shared

    /// 只在需要用户额外动手时才提示
    private var tip: String? {
        choice == .holdFn ? "需到「系统设置 → 键盘」把「按下 fn 键时」改成「不执行任何操作」" : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GlobalHotkeyRow(
                title: "语音输入", hint: tip, choice: $choice,
                options: VoiceHotkey.allCases.map { ($0, $0.label) }, customChoice: .custom, owner: .voice,
                saved: { VoiceHotkey.savedCustom }, save: VoiceHotkey.saveCustom,
                suspend: { voice.suspendHotkey() }, resume: { voice.resumeHotkey() },
                registerError: voice.registerError
            )

            if choice.modifierKey != nil, !ModifierHotkey.permitted {
                HStack(spacing: 8) {
                    Label("需要「输入监控」权限才能识别单独的修饰键", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11.5)).foregroundStyle(Color.orange)
                    Spacer(minLength: 0)
                    SIconButton(symbol: "gearshape", help: "打开系统设置") { VoicePermission.openPrivacySettings("ListenEvent") }
                }
            }
        }
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
