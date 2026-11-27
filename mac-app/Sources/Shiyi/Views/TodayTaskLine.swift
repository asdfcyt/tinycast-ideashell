import AppKit
import SwiftUI

// MARK: - 一行待办

/// 圆圈 + 标题 + 副标题；悬停时右边出现「专注 / 推迟」（无日期的行是常驻的「定日期」）
struct TaskLine: View {
    @EnvironmentObject var model: AppModel
    let task: DidaTask
    var overdue = false
    var undatedRow = false
    @ObservedObject var focus: FocusStore
    /// 紧凑：标题和副标题排在一行，行高更矮
    var compact = false
    @State private var checked = false
    @State private var hover = false

    private var ring: Color {
        switch task.priority {
        case 5: return .red
        case 3: return .orange
        case 1: return .blue
        default: return Color.secondary
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if overdue, let d = task.date { parts.append("逾期 \(max(1, Day.diff(d, Day.today()))) 天") }
        if let t = task.time { parts.append(t) }
        if let p = model.overview?.projectName(task.projectId) { parts.append(p) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        let done = task.done || checked
        HStack(spacing: 10) {
            Button {
                guard !done else { return }
                withAnimation(.easeOut(duration: 0.2)) { checked = true }
                Task { await model.complete(task) }
            } label: {
                ZStack {
                    Circle().strokeBorder(done ? Color.clear : ring, lineWidth: 1.6)
                    if done {
                        Circle().fill(Color.secondary.opacity(0.55))
                        Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                    }
                }
                .frame(width: compact ? 17 : 20, height: compact ? 17 : 20)
                .frame(width: compact ? 24 : 28, height: compact ? 24 : 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(task.done)

            Group {
                if compact {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(task.cleanTitle).font(.system(size: 13, weight: .medium)).strikethrough(done)
                            .foregroundStyle(done ? .secondary : .primary).lineLimit(1)
                            .layoutPriority(1)
                        if !subtitle.isEmpty {
                            Text(subtitle).font(.caption).foregroundStyle(overdue ? Color.red : Color.secondary).lineLimit(1)
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(task.cleanTitle).font(.body).strikethrough(done)
                            .foregroundStyle(done ? .secondary : .primary).lineLimit(2)
                        if !subtitle.isEmpty {
                            Text(subtitle).font(.caption).foregroundStyle(overdue ? Color.red : Color.secondary).lineLimit(1)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { model.openTask(task) }

            if !done {
                if undatedRow {
                    Menu { ScheduleItems(task: task) } label: { Text("定日期") }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .disabled(model.scheduling)
                } else {
                    HStack(spacing: 2) {
                        Button { startFocus(task, focus) } label: {
                            Image(systemName: "play.circle").font(.system(size: 16)).frame(width: 26, height: 26)
                        }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("专注这件事")
                        .disabled(focus.run != nil)
                        Menu { SnoozeItems(task: task) } label: {
                            Image(systemName: "clock.arrow.circlepath").font(.system(size: 14)).frame(width: 26, height: 26)
                        }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("推迟")
                        .disabled(model.scheduling)
                    }
                    .opacity(hover ? 1 : 0)
                }
            } else if task.done {
                // 已完成的：悬停时出现「恢复为未完成」
                Button { Task { await model.undoComplete(task) } } label: {
                    Image(systemName: "arrow.uturn.backward.circle").font(.system(size: 15)).frame(width: 26, height: 26)
                }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("恢复为未完成")
                .opacity(hover ? 1 : 0)
            }
        }
        .padding(.horizontal, compact ? 16 : 12).padding(.vertical, compact ? 4 : 7)
        .background(hover ? Color.primary.opacity(0.04) : Color.clear)
        .onHover { hover = $0 }
        .contextMenu {
            if let note = model.taskNote(forTask: task) {
                Button("打开任务笔记") { model.openNote(note.noteId, title: note.deliverable) }
            }
            TaskContextMenu(task: task)
        }
    }
}
