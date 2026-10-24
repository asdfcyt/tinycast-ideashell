import SwiftUI

/// 小票收集墙：每完成一个番茄的小票按日期收在这里（最近 100 张），放在项目列表下面。
/// 每张是一张带齿孔缺口的小票：上半是时长，下半是任务和时间；点一下弹出完整小票，可以保存成图片或复制。
struct TicketWall: View {
    @ObservedObject var focus: FocusStore
    @State private var opened: UUID?

    private let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]

    private var cards: [Celebration] {
        var items = TicketStore.shared.items
        if let r = focus.receipt, !items.contains(where: { $0.id == r.id }) { items.append(r) }
        return items.reversed()
    }

    private struct DayGroup: Identifiable {
        let day: String
        let items: [Celebration]
        var id: String { day }
        var minutes: Int { items.reduce(0) { $0 + $1.minutes } }
    }

    private var groups: [DayGroup] {
        var order: [String] = []
        var map: [String: [Celebration]] = [:]
        for c in cards {
            let d = Day.string(c.postedAt)
            if map[d] == nil { order.append(d) }
            map[d, default: []].append(c)
        }
        return order.map { DayGroup(day: $0, items: map[$0] ?? []) }
    }

    private func label(_ day: String) -> String {
        if day == Day.today() { return "今天" }
        if day == Day.add(Day.today(), days: -1) { return "昨天" }
        return Day.label(day)
    }

    var body: some View {
        let gs = groups
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("小票").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                if !cards.isEmpty {
                    Text("\(cards.count)").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary).monospacedDigit()
                }
                Spacer()
            }
            .padding(.horizontal, 18)

            if gs.isEmpty {
                VStack(spacing: 4) {
                    Image(systemName: "ticket").font(.system(size: 18, weight: .light)).foregroundStyle(.tertiary)
                    Text("完成一个番茄，小票会收在这里").font(.caption).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, minHeight: 78)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                .padding(.horizontal, 10)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(gs) { g in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 6) {
                                    Text(label(g.day)).font(.system(size: 11, weight: .semibold))
                                    Text("\(g.items.count) 张 · \(FocusParser.formatMinutes(g.minutes))")
                                        .font(.system(size: 10.5)).foregroundStyle(.tertiary)
                                    Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 0.5)
                                }
                                LazyVGrid(columns: columns, spacing: 8) {
                                    ForEach(g.items) { c in
                                        MiniTicket(c: c)
                                            .onTapGesture { opened = c.id }
                                            .popover(isPresented: Binding(get: { opened == c.id }, set: { if !$0 { opened = nil } }), arrowEdge: .trailing) {
                                                VStack(spacing: 12) {
                                                    ResultTicketView(c: c, width: 300)
                                                    TicketActions(c: c, showClose: false) {}
                                                }
                                                .padding(16)
                                            }
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 10).padding(.bottom, 4)
                }
                .frame(maxHeight: 250)
            }
        }
        .padding(.top, 10).padding(.bottom, 8)
    }
}

/// 底边是锯齿的小票外形（撕下来的热敏纸）
private struct ReceiptShape: Shape {
    var tooth: CGFloat = 5
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - tooth))
        let n = max(Int((r.width / (tooth * 1.6)).rounded()), 2)
        let step = r.width / CGFloat(n)
        var x = r.maxX
        for _ in 0 ..< n {
            p.addLine(to: CGPoint(x: x - step / 2, y: r.maxY))
            p.addLine(to: CGPoint(x: x - step, y: r.maxY - tooth))
            x -= step
        }
        p.closeSubpath()
        // 上面两个角做成小圆角
        let clip = Path(roundedRect: CGRect(x: r.minX, y: r.minY, width: r.width, height: r.height + 20), cornerRadius: 5, style: .continuous)
        return p.intersection(clip)
    }
}

/// 一张迷你小票：奶白热敏纸、等宽小字、虚线分隔、条形码、锯齿底边——和弹出的完整小票是同一套配色
private struct MiniTicket: View {
    let c: Celebration
    @State private var hover = false

    private typealias P = TicketPalette

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private let tooth: CGFloat = 4.5

    var body: some View {
        let shape = ReceiptShape(tooth: tooth)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text("\(c.minutes)")
                    .font(.system(size: 17, weight: .heavy, design: .rounded)).monospacedDigit()
                    .foregroundStyle(c.completed ? P.num : P.mute)
                Text("分钟").font(.system(size: 9)).foregroundStyle(P.mute)
            }

            Text(c.title.isEmpty ? "自由专注" : c.title)
                .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(P.ink).lineLimit(1)
                .padding(.top, 1)

            Line().padding(.top, 4)

            HStack(spacing: 6) {
                Barcode(seed: c.serial).frame(height: 9).opacity(0.78)
                HStack(spacing: 3) {
                    Circle().fill(c.completed ? P.greenInk : P.mute.opacity(0.6)).frame(width: 4, height: 4)
                    Text(Self.clock.string(from: c.postedAt))
                        .font(.system(size: 8.5, weight: .semibold, design: .monospaced)).foregroundStyle(P.mute)
                }
                .fixedSize()
            }
            .padding(.top, 4)
        }
        .padding(.horizontal, 10).padding(.top, 7).padding(.bottom, 4 + tooth)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(LinearGradient(colors: [P.paper1, P.paper2], startPoint: .top, endPoint: .bottom)))
        .shadow(color: .black.opacity(hover ? 0.22 : 0.13), radius: hover ? 6 : 3, y: hover ? 3 : 1.5)
        .offset(y: hover ? -1.5 : 0)
        .animation(.easeOut(duration: 0.15), value: hover)
        .onHover { hover = $0 }
        .contentShape(shape)
        .environment(\.colorScheme, .light)
        .help(c.title.isEmpty ? "自由专注 · \(c.minutes) 分钟" : "\(c.title) · \(c.minutes) 分钟")
    }

    private struct Line: View {
        var body: some View {
            Path { p in
                p.move(to: CGPoint(x: 0, y: 0.5))
                p.addLine(to: CGPoint(x: 400, y: 0.5))
            }
            .stroke(TicketPalette.line, style: StrokeStyle(lineWidth: 1, dash: [2.5, 2.5]))
            .frame(height: 1)
            .clipped()
        }
    }
}
