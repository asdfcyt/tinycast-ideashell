import SwiftUI

/// 编辑任务：标题、备注、标签。日期 / 优先级 / 清单 / 项目在详情页上方的小胶囊里改。
struct TaskEditSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let task: DidaTask

    @State private var title: String
    @State private var content: String
    @State private var tags: String
    @State private var saving = false
    @State private var startStr: String
    @State private var phaseKey: String
    @State private var dueStr: String
    @FocusState private var titleFocused: Bool

    init(task: DidaTask) {
        self.task = task
        _title = State(initialValue: task.cleanTitle)
        _content = State(initialValue: task.content)
        _tags = State(initialValue: task.tags.map { "#" + $0 }.joined(separator: " "))
        _startStr = State(initialValue: task.startDate ?? "")
        _phaseKey = State(initialValue: task.phase ?? "")
        _dueStr = State(initialValue: task.date ?? "")
    }

    private var parsedTags: [String] {
        tags.split(whereSeparator: { $0 == " " || $0 == "," || $0 == "，" || $0 == "　" })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "#")) }
            .filter { !$0.isEmpty }
    }

    private var changed: Bool {
        title.trimmed != task.cleanTitle || content != task.content || parsedTags != task.tags || startChanged || dueChanged || phaseChanged
    }

    private var isSjz: Bool { SjzTasks.owns(task.id) }
    private var newStart: String? { startStr.isEmpty ? nil : startStr }
    private var startChanged: Bool { isSjz && newStart != task.startDate }
    private var dueChanged: Bool { isSjz && dueStr != (task.date ?? "") }
    private var phaseChanged: Bool { isSjz && !phaseKey.isEmpty && phaseKey != (task.phase ?? "") }
    private static let phases: [(String, String)] = [("preparation", "审前准备"), ("implementation", "审计实施"), ("reporting", "报告与处理"), ("rectification", "整改跟踪")]
    private var datesInvalid: Bool { isSjz && !startStr.isEmpty && !dueStr.isEmpty && startStr > dueStr }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "square.and.pencil").foregroundStyle(Brand.orange)
                Text("编辑任务").font(.title3.weight(.bold))
            }

            field("标题") {
                TextField("任务标题", text: $title).textFieldStyle(.roundedBorder).focused($titleFocused)
            }
            field("备注") {
                TextEditor(text: $content)
                    .font(.body).scrollContentBackground(.hidden)
                    .frame(minHeight: 110, maxHeight: 220)
                    .padding(8)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
            }
            if isSjz {
                field("计划日期", hint: "开始日和截止日决定结审甘特图里这条任务的横条") {
                    HStack(spacing: 14) {
                        DayPickerButton(title: "开始", icon: "flag", value: $startStr)
                        DayPickerButton(title: "截止", icon: "calendar", value: $dueStr)
                        if datesInvalid { Text("开始日晚于截止日").font(.caption).foregroundStyle(.red) }
                        Spacer()
                    }
                }
                field("所属阶段", hint: "默认是项目当前所处的阶段，结审甘特图按它分组") {
                    HStack(spacing: 6) {
                        ForEach(Self.phases, id: \.0) { key, label in
                            Button { phaseKey = key } label: {
                                Text(label).font(.caption.weight(.medium))
                                    .foregroundStyle(phaseKey == key ? Color.white : Color.secondary)
                                    .padding(.horizontal, 10).padding(.vertical, 4)
                                    .background(phaseKey == key ? Brand.orange : Color.primary.opacity(0.06), in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                        Spacer()
                    }
                }
            } else {
                field("标签", hint: "用空格分隔，例如 #经济学 #读书") {
                    TextField("#标签", text: $tags).textFieldStyle(.roundedBorder)
                }
            }

            HStack {
                if saving { ProgressView().controlSize(.small) }
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") { save() }
                    .buttonStyle(.borderedProminent).tint(Brand.orange)
                    .keyboardShortcut(.defaultAction)
                    .disabled(title.trimmed.isEmpty || !changed || saving || datesInvalid)
            }
        }
        .padding(22)
        .frame(minWidth: 480, idealWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
        .sheetWindowTweaks()
        .onAppear { titleFocused = true }
    }

    private func field<C: View>(_ name: String, hint: String? = nil, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(name).font(.callout.weight(.semibold))
                if let hint { Text(hint).font(.caption).foregroundStyle(.tertiary) }
            }
            content()
        }
    }

    private func save() {
        saving = true
        let t = title.trimmed, c = content, g = parsedTags
        let start = newStart, startChanged = startChanged, dueChanged = dueChanged, phaseChanged = phaseChanged, phase = phaseKey, due = dueStr, textChanged = t != task.cleanTitle || c != task.content || g != task.tags
        Task {
            if textChanged || !isSjz { await model.edit(task, .details(title: t, content: c, tags: g)) }
            if startChanged { await model.edit(task, .startDate(start)) }
            if phaseChanged { await model.edit(task, .phase(phase)) }
            if dueChanged { await model.edit(task, due.isEmpty ? .clearDate : .schedule(date: due, time: nil)) }
            saving = false
            dismiss()
        }
    }
}
