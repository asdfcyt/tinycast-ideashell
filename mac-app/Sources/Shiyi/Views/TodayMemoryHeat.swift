import AppKit
import SwiftUI

// MARK: - 往日回顾

struct MemoryPanel: View {
    @EnvironmentObject var model: AppModel
    let items: [MemoryItem]

    var body: some View {
        Panel {
            CardHeader(icon: "clock.arrow.circlepath", title: "往日回顾") { EmptyView() }
            ForEach(Array(items.enumerated()), id: \.element.id) { i, m in
                Button { model.openNote(m.note.id, title: m.note.title) } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(m.label).font(.caption.weight(.bold)).foregroundStyle(Brand.orange)
                            Text(String(m.date.dropFirst(5))).font(.caption).foregroundStyle(.tertiary).monospacedDigit()
                        }
                        Text(m.note.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.primary).lineLimit(1)
                        if let s = m.note.summary?.trimmed, !s.isEmpty {
                            Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.leading)
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if i < items.count - 1 { Divider().padding(.leading, 16) }
            }
        }
    }
}

// MARK: - 侧栏：Daily Note 热力图

struct HeatPanel: View {
    @EnvironmentObject var model: AppModel
    let weeks: Int

    /// 今天页上任何数据变化都会重算这里的 body：只负责把输入交给 HeatGrid，输入没变就整块跳过（不再每次重算 180 天的日期字符串、重画画布）
    var body: some View {
        HeatGrid(weeks: weeks, counts: model.heat, loading: model.heatLoading, today: Day.today()).equatable()
    }
}

struct HeatGrid: View, Equatable {
    let weeks: Int
    let counts: [String: Int]
    let loading: Bool
    /// 今天（跨天后重算）
    let today: String

    private func metrics(_ w: CGFloat) -> (cell: CGFloat, gap: CGFloat) {
        let n = CGFloat(weeks)
        let cell = min((w - (n - 1) * 3) / n, 20)
        return (cell, max((w - n * cell) / (n - 1), 3))
    }

    private func level(_ i: Int) -> Color {
        [Brand.orange.opacity(0.28), Brand.orange.opacity(0.55), Brand.orange, Brand.orangeDeep][i]
    }

    var body: some View {
        let r = AppModel.heatRange(weeks: weeks)
        let cal = Day.cal
        let days = (0 ..< weeks * 7).map { cal.date(byAdding: .day, value: $0, to: r.first) ?? r.first }
        // 每一天的日期字符串只格式化一次（下面统计和画布都用它）
        let keys = days.map { Day.string($0) }
        let vals = keys.compactMap { counts[$0] }.filter { $0 > 0 }.sorted()
        let at: (Double) -> Int = { q in vals.isEmpty ? 1 : vals[Int(Double(vals.count - 1) * q)] }
        // 档位按「有记录的日子」的条数分布来切（前 25% / 50% / 80%），记得多的人不会满屏深色
        let cuts = [at(0.25), at(0.5), at(0.8)]
        let total = keys.reduce(0) { $0 + (counts[$1] ?? 0) }
        let month = cal.component(.month, from: r.last)
        let monthDays = keys.indices.filter { i in
            cal.component(.month, from: days[i]) == month && keys[i] <= today && (counts[keys[i]] ?? 0) > 0
        }.count

        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Daily Note · 最近 \(weeks) 周").font(.subheadline.weight(.bold)).foregroundStyle(.secondary)
                Spacer(minLength: 6)
                Text(loading && counts.isEmpty ? "正在读取…" : "本月 \(monthDays) 天")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary).help("共 \(total) 条")
            }
            Group {
                VStack(alignment: .leading, spacing: 6) {
                    Canvas { ctx, size in
                        let (cell, gap) = metrics(size.width)
                        var prev = -1
                        var marks: [(Int, Int)] = []
                        for w in 0 ..< weeks {
                            let m = cal.component(.month, from: cal.date(byAdding: .weekOfYear, value: w, to: r.first) ?? r.first)
                            if m != prev { marks.append((w, m)) }
                            prev = m
                        }
                        if marks.count > 1, marks[1].0 < 3 { marks.removeFirst() }
                        for (w, m) in marks {
                            ctx.draw(Text("\(m)月").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary),
                                     at: CGPoint(x: CGFloat(w) * (cell + gap), y: 6), anchor: .leading)
                        }
                    }
                    .frame(height: 12)
                    Canvas { ctx, size in
                        let (cell, gap) = metrics(size.width)
                        for w in 0 ..< weeks {
                            for d in 0 ..< 7 {
                                let key = keys[w * 7 + d]
                                if key > today { continue }
                                let n = counts[key] ?? 0
                                let color: Color = n <= 0 ? Color.primary.opacity(0.07)
                                    : (n <= cuts[0] ? level(0) : (n <= cuts[1] ? level(1) : (n <= cuts[2] ? level(2) : level(3))))
                                let rect = CGRect(x: CGFloat(w) * (cell + gap), y: CGFloat(d) * (cell + gap), width: cell, height: cell)
                                ctx.fill(Path(roundedRect: rect, cornerRadius: cell * 0.3), with: .color(color))
                            }
                        }
                    }
                    .aspectRatio(CGFloat(weeks) / 7.0, contentMode: .fit)
                }
            }
        }
        .padding(16)
    }
}
