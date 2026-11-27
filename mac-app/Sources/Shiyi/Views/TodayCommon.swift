import AppKit
import SwiftUI

// MARK: - 基础部件

struct FlatPanelsKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    /// 平铺：Panel 不画卡片底（右边的仪表盘用）
    var flatPanels: Bool {
        get { self[FlatPanelsKey.self] }
        set { self[FlatPanelsKey.self] = newValue }
    }
}

struct Panel<Content: View>: View {
    var radius: CGFloat = 16
    @ViewBuilder var content: Content
    @Environment(\.flatPanels) private var flat
    var body: some View {
        let v = VStack(alignment: .leading, spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
        if flat { v } else { v.glassCard(radius: radius) }
    }
}

/// 中间一列所有卡片共用的标题行：图标 + 标题 + 数量（左），右边放动作
struct CardHeader<Trailing: View>: View {
    let icon: String
    let title: String
    var count = 0
    var tint: Color = Brand.orange
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(title).foregroundStyle(tint)
            if count > 0 { Text("\(count)").foregroundStyle(.tertiary) }
            Spacer(minLength: 6)
            trailing
        }
        .font(.subheadline.weight(.semibold))
        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 6)
    }
}

/// 卡片里的小分组标题：日常 / 结审
struct GroupLabel: View {
    let title: String
    let count: Int
    let tint: Color

    var body: some View {
        // 和 AI 速览里「先读这几篇」同一种小标题：11 号粗体、灰色、字距拉开
        HStack(spacing: 6) {
            Text(title).tracking(1.2)
            Text("\(count)").foregroundStyle(.tertiary).monospacedDigit()
        }
        .font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary)
        .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 4)
    }
}

/// 一张卡：标题行 + 分隔线隔开的列表
struct TaskSection<Trailing: View, Rows: View>: View {
    let title: String
    let count: Int
    var icon = "checklist"
    var tint: Color = Brand.orange
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Rows

    var body: some View {
        Panel {
            CardHeader(icon: icon, title: title, count: count, tint: tint) { trailing }
            content
            // 最后一行和卡片下沿留点空
            Color.clear.frame(height: 8)
        }
    }
}

/// 「推迟到…」菜单项（单条）
struct SnoozeItems: View {
    @EnvironmentObject var model: AppModel
    let task: DidaTask
    var body: some View {
        ForEach(SnoozeOption.allCases) { o in
            Button { Task { await model.snooze(task, o) } } label: { Label(o.label, systemImage: o.icon) }
        }
    }
}

/// 「定日期」菜单项（无日期的任务）
struct ScheduleItems: View {
    @EnvironmentObject var model: AppModel
    let task: DidaTask
    var body: some View {
        let today = Day.today()
        Button("今天") { Task { await model.schedule(task, on: today) } }
        Button("明天") { Task { await model.schedule(task, on: Day.add(today, days: 1)) } }
        Button("本周末") { Task { await model.schedule(task, on: Scheduler.nextSaturday(from: today)) } }
        Button("下周一") { Task { await model.schedule(task, on: Scheduler.nextMonday(from: today)) } }
    }
}

@MainActor func startFocus(_ task: DidaTask, _ focus: FocusStore) {
    guard focus.run == nil else { return }
    focus.task = task
    focus.quickFocus(focus.focusMinutes)
}

// MARK: - 标题栏：开始专注

/// 「快速启动」右边的开始专注：点一下按上次的时长开始，右边小箭头选 15 / 25 / 45 / 60 / 90 分钟；
/// 刚完成一个番茄、该休息时，主按钮是「休息 N 分」，菜单里可以跳过休息直接专注
/// 标题栏按钮：和侧栏卡片一样的玻璃底、圆角 12
struct GlassActionStyle: ButtonStyle {
    var tint: Color = .primary
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 12).frame(height: 28)
            .glassCard(radius: 12)
            .opacity(enabled ? (configuration.isPressed ? 0.6 : 1) : 0.45)
            .contentShape(Rectangle())
    }
}
