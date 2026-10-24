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
