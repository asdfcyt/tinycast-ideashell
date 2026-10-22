import SwiftUI

/// 专注中的「记录」输入框（参考安卓端通知上的「记录」面板）：
/// 有绑定待办 → 写进任务笔记的「进展记录」并同步成滴答评论；没绑定 → 记到今天的 Daily Note。
/// 写到一半关掉，文字留在 `focus.recordDraft` 里，下次打开自动放回来。
struct RecordComposer: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var focus: FocusStore
    var compact = false
    var onClose: (() -> Void)?

    @FocusState private var focused: Bool

    private var canSend: Bool { !focus.recordDraft.trimmed.isEmpty && !model.recording }

    private var target: String {
        guard let r = focus.run else { return "" }
        if r.taskId == nil { return "没有关联待办：记到今天的 Daily Note" }
        return "记到任务笔记「\(r.title)」的进展记录，并同步成滴答评论"
    }

    private func send() {
        let t = focus.recordDraft.trimmed
        guard !t.isEmpty else { return }
        focus.recordDraft = ""
        Task { await model.recordFocus(t) }
        onClose?()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(target).font(.caption).foregroundStyle(.secondary).lineLimit(compact ? 2 : 1)
                Spacer(minLength: 0)
                if model.recording { ProgressView().controlSize(.small) }
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("专注时的想法、进展、卡点…", text: $focus.recordDraft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(compact ? 1 ... 3 : 2 ... 5)
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .focused($focused)
                    .onSubmit(send)
                Button(action: send) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(canSend ? Brand.orange : Color.secondary.opacity(0.35), in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .keyboardShortcut(.return, modifiers: .command)
                .help("记录（⌘↩）")
            }
        }
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { focused = true } }
    }
}
