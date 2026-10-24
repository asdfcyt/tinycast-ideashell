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
        VStack(spacing: 8) {
            HStack(spacing: 2) {
                Text(title).font(.system(size: 15, weight: .semibold))
                Spacer(minLength: 4)
                nav("chevron.left") { shift(-1) }
                Button { month = Date(); selection = Day.startOfDay(Date()) } label: {
                    Text("今天").font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.primary.opacity(0.07), in: Capsule())
                }
                .buttonStyle(.plain)
                nav("chevron.right") { shift(1) }
            }
            HStack(spacing: 0) {
                ForEach(heads, id: \.self) { h in
                    Text(h).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                }
            }
            LazyVGrid(columns: columns, spacing: 2) {
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
            if on { Circle().fill(Brand.orange).frame(width: 30, height: 30) }
            Text("\(Day.cal.component(.day, from: d))")
                .font(.system(size: 14, weight: on || isToday ? .bold : .regular)).monospacedDigit()
                .foregroundStyle(on ? Color.white : (isToday ? Color.red : (inMonth ? Color.primary : Color.secondary.opacity(0.4))))
        }
        .frame(height: 34)
        .contentShape(Rectangle())
        .onTapGesture {
            selection = d
            if !inMonth { month = d }
        }
    }

    private func nav(_ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                .frame(width: 24, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func shift(_ n: Int) {
        month = Day.cal.date(byAdding: .month, value: n, to: month) ?? month
    }
}
