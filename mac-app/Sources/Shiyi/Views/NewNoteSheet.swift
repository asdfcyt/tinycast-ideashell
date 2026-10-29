import SwiftUI

/// 从一条内容新建笔记：这条内容作为标题，正文自己写
struct NewNoteDraft: Identifiable {
    let id = UUID()
    var title: String
}

struct NewNoteSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var title: String
    @State private var content = ""
    @State private var saving = false
    @State private var error: String?
    @FocusState private var bodyFocused: Bool

    init(draft: NewNoteDraft) {
        _title = State(initialValue: draft.title.replacingOccurrences(of: "\n", with: " ").trimmed)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "square.and.pencil").foregroundStyle(Brand.orange)
                Text("新建笔记").font(.title3.weight(.bold))
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("标题").font(.callout.weight(.semibold))
                TextField("笔记标题", text: $title).textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("正文").font(.callout.weight(.semibold))
                TextEditor(text: $content)
                    .font(.body).scrollContentBackground(.hidden)
                    .focused($bodyFocused)
                    .frame(minHeight: 150, maxHeight: 280)
                    .padding(8)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }

            HStack {
                if saving { ProgressView().controlSize(.small) }
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") { save() }
                    .buttonStyle(.borderedProminent).tint(Brand.orange)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(title.trimmed.isEmpty || saving)
                    .help("⌘↩ 保存")
            }
        }
        .padding(22)
        .frame(minWidth: 480, idealWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { bodyFocused = true }
    }

    private func save() {
        saving = true
        error = nil
        let t = title.trimmed, b = content.trimmed
        Task {
            do {
                _ = try await model.ideashell.createNote(title: t, body: b, tags: [])
                model.invalidateHistory()
                model.showNotice("已新建笔记「" + String(t.prefix(20)) + "」")
                dismiss()
                await model.loadTimeline(silent: true)
            } catch {
                saving = false
                self.error = "保存失败：" + error.localizedDescription
            }
        }
    }
}
