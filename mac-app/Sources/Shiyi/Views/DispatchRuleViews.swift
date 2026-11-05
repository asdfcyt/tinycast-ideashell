import AppKit
import SwiftUI

/// 添加 / 修改一条自动派活规则
struct DispatchRuleEditor: View {
    let existing: DispatchRule?
    /// 从模板添加时的初始内容
    var preset: DispatchRule? = nil
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var ocStore = OpenCodeStore.shared

    @State private var rule = DispatchRule()
    @State private var error: String?

    /// 规则只派给命令行 Agent：WorkBuddy 要靠界面操作，会抢你的焦点
    private var profiles: [AgentProfile] { AgentProfiles.all.filter { $0.kind == .command && $0.enabled } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(existing == nil ? "添加自动派活规则" : "修改规则").font(.system(size: 15, weight: .semibold))
                .padding(.horizontal, 18).padding(.vertical, 14)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    labeled("名称") { TextField("比如 每日回顾", text: $rule.name).textFieldStyle(.roundedBorder) }

                    labeled("触发") {
                        Picker("", selection: $rule.trigger) {
                            ForEach(DispatchRule.Trigger.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                        .labelsHidden().fixedSize()
                    }
                    if rule.isTimed {
                        if rule.trigger == .weekly {
                            labeled("周几") {
                                Picker("", selection: weekdayBinding) {
                                    ForEach(1...7, id: \.self) { Text(DispatchRule.weekdayNames[$0 - 1]).tag($0) }
                                }
                                .pickerStyle(.segmented).labelsHidden()
                            }
                        }
                        labeled("时间") {
                            DatePicker("", selection: timeBinding, displayedComponents: .hourAndMinute).labelsHidden()
                        }
                        if rule.pickMaterial {
                            labeled("带什么资料") {
                                Picker("", selection: $rule.material) {
                                    ForEach(DispatchRule.Material.allCases, id: \.self) { Text($0.label).tag($0) }
                                }
                                .labelsHidden().fixedSize()
                            }
                        } else {
                            Text("每天到点检查一次：没有逾期就不打扰（不调用 Agent）；有逾期才派一轮，资料是逾期清单。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } else if rule.isTagged {
                        labeled("标签") {
                            TextField("派活", text: $rule.tag).textFieldStyle(.roundedBorder)
                        }
                        if rule.trigger == .todoTag {
                            Text("给滴答任务加上这个标签：没有日期的立刻派，有日期的到期后派；任务的标题和备注作为资料附上。结审任务也行：在任务的「编辑任务」里填「本地标签」（只存在拾忆里，不改结审）。")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("闪念贝壳里最近 7 天写的、带这个标签的笔记，会各派一次；笔记正文作为资料附上。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        labeled("提前几天") {
                            Stepper("截止前 \(rule.lead) 天开始派", value: leadBinding, in: 0...30)
                        }
                        Text("结审任务离截止日不到这些天（含已过期还没完成的），各派一次；任务说明作为资料附上。")
                            .font(.caption).foregroundStyle(.secondary)
                    }

                    labeled("谁来做") {
                        if profiles.isEmpty {
                            Text("没有可用的命令行 Agent").foregroundStyle(.secondary)
                        } else {
                            Picker("", selection: $rule.profileId) {
                                ForEach(profiles) { Text($0.name).tag($0.id) }
                            }
                            .labelsHidden().fixedSize()
                        }
                    }
                    labeled("在哪个目录") { dirMenu }
                    labeled("做什么") {
                        TextEditor(text: $rule.prompt)
                            .font(.system(size: 13))
                            .scrollContentBackground(.hidden)
                            .frame(height: 78)
                            .padding(4)
                            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }
                    labeled("权限") {
                        Picker("", selection: accessBinding) {
                            ForEach(AgentAccess.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented).labelsHidden()
                    }
                    labeled("每天最多") {
                        Stepper("\(rule.dailyLimit) 次", value: $rule.dailyLimit, in: 1...20)
                    }
                    labeled("状态") {
                        Toggle("启用这条规则（关闭时不会自动派活）", isOn: $rule.enabled)
                    }
                    if let error { Text(error).font(.caption).foregroundStyle(.red) }
                }
                .padding(18)
            }
            Divider()
            HStack(spacing: 10) {
                if let existing {
                    Button("删除", role: .destructive) {
                        DispatchRuleEngine.shared.remove(existing.id)
                        dismiss()
                    }
                }
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") { save() }.keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
        }
        .frame(width: 500, height: 600)
        .onAppear(perform: load)
    }

    private func labeled<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.secondary)
            content()
        }
    }

    private var dirMenu: some View {
        var dirs: [String] = []
        for d in [rule.cwd] + ocStore.dirs where !d.isEmpty && !dirs.contains(d) { dirs.append(d) }
        return Menu {
            ForEach(dirs, id: \.self) { d in
                Button {
                    rule.cwd = d
                } label: {
                    if d == rule.cwd { Label((d as NSString).lastPathComponent, systemImage: "checkmark") } else { Label((d as NSString).lastPathComponent, systemImage: "folder") }
                }
                .help(d)
            }
            Button("选择文件夹…") { chooseDir() }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "folder").font(.system(size: 11, weight: .semibold))
                Text(rule.cwd.isEmpty ? "选择文件夹" : (rule.cwd as NSString).abbreviatingWithTildeInPath)
                    .lineLimit(1).truncationMode(.middle)
            }
            .frame(maxWidth: 420, alignment: .leading)
        }
        .menuStyle(.button).fixedSize(horizontal: false, vertical: true)
    }

    private func chooseDir() {
        FolderPicker.pick(title: "选择工作目录", start: rule.cwd) { if let p = $0 { rule.cwd = p } }
    }

    /// 「完全放开」要二次确认
    private var accessBinding: Binding<AgentAccess> {
        Binding(
            get: { rule.access },
            set: { new in
                if new == .full, rule.access != .full, !AgentAccess.confirmFull(for: DispatchTarget(rawValue: rule.profileId)?.title ?? "这个 Agent") { return }
                rule.access = new
            }
        )
    }

    private var weekdayBinding: Binding<Int> {
        Binding(get: { rule.weekday ?? 1 }, set: { rule.weekday = $0 })
    }

    private var leadBinding: Binding<Int> {
        Binding(get: { rule.lead }, set: { rule.leadDays = $0 })
    }

    private var timeBinding: Binding<Date> {
        Binding(
            get: {
                let p = rule.time.split(separator: ":").compactMap { Int($0) }
                let (h, m) = p.count == 2 ? (p[0], p[1]) : (9, 0)
                return Calendar.current.date(bySettingHour: h, minute: m, second: 0, of: Date()) ?? Date()
            },
            set: { d in
                let c = Calendar.current.dateComponents([.hour, .minute], from: d)
                rule.time = String(format: "%02d:%02d", c.hour ?? 9, c.minute ?? 0)
            }
        )
    }

    private func load() {
        if let e = existing {
            rule = e
        } else {
            if let preset { rule = preset; rule.id = UUID() }
            // 你亲手新建的规则，保存后就该生效；想暂停再在列表里关掉
            rule.enabled = true
            if rule.profileId.isEmpty { rule.profileId = profiles.first?.id ?? "" }
            if rule.cwd.isEmpty { rule.cwd = UserDefaults.standard.string(forKey: "dispatch.opencode.dir") ?? ocStore.dirs.first ?? "" }
        }
        if !profiles.contains(where: { $0.id == rule.profileId }), existing == nil || rule.profileId.isEmpty {
            rule.profileId = profiles.first?.id ?? ""
        }
        ocStore.refresh(after: 0.3)
    }

    private func save() {
        var r = rule
        r.name = r.name.trimmed
        r.prompt = r.prompt.trimmed
        r.tag = r.tag.trimmingCharacters(in: CharacterSet(charactersIn: "# ").union(.whitespaces))
        guard !r.name.isEmpty else { error = "名称不能为空"; return }
        guard DispatchTarget(rawValue: r.profileId)?.isCommand == true else { error = "选一个可用的命令行 Agent"; return }
        guard !r.cwd.isEmpty else { error = "选一个工作目录"; return }
        guard !r.prompt.isEmpty else { error = "写一下要它做什么"; return }
        if r.isTagged {
            guard !r.tag.isEmpty else { error = "标签不能为空"; return }
            guard r.tag.lowercased() != DispatchRuleEngine.reminderTag.lowercased() else { error = "「\(DispatchRuleEngine.reminderTag)」是复查提醒用的标签，换一个"; return }
        }
        if !r.pickMaterial { r.material = .none }
        if r.trigger == .weekly, r.weekday == nil { r.weekday = 1 }
        if let m = AppModel.current {
            if (r.trigger == .todoTag || r.trigger == .overdue), !m.hasDida { error = "还没连上滴答清单（设置里填口令），这条规则读不到待办"; return }
            if r.trigger == .sjzDue, !m.hasSjz { error = "还没连上结审，这条规则读不到结审任务"; return }
        }
        error = nil
        DispatchRuleEngine.shared.upsert(r)
        dismiss()
    }
}
