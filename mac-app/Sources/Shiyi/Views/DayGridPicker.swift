import SwiftUI

/// 选日期的月历：宽度由外面决定、格子铺满（系统自带的图形化 DatePicker 是固定宽度，放进宽一点的弹层右边会空一大块）。
/// 周一在最前，和「日历」页一致；选中日是橙色圆，今天的数字是红色。
struct DayGridPicker: View {
    @Binding var selection: Date
    @State private var month: Date

    private let heads = ["一", "二", "三", "四", "五", "六", "日"]
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)

    init(selection: Binding<Date>) {
        _selection = selection
        _month = State(initialValue: selection.wrappedValue)
    }

    private var title: String {
        let c = Day.cal.dateComponents([.year, .month], from: month)
        return "\(c.year ?? 0)年\(c.month ?? 0)月"
    }

    var body: some View {
        let today = Day.today()
        let picked = Day.string(selection)
        VStack(spacing: 4) {
            HStack(spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 4)
                nav("chevron.left") { shift(-1) }
                Button { month = Date(); selection = Day.startOfDay(Date()) } label: {
                    Text("今天").font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Color.primary.opacity(0.07), in: Capsule())
                }
                .buttonStyle(.plain)
                nav("chevron.right") { shift(1) }
            }
            HStack(spacing: 0) {
                ForEach(heads, id: \.self) { h in
                    Text(h).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                }
            }
            LazyVGrid(columns: columns, spacing: 0) {
                ForEach(AppModel.calendarGrid(for: month), id: \.self) { day in cell(day, today: today, picked: picked) }
            }
        }
    }

    private func cell(_ day: String, today: String, picked: String) -> some View {
        let d = Day.parse(day) ?? Date()
        let inMonth = Day.cal.isDate(d, equalTo: month, toGranularity: .month)
        let on = day == picked
        let isToday = day == today
        return ZStack {
            if on { Circle().fill(Brand.orange).frame(width: 24, height: 24) }
            Text("\(Day.cal.component(.day, from: d))")
                .font(.system(size: 12, weight: on || isToday ? .bold : .regular)).monospacedDigit()
                .foregroundStyle(on ? Color.white : (isToday ? Color.red : (inMonth ? Color.primary : Color.secondary.opacity(0.4))))
        }
        .frame(height: 26)
        .contentShape(Rectangle())
        .onTapGesture {
            selection = d
            if !inMonth { month = d }
        }
    }

    private func nav(_ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                .frame(width: 22, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func shift(_ n: Int) {
        month = Day.cal.date(byAdding: .month, value: n, to: month) ?? month
    }
}

/// 时间选择（时 : 分）。系统的 DatePicker(.hourAndMinute) 在弹层刚打开时是空白的，这里用两个菜单自己做。
struct TimeField: View {
    @Binding var time: Date

    private var hour: Int { Day.cal.component(.hour, from: time) }
    private var minute: Int { Day.cal.component(.minute, from: time) }

    private var minutes: [Int] { Array(Set(Array(stride(from: 0, to: 60, by: 5)) + [minute])).sorted() }

    private func set(hour h: Int? = nil, minute m: Int? = nil) {
        time = Day.cal.date(bySettingHour: h ?? hour, minute: m ?? minute, second: 0, of: time) ?? time
    }

    var body: some View {
        HStack(spacing: 2) {
            Menu {
                ForEach(0 ..< 24, id: \.self) { h in Button(String(format: "%02d", h)) { set(hour: h) } }
            } label: { Text(String(format: "%02d", hour)).frame(width: 24) }
            Text(":").foregroundStyle(.secondary)
            Menu {
                ForEach(minutes, id: \.self) { m in Button(String(format: "%02d", m)) { set(minute: m) } }
            } label: { Text(String(format: "%02d", minute)).frame(width: 24) }
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden)
        .font(.system(size: 14, weight: .medium)).monospacedDigit()
        .fixedSize()
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

/// 任务的「日期 + 具体时间」弹层：月历、快捷日期、时间开关、时分选择。
/// 日期 / 时间的状态全部在这个视图自己里面，开关一拨时间那一行就跟着出现。
struct TaskDatePopover: View {
    @EnvironmentObject var model: AppModel
    let task: DidaTask
    let onClose: () -> Void

    @State private var date: Date
    @State private var hasTime: Bool
    @State private var time: Date

    init(task: DidaTask, onClose: @escaping () -> Void) {
        self.task = task
        self.onClose = onClose
        _date = State(initialValue: task.date.flatMap(Day.parse) ?? Date())
        var h = 9, m = 0
        if let t = task.time {
            let p = t.split(separator: ":").compactMap { Int($0) }
            h = p.first ?? 9
            m = p.count > 1 ? p[1] : 0
        }
        _hasTime = State(initialValue: task.time != nil)
        _time = State(initialValue: Day.cal.date(bySettingHour: h, minute: m, second: 0, of: Date()) ?? Date())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            DayGridPicker(selection: $date)
            HStack(spacing: 8) {
                quick("今天", 0)
                quick("明天", 1)
                quick("后天", 2)
                quick("下周", 7)
            }
            Divider()
            HStack(spacing: 8) {
                Label("具体时间", systemImage: "clock").font(.callout)
                Spacer(minLength: 4)
                // 始终显示；没打开开关时变灰、不能点
                TimeField(time: $time)
                    .opacity(hasTime ? 1 : 0.35)
                    .allowsHitTesting(hasTime)
                Toggle("", isOn: $hasTime).toggleStyle(.switch).labelsHidden().controlSize(.small)
            }
            Divider()
            HStack {
                if task.date != nil {
                    Button("清除日期", role: .destructive) {
                        onClose()
                        Task { await model.edit(task, .clearDate) }
                    }
                }
                Spacer()
                Button("取消") { onClose() }
                Button("确定") {
                    onClose()
                    let c = Day.cal.dateComponents([.hour, .minute], from: time)
                    let t = hasTime ? String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0) : nil
                    Task { await model.edit(task, .schedule(date: Day.string(date), time: t)) }
                }
                .buttonStyle(.borderedProminent).tint(Brand.orange)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14).frame(width: 288)
    }

    private func quick(_ label: String, _ days: Int) -> some View {
        Button { date = Day.parse(Day.add(Day.today(), days: days)) ?? Date() } label: {
            Text(label).frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered).controlSize(.small)
    }
}
