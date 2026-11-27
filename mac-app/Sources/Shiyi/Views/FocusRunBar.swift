import AppKit
import SwiftUI

// MARK: - 专注进行条（今天页和菜单栏共用）

struct FocusRunBar: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var focus: FocusStore
    @ObservedObject private var session = BreakSession.shared
    @ObservedObject private var music = BreakSession.shared.music
    @ObservedObject private var sound = AmbientSound.shared
    @State private var writing = false

    var body: some View {
        if let r = focus.run {
            VStack(spacing: 10) {
                // 第一行：图标 + 关联的任务（点一下可以换）+ 倒计时
                HStack(spacing: 8) {
                    // 休息时图标和休息页上当前的动作保持一致
                    Image(systemName: r.paused ? "pause.circle.fill" : (r.kind.isBreak ? session.move(for: focus).icon : "timer"))
                        .font(.title3).foregroundStyle(Brand.orange)
                    titleBlock(r)
                    if r.kind.isBreak { breakChips }
                    Spacer(minLength: 4)
                    FocusTick(clock: focus.clock) { now in
                        let left = max(Int(r.remainingMs(now) / 1000), 0)
                        Text(String(format: "%02d:%02d", left / 60, left % 60))
                            .font(.system(size: 24, weight: .semibold).monospacedDigit())
                            .lineLimit(1).fixedSize()
                    }
                }
                // 第二行：按钮平分整行宽度，窄的地方也不会被挤掉
                HStack(spacing: 8) {
                    if !r.kind.isBreak {
                        pill("square.and.pencil", "记录", on: writing) { writing.toggle() }
                    }
                    pill(r.paused ? "play.fill" : "pause.fill", r.paused ? "继续" : "暂停") { focus.pauseOrResume() }
                    pill("stop.fill", r.kind.isBreak ? "结束休息" : "结束", filled: true) { Task { await focus.finish() } }
                }
                if writing, !r.kind.isBreak {
                    RecordComposer(focus: focus, compact: true) { writing = false }
                }
            }
        }
    }

    private func titleBlock(_ r: FocusRun) -> some View {
        let name = r.kind.isBreak ? r.kind.label : (r.title.isEmpty ? "自由专注" : r.title)
        let status = r.paused ? "已暂停" : (r.kind.isBreak ? "休息中" : (r.title.isEmpty ? "点一下关联待办" : "专注中"))
        let block = VStack(alignment: .leading, spacing: 1) {
            Text(name).font(.callout.weight(.semibold)).lineLimit(1)
            Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        return Group {
            if r.kind.isBreak {
                // 休息：名字后面紧跟着跟练 / 歌 / 环境音的状态，右边留给倒计时
                block.layoutPriority(1)
            } else {
                FocusTaskMenu(focus: focus) {
                    HStack(spacing: 4) {
                        block
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 9)).foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// 休息中的状态：跟练倒计时、正在播放的歌、环境音。点一下可以停 / 暂停
    @ViewBuilder private var breakChips: some View {
        HStack(spacing: 5) {
            if let end = session.practiceEnd {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    let left = Int(end.timeIntervalSince(ctx.date).rounded(.up))
                    if left > 0 {
                        chip(session.move(for: focus).icon, String(format: "%d:%02d", left / 60, left % 60), help: "跟练中，点一下停止") {
                            session.practiceEnd = nil
                        }
                    }
                }
            }
            if let t = music.track, t.playing {
                chip("music.note", t.title, help: "\(t.title) · \(t.artist)，点一下暂停") { music.toggle(t.app) }
                    .frame(maxWidth: 96)
            }
            if let k = sound.current {
                chip(k.icon, nil, help: "\(k.label)，点一下关闭") { sound.stop() }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func chip(_ icon: String, _ text: String?, help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 10, weight: .semibold))
                if let text { Text(text).font(.system(size: 11, weight: .medium)).monospacedDigit().lineLimit(1) }
            }
            .foregroundStyle(Brand.orange)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Brand.orange.opacity(0.16), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func pill(_ icon: String, _ text: String, on: Bool = false, filled: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(text, systemImage: icon)
                .font(.callout.weight(.medium))
                .foregroundStyle(filled ? Brand.brown : (on ? Brand.orange : Color.primary))
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(filled ? Brand.orange : (on ? Brand.orange.opacity(0.16) : Color.primary.opacity(0.07)), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// 选择专注关联的待办：今天的 + 逾期的；没在专注时是「下一次专注」关联谁，专注中直接换
struct FocusTaskMenu<MenuLabel: View>: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var focus: FocusStore
    @ViewBuilder var label: MenuLabel

    var body: some View {
        let ov = model.overview
        let today = (ov?.todayTasks() ?? []).sorted { ($0.time ?? "99:99") < ($1.time ?? "99:99") }
        let late = (ov?.overdue ?? []).sorted { ($0.date ?? "") < ($1.date ?? "") }
        let current = focus.run?.taskId ?? focus.task?.id
        let todayStr = Day.today()
        let sjzLater = ((ov?.upcoming ?? []) + (ov?.undated ?? [])).filter { SjzTasks.owns($0.id) && ($0.date == nil || ($0.date ?? "") > todayStr) }
            .sorted { ($0.date ?? "9999") < ($1.date ?? "9999") }
        Menu {
            Button { focus.attach(nil) } label: {
                Label("不关联待办", systemImage: current == nil ? "checkmark" : "circle.dashed")
            }
            if !today.isEmpty {
                Section("今天") {
                    ForEach(today.prefix(20)) { t in
                        Button { focus.attach(t) } label: {
                            if current == t.id { Label(t.cleanTitle, systemImage: "checkmark") } else { Text(t.cleanTitle) }
                        }
                    }
                }
            }
            if !late.isEmpty {
                Section("逾期") {
                    ForEach(late.prefix(12)) { t in
                        Button { focus.attach(t) } label: {
                            if current == t.id { Label(t.cleanTitle, systemImage: "checkmark") } else { Text(t.cleanTitle) }
                        }
                    }
                }
            }
            // 结审里还没排到今天的任务（无日期 / 以后到期）
            if !sjzLater.isEmpty {
                Section("结审") {
                    ForEach(sjzLater.prefix(12)) { t in
                        Button { focus.attach(t) } label: {
                            if current == t.id { Label(t.cleanTitle, systemImage: "checkmark") } else { Text(t.cleanTitle) }
                        }
                    }
                }
            }
        } label: { label }
        .menuStyle(.borderlessButton).menuIndicator(.hidden)
    }
}
