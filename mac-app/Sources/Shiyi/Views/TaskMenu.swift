import SwiftUI

/// 待办的右键菜单：日历、待办列表、今天页共用。改期 / 优先级走 `model.edit`（界面先动，再写滴答）
struct TaskContextMenu: View {
    @EnvironmentObject var model: AppModel
    let task: DidaTask

    private var t: DidaTask { model.localTask(task.id) ?? task }

    private var nextMonday: String {
        let today = Day.today()
        let wd = Day.cal.component(.weekday, from: Day.parse(today) ?? Date())  // 1 = 周日
        let n = (9 - wd) % 7
        return Day.add(today, days: n == 0 ? 7 : n)
    }

    var body: some View {
        let t = self.t
        Button("查看详情") { model.openTask(t) }
        Button("编辑任务…") { model.editTask(t) }
        if t.done {
            Button("恢复为未完成") { Task { await model.undoComplete(t) } }
        } else {
            Button("完成") { Task { await model.complete(t) } }
            Button {
                model.focus.attach(t)
                model.focus.quickFocus(model.focus.focusMinutes)
            } label: {
                Label("开始专注", systemImage: "play.fill")
            }
            .disabled(model.focus.run != nil)
            Menu("改期") {
                ForEach([("今天", 0), ("明天", 1), ("后天", 2)], id: \.0) { label, n in
                    Button(label) { move(t, to: Day.add(Day.today(), days: n)) }
                }
                Button("下周一") { move(t, to: nextMonday) }
                if t.date != nil {
                    Divider()
                    Button("清除日期") { Task { await model.edit(t, .clearDate) } }
                }
            }
            Menu("优先级") {
                ForEach([("无", 0), ("低", 1), ("中", 3), ("高", 5)], id: \.1) { label, p in
                    Button {
                        if t.priority != p { Task { await model.edit(t, .priority(p)) } }
                    } label: {
                        if t.priority == p { Label(label, systemImage: "checkmark") } else { Text(label) }
                    }
                }
            }
        }
        Divider()
        Button("在滴答清单中打开") { model.open(didaTaskURL(t.projectId, t.id)) }
        Button("复制标题") { model.copy(t.cleanTitle) }
        Divider()
        Button("删除…", role: .destructive) { model.requestDelete(.task(t)) }
    }

    private func move(_ t: DidaTask, to day: String) {
        if t.date == day { return }
        Task { await model.edit(t, .schedule(date: day, time: t.time)) }
    }
}
