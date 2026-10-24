import SwiftUI

/// 侧边栏底部的小月历（版式参考系统「提醒事项」）：今天是红圆，有未完成待办的日子下面一个小点；
/// 点某一天 → 跳到「日历」页的那一天。
struct MiniCalendar: View {
    @EnvironmentObject var model: AppModel
    @State private var month = Day.startOfDay(Date())

    private let heads = ["一", "二", "三", "四", "五", "六", "日"]
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)

    private var title: String {
        let c = Day.cal.dateComponents([.year, .month], from: month)
        return "\(c.year ?? 0)年\(c.month ?? 0)月"
    }

    /// 有未完成待办的日子
    private var busyDays: Set<String> {
        var out = Set<String>()
        if let ov = model.overview {
            for t in ov.overdue + ov.upcoming { if let d = t.date { out.insert(d) } }
        }
        for t in model.calendarTasks.values where !t.done { if let d = t.date { out.insert(d) } }
        return out
    }

    var body: some View {
        let busy = busyDays
        let today = Day.today()
        VStack(spacing: 6) {
            HStack(spacing: 4) {
                Text(title).font(.system(size: 12.5, weight: .semibold))
                Spacer(minLength: 4)
                step("chevron.left", "上个月") { shift(-1) }
                Button {
                    month = Day.startOfDay(Date())
                    model.section = .calendar
                    model.selectCalendarDay(Day.today(), mode: .day)
                } label: {
                    Circle().strokeBorder(Color.secondary, lineWidth: 1.4).frame(width: 8, height: 8)
                        .frame(width: 20, height: 20).contentShape(Rectangle())
                }
                .buttonStyle(.plain).help("回到今天")
                step("chevron.right", "下个月") { shift(1) }
            }
            HStack(spacing: 0) {
                ForEach(heads, id: \.self) { h in
                    Text(h).font(.system(size: 10, weight: .medium)).foregroundStyle(.tertiary).frame(maxWidth: .infinity)
                }
            }
            LazyVGrid(columns: columns, spacing: 1) {
                ForEach(AppModel.calendarGrid(for: month), id: \.self) { day in cell(day, today: today, busy: busy.contains(day)) }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 9)
        .padding(.horizontal, 8).padding(.bottom, 8)
        .onChange(of: model.calendarDay) {
            // 日历页里翻到了别的月份：小月历跟着走
            if let d = Day.parse(model.calendarDay), !Day.cal.isDate(d, equalTo: month, toGranularity: .month) { month = d }
        }
    }

    private func cell(_ day: String, today: String, busy: Bool) -> some View {
        let d = Day.parse(day) ?? Date()
        let inMonth = Day.cal.isDate(d, equalTo: month, toGranularity: .month)
        let isToday = day == today
        let selected = model.section == .calendar && model.calendarDay == day
        return ZStack {
            if isToday {
                Circle().fill(Color.red).frame(width: 21, height: 21)
            } else if selected {
                Circle().fill(Color.primary.opacity(0.14)).frame(width: 21, height: 21)
            }
            Text("\(Day.cal.component(.day, from: d))")
                .font(.system(size: 11.5, weight: isToday ? .bold : .regular)).monospacedDigit()
                .foregroundStyle(isToday ? Color.white : (inMonth ? Color.primary : Color.secondary.opacity(0.4)))
        }
        .overlay(alignment: .bottom) {
            if busy && inMonth {
                Circle().fill(isToday ? Color.white : Brand.orange).frame(width: 3, height: 3).offset(y: 1)
            }
        }
        .frame(height: 24)
        .contentShape(Rectangle())
        .onTapGesture {
            model.section = .calendar
            model.selectCalendarDay(day, mode: .day)
        }
    }

    private func step(_ icon: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
                .frame(width: 20, height: 20).contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(help)
    }

    private func shift(_ n: Int) {
        month = Day.cal.date(byAdding: .month, value: n, to: month) ?? month
    }
}
