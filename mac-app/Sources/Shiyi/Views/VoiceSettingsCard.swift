import AppKit
import SwiftUI

/// 设置页里「语音输入」那一张卡：快捷键、模式、识别引擎、整理 / 入库行为、权限、词库、历史
struct VoiceSettingsCard: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var voice = VoiceController.shared
    @ObservedObject private var lexicon = VoiceLexicon.shared

    @AppStorage(VoiceSettings.modeKey) private var mode: VoiceMode = .toggle
    @AppStorage(VoiceSettings.engineKey) private var engine: VoiceEngine = .apple
    @AppStorage(VoiceSettings.polishKey) private var polish = true
    @AppStorage(VoiceSettings.directKey) private var direct = false
    @AppStorage(VoiceSettings.countdownKey) private var countdown = true
    @AppStorage(VoiceSettings.pasteKey) private var paste = false
    @AppStorage(VoiceSettings.autoStopKey) private var autoStop = true
    @AppStorage(VoiceSettings.soundKey) private var sound = true
    @AppStorage(VoiceSettings.duckKey) private var duck = true

    @State private var tencentId = ""
    @State private var tencentKey = ""
    @State private var showKey = false
    @State private var tencentSaved = false
    @State private var hotwords = ""
    @State private var replacements = ""
    @State private var lexiconSaved = false
    @State private var showHistory = false
    @State private var permTick = 0

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(Brand.orange)
                        .frame(width: 30, height: 30)
                        .background(Brand.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    Text("语音输入").font(.headline)
                    TagChip(text: model.hasLlm && polish ? "AI 整理" : "本地整理", tint: model.hasLlm && polish ? .purple : .gray)
                    Spacer()
                }
                Text("在任何 App 里按快捷键说话，AI 整理成待办 / 日记 / 笔记，确认后直接入库。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

                VoiceHotkeyRow()

                Divider()
                row("触发方式") {
                    Picker("", selection: $mode) { ForEach(VoiceMode.allCases) { Text($0.label).tag($0) } }
                        .labelsHidden().frame(width: 240)
                }
                row("识别引擎") {
                    Picker("", selection: $engine) { ForEach(VoiceEngine.allCases) { Text($0.label).tag($0) } }
                        .labelsHidden().frame(width: 330)
                }
                if engine == .tencent { tencentFields }

                Divider()
                Toggle("用 AI 整理（拆成多条、识别日期时间、改 / 完成 / 删待办、问答）", isOn: $polish)
                    .disabled(!model.hasLlm)
                if !model.hasLlm {
                    Text("还没配置 AI 模型，目前只会用本地规则整理（上面的「AI 模型」卡里填写）。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("说完直接入库，不再预览（改 / 完成 / 删除类操作仍会先确认）", isOn: $direct)
                Toggle("预览后 5 秒自动入库（鼠标放在卡片上或修改内容就暂停）", isOn: $countdown).disabled(direct)
                Toggle("停顿约 2.5 秒自动结束（仅「按一下开始」模式）", isOn: $autoStop).disabled(mode != .toggle)
                Toggle("开始 / 结束时播放提示音", isOn: $sound)
                Toggle("录音时自动压低系统音量（结束后恢复）", isOn: $duck)
                Toggle("保存的同时，把文字输入到光标所在位置", isOn: $paste)
                if paste {
                    HStack(spacing: 8) {
                        Image(systemName: AXIsProcessTrusted() ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(AXIsProcessTrusted() ? Color.green : Color.orange)
                        Text(AXIsProcessTrusted() ? "辅助功能已授权" : "需要在「系统设置 → 隐私与安全性 → 辅助功能」里允许拾忆")
                            .font(.caption).foregroundStyle(.secondary)
                        if !AXIsProcessTrusted() {
                            Button("打开") { VoicePermission.openPrivacySettings("Accessibility") }
                                .buttonStyle(.link).font(.caption)
                        }
                    }
                }

                Divider()
                permissions

                Divider()
                lexiconEditor

                Divider()
                HStack {
                    Button { showHistory = true } label: { Label("识别历史", systemImage: "clock.arrow.circlepath") }
                        .buttonStyle(.bordered)
                    Spacer()
                    Text(engine == .apple
                        ? "系统离线识别：音频不离开本机；开启 AI 整理时，识别后的文字会发给你配置的大模型。"
                        : "腾讯云识别：录音会上传到腾讯云；开启 AI 整理时，文字还会发给你配置的大模型。")
                        .font(.caption2).foregroundStyle(.tertiary).multilineTextAlignment(.trailing)
                        .frame(maxWidth: 360, alignment: .trailing)
                }
            }
        }
        .onAppear {
            tencentId = model.credentials.tencentId
            tencentKey = model.credentials.tencentKey
            hotwords = lexicon.hotwordsText
            replacements = lexicon.replacementsText
        }
        .sheet(isPresented: $showHistory) { VoiceHistorySheet() }
    }

    private func row<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack {
            Text(title).font(.callout)
            Spacer(minLength: 12)
            content()
        }
    }

    // MARK: 腾讯云

    private var tencentFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text("SecretId").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                TextField("AKID…", text: $tencentId).textFieldStyle(.roundedBorder).font(.body.monospaced())
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("SecretKey").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Group {
                        if showKey { TextField("", text: $tencentKey) } else { SecureField("", text: $tencentKey) }
                    }
                    .textFieldStyle(.roundedBorder).font(.body.monospaced())
                    Button { showKey.toggle() } label: { Image(systemName: showKey ? "eye.slash" : "eye").frame(width: 18) }
                        .buttonStyle(.borderless)
                }
            }
            HStack(spacing: 10) {
                Button("保存") {
                    model.credentials.setTencent(id: tencentId.trimmed, key: tencentKey.trimmed)
                    tencentSaved = true
                }
                .buttonStyle(.borderedProminent).tint(Brand.orange)
                if tencentSaved { Label("已保存", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green) }
                Spacer()
                Text("在腾讯云控制台「访问管理 → API 密钥」创建；识别结果会用热词增强。")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: 权限

    private var permissions: some View {
        _ = permTick
        return VStack(alignment: .leading, spacing: 8) {
            permRow("麦克风", ok: VoicePermission.micAuthorized, denied: VoicePermission.micDenied, pane: "Microphone") {
                _ = await VoicePermission.ensureMic()
            }
            if engine == .apple {
                permRow("语音识别", ok: VoicePermission.speechAuthorized, denied: VoicePermission.speechDenied, pane: "SpeechRecognition") {
                    _ = await VoicePermission.ensureSpeech()
                }
            }
        }
    }

    private func permRow(_ name: String, ok: Bool, denied: Bool, pane: String, request: @escaping () async -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(ok ? Color.green : Color.orange)
            Text(name + "权限").font(.callout)
            Text(ok ? "已授权" : (denied ? "已被拒绝" : "未授权"))
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            if !ok {
                if denied {
                    Button("打开系统设置") { VoicePermission.openPrivacySettings(pane) }.buttonStyle(.bordered).controlSize(.small)
                } else {
                    Button("请求授权") { Task { await request(); permTick += 1 } }.buttonStyle(.bordered).controlSize(.small)
                }
            }
        }
    }

    // MARK: 词库

    private var lexiconEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("词库").font(.callout.weight(.semibold))
            VStack(alignment: .leading, spacing: 4) {
                Text("热词（人名 / 项目名 / 专业词，用顿号或换行分隔，2–10 字）：系统识别和腾讯云识别都会优先识别这些词，AI 整理时也会按它们修正同音字").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $hotwords)
                    .font(.callout).frame(height: 54)
                    .scrollContentBackground(.hidden)
                    .padding(4).background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("替换规则（每行一条：听错的词=正确写法），识别后无条件替换；在预览里手改同音错字，也会自动记在这里").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $replacements)
                    .font(.callout.monospaced()).frame(height: 70)
                    .scrollContentBackground(.hidden)
                    .padding(4).background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            HStack(spacing: 10) {
                Button("保存词库") {
                    lexicon.save(hotwords: VoiceLexicon.parseHotwords(hotwords), replacements: VoiceLexicon.parseReplacements(replacements))
                    hotwords = lexicon.hotwordsText
                    replacements = lexicon.replacementsText
                    lexiconSaved = true
                }
                .buttonStyle(.borderedProminent).tint(Brand.orange)
                if lexiconSaved { Label("已保存", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green) }
                Spacer()
                Text("\(lexicon.data.hotwords.count) 个热词 · \(lexicon.data.replacements.count) 条替换")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .onChange(of: lexicon.data) { _, _ in
            // 纠错学习在后台改了词库：编辑框没有未保存内容时同步
            hotwords = lexicon.hotwordsText
            replacements = lexicon.replacementsText
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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "keyboard")
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(Brand.orange)
                    .frame(width: 30, height: 30)
                    .background(Brand.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text("语音输入快捷键")
                    Text(choice.modifierKey != nil ? "在任何 App 里按住说话，松开结束" : "在任何 App 里按下开始说话；回车 / 再按一次结束，Esc 取消")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Picker("", selection: $choice) {
                    ForEach(VoiceHotkey.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden().frame(width: 130)
            }

            if choice.modifierKey != nil {
                VStack(alignment: .leading, spacing: 4) {
                    Text("按住说话、松开结束。按住不到 0.15 秒不会触发，Option+其它键 / 点击也不会误触发。")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if choice == .holdFn {
                        Text("fn 键默认可能会触发系统的表情 / 听写：到「系统设置 → 键盘」把「按下 fn 键时」改成「不执行任何操作」。")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    if !ModifierHotkey.permitted {
                        Button("打开「输入监控」设置") { VoicePermission.openPrivacySettings("ListenEvent") }
                            .buttonStyle(.link).font(.caption)
                    }
                }
            }

            if choice == .custom {
                HStack(spacing: 10) {
                    Spacer(minLength: 0)
                    Button {
                        if recording { stopRecording() } else { startRecording() }
                    } label: {
                        Text(recording ? "按下新的组合键…（Esc 取消）" : customLabel)
                            .font(.callout.monospaced().weight(.medium))
                            .frame(minWidth: 170)
                    }
                    .buttonStyle(.bordered)
                    .tint(recording ? Brand.orange : nil)
                }
            }

            if let msg = hint ?? voice.registerError {
                Label(msg, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(Color.orange)
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

private struct VoiceHistorySheet: View {
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
