import SwiftUI

/// 完成任务后的短暂「撤销」提示
struct UndoToast: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if let t = model.lastUndo {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("已完成「\(t.cleanTitle)」").lineLimit(1)
                Button("撤销") { Task { await model.undoComplete(t) } }.buttonStyle(.link)
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .glassCapsule()
            .shadow(radius: 6, y: 2)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}
