import AppKit
import SwiftUI

/// 设置：连接账号、手机备份、本机数据。卡片式排布，和其他页面保持同一套玻璃风格。
struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var saving = false
    @State private var showIdeashell = false
    @State private var showDida = false
    @State private var showLlm = false
    @State private var testing = false
    @State private var testResult: (ok: Bool, text: String)?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("设置").font(.largeTitle.bold())

                accountsCard
                aiCard
                focusCard
                notifyCard
                backupCard
                dataCard
                shortcutsCard
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(AmbientBackground())
    }

    // MARK: - 账号

    private var accountsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 16) {
                SectionTitle(text: "账号连接")

                credentialRow(
                    icon: "tray.full", tint: Brand.orange,
                    name: "闪念贝壳", connected: model.hasIdeashell,
                    placeholder: "API Key", text: $model.ideashellKeyInput, reveal: $showIdeashell,
                    hint: "在闪念贝壳 App 的「设置 → API / MCP」里创建。用于读写笔记、读取手机备份。"
                )

                Divider()

                credentialRow(
                    icon: "checklist", tint: .blue,
                    name: "滴答清单", connected: model.hasDida,
                    placeholder: "API 口令", text: $model.didaTokenInput, reveal: $showDida,
                    hint: "在滴答清单「设置 → 账户 → API 口令」里创建。用于读写待办和专注。"
                )

                HStack(spacing: 10) {
                    Button {
                        saving = true
                        Task { await model.saveCredentials(); saving = false }
                    } label: {
                        Text("保存并刷新").frame(minWidth: 70)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Brand.orange)
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving)
                    if saving { ProgressView().controlSize(.small) }
                    Spacer()
                    Label("只保存在本机，仅当前用户可读", systemImage: "lock.fill")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func credentialRow(
        icon: String, tint: Color, name: String, connected: Bool, placeholder: String,
        text: Binding<String>, reveal: Binding<Bool>, hint: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 30, height: 30)
                    .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                Text(name).font(.headline)
                TagChip(text: connected ? "已连接" : "未填写", tint: connected ? .green : .orange)
                Spacer()
            }
            HStack(spacing: 6) {
                Group {
                    if reveal.wrappedValue {
                        TextField(placeholder, text: text)
                    } else {
                        SecureField(placeholder, text: text)
                    }
                }
                .textFieldStyle(.roundedBorder)
                .font(.body.monospaced())
                Button {
                    reveal.wrappedValue.toggle()
                } label: {
                    Image(systemName: reveal.wrappedValue ? "eye.slash" : "eye").frame(width: 18)
                }
                .buttonStyle(.borderless)
                .help(reveal.wrappedValue ? "隐藏" : "显示")
            }
            Text(hint).font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - AI 模型

    private var aiCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(.purple)
                        .frame(width: 30, height: 30)
                        .background(Color.purple.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    Text("AI 模型").font(.headline)
                    TagChip(text: model.hasLlm ? "已配置" : "未填写", tint: model.hasLlm ? .green : .orange)
                    Spacer()
                    Menu {
                        ForEach(LlmClient.presets, id: \.name) { p in
                            Button(p.name) { model.llmBaseUrl = p.url; model.llmModel = p.model }
                        }
                    } label: {
                        Label("常用服务", systemImage: "list.bullet")
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                }

                field("接口地址", "https://…/v1", $model.llmBaseUrl)
                field("模型名", "qwen-plus", $model.llmModel)

                VStack(alignment: .leading, spacing: 4) {
                    Text("API Key").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        Group {
                            if showLlm { TextField("sk-…", text: $model.llmKeyInput) } else { SecureField("sk-…", text: $model.llmKeyInput) }
                        }
                        .textFieldStyle(.roundedBorder).font(.body.monospaced())
                        Button { showLlm.toggle() } label: { Image(systemName: showLlm ? "eye.slash" : "eye").frame(width: 18) }
                            .buttonStyle(.borderless)
                    }
                }

                HStack(spacing: 10) {
                    Button("保存") { model.saveLlm(); testResult = nil }
                        .buttonStyle(.borderedProminent).tint(Brand.orange)
                    Button {
                        model.saveLlm()
                        testing = true
                        testResult = nil
                        Task {
                            do {
                                let r = try await model.llm.chatJSON(system: "只输出 JSON 对象：{\"ok\":true}", user: "ping", timeout: 20)
                                testResult = (true, "连接正常" + (r.isEmpty ? "" : "（模型 \(model.llmModel)）"))
                            } catch {
                                testResult = (false, error.localizedDescription)
                            }
                            testing = false
                        }
                    } label: { Text("测试连接") }
                        .buttonStyle(.bordered).disabled(testing || model.llmKeyInput.trimmed.isEmpty)
                    if testing { ProgressView().controlSize(.small) }
                    if let r = testResult {
                        Label(r.text, systemImage: r.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(r.ok ? Color.green : Color.red).lineLimit(2)
                    }
                    Spacer()
                }
                Text("支持任何 OpenAI 兼容的接口（通义千问、DeepSeek、OpenAI、智谱等）。目前用于「重新规划」里的 AI 排期；Key 只保存在本机。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func field(_ name: String, _ placeholder: String, _ text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(name).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            TextField(placeholder, text: text).textFieldStyle(.roundedBorder).font(.body.monospaced())
        }
    }

    // MARK: - 通知

    @AppStorage("notify.focus") private var nFocus = true
    @AppStorage("notify.goal") private var nGoal = true
    @AppStorage("notify.due") private var nDue = true
    @AppStorage("notify.lead") private var nLead = 10
    @AppStorage("notify.digest") private var nDigest = true
    @AppStorage("notify.overdue") private var nOverdue = true

    private var notifyCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    SectionTitle(text: "通知")
                    Spacer()
                    Button("发送测试通知") { Notifier.shared.sendTest() }.buttonStyle(.bordered)
                }
                notifyRow("专注与休息", "番茄完成、休息结束、还剩 5 分钟、暂停太久", $nFocus)
                notifyRow("专注目标达成", "今天的专注时长第一次达到每日目标", $nGoal)
                Divider()
                notifyRow("待办到点", "有具体时间的待办，到点提醒", $nDue)
                if nDue {
                    HStack {
                        Text("提前提醒").font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        Picker("", selection: $nLead) {
                            Text("不提前").tag(0)
                            Text("5 分钟").tag(5)
                            Text("10 分钟").tag(10)
                            Text("15 分钟").tag(15)
                            Text("30 分钟").tag(30)
                        }
                        .labelsHidden().frame(width: 110)
                    }
                    .padding(.leading, 2)
                }
                notifyRow("早晚简报", "早上 8:30 今天的安排，晚上 9:00 还没完成的几件", $nDigest)
                notifyRow("逾期提醒", "每天 10:00 提醒还有几件逾期", $nOverdue)
                Text("待办提醒在待办刷新后重新安排，退出拾忆后也会按时响。如果收不到，请在「系统设置 → 通知」里允许拾忆。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onChange(of: nDue) { _, _ in Notifier.shared.syncTodos(model.overview) }
        .onChange(of: nLead) { _, _ in Notifier.shared.syncTodos(model.overview) }
        .onChange(of: nDigest) { _, _ in Notifier.shared.syncTodos(model.overview) }
        .onChange(of: nOverdue) { _, _ in Notifier.shared.syncTodos(model.overview) }
    }

    private func notifyRow(_ title: String, _ hint: String, _ on: Binding<Bool>) -> some View {
        Toggle(isOn: on) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(hint).font(.caption).foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.switch)
    }

    // MARK: - 专注目标

    private var focusCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(text: "专注")
                HStack {
                    Text("每日专注目标")
                    Spacer()
                    Text(goalText).monospacedDigit().foregroundStyle(.secondary)
                    Stepper("", value: $model.focusGoalMin, in: 10 ... 720, step: 10).labelsHidden()
                }
                Text("「今天」页的专注环以它为满环。").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var goalText: String {
        let m = model.focusGoalMin
        return m < 60 ? "\(m) 分钟" : (m % 60 == 0 ? "\(m / 60) 小时" : "\(m / 60) 小时 \(m % 60) 分钟")
    }

    // MARK: - 手机备份

    private var backupCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    SectionTitle(text: "手机备份")
                    if model.backupLoading { ProgressView().controlSize(.small) }
                    Spacer()
                    Button {
                        Task { await model.loadBackup() }
                    } label: { Label("重新读取", systemImage: "arrow.clockwise") }
                        .buttonStyle(.bordered)
                        .disabled(model.backupLoading || !model.hasIdeashell)
                }

                if let b = model.backup {
                    HStack(spacing: 10) {
                        miniStat("\(b.workspace.projects.count)", "项目")
                        miniStat("\(b.workspace.taskNotes.count + localOnlyCount)", "任务笔记")
                        miniStat("\(b.workspace.focusLog.count)", "专注记录")
                    }
                    if let d = b.exportedDate {
                        Label("导出于 " + d.formatted(date: .abbreviated, time: .shortened), systemImage: "clock")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Label("还没有读到备份", systemImage: "tray").foregroundStyle(.secondary)
                }
                if let e = model.backupError { ErrorBanner(text: e) }
                Text("项目、任务笔记的对应关系来自手机在闪念贝壳里的「拾忆备份（请勿删除）」笔记，Mac 端只读取；在 Mac 上新建的任务笔记会记在本机，并把链接写回滴答任务。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// 只在本机、还没进手机备份的任务笔记数
    private var localOnlyCount: Int {
        let remote = model.backup?.workspace.taskNotes ?? [:]
        return model.localTaskNotes.keys.filter { remote[$0] == nil }.count
    }

    private func miniStat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 24, weight: .semibold, design: .rounded))
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - 本机数据

    private var dataCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(text: "本机数据")
                HStack(spacing: 10) {
                    Image(systemName: "folder").foregroundStyle(.secondary)
                    Text(LocalStore.dir.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(.callout.monospaced()).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    Spacer()
                    Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([LocalStore.dir]) }
                        .buttonStyle(.bordered)
                }
                Text("凭证、备份缓存、本机新建的任务笔记都存在这里；笔记和待办本身保存在闪念贝壳和滴答清单，不会存在这里。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 快捷键

    private var shortcutsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(text: "快捷键")
                shortcut("⌘ N", "万能输入：写笔记 / 记待办，自动识别")
                shortcut("⌘ R", "刷新当前页")
            }
        }
    }

    private func shortcut(_ keys: String, _ text: String) -> some View {
        HStack(spacing: 12) {
            Text(keys)
                .font(.callout.monospaced().weight(.medium))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .frame(width: 64, alignment: .leading)
            Text(text).font(.callout).foregroundStyle(.secondary)
            Spacer()
        }
    }
}
