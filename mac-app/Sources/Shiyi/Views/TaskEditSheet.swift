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
    @FocusState private var titleFocused: Bool

    init(task: DidaTask) {
        self.task = task
        _title = State(initialValue: task.cleanTitle)
        _content = State(initialValue: task.content)
        _tags = State(initialValue: task.tags.map { "#" + $0 }.joined(separator: " "))
    }

    private var parsedTags: [String] {
        tags.split(whereSeparator: { $0 == " " || $0 == "," || $0 == "，" || $0 == "　" })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "#")) }
            .filter { !$0.isEmpty }
    }

    private var changed: Bool {
        title.trimmed != task.cleanTitle || content != task.content || parsedTags != task.tags
    }

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
            field("标签", hint: "用空格分隔，例如 #经济学 #读书") {
                TextField("#标签", text: $tags).textFieldStyle(.roundedBorder)
            }

            HStack {
                if saving { ProgressView().controlSize(.small) }
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") { save() }
                    .buttonStyle(.borderedProminent).tint(Brand.orange)
                    .keyboardShortcut(.defaultAction)
                    .disabled(title.trimmed.isEmpty || !changed || saving)
            }
        }
        .padding(22)
        .frame(width: 480)
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
        Task {
            await model.edit(task, .details(title: t, content: c, tags: g))
            saving = false
            dismiss()
        }
    }
}
