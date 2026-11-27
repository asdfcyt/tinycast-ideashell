import SwiftUI

// MARK: - 快速启动：把 AI 梳理的结果直接放在今天页里

/// 加载、缓存今天的 AI 梳理：同一天里有缓存就直接用，只有「重新梳理」才再请求
@MainActor final class TodayPlanLoader: ObservableObject {
    @Published var plan: QuickStartPlan?
    @Published var loading = false
    @Published var error: String?
    /// 「先放一放」里已延期的：行 id → 结果文案
    @Published var postponed: [UUID: String] = [:]

    /// 只取今天已经生成过的结果，不会发请求
    func restore(_ model: AppModel) {
        if plan == nil, let c = model.quickStartCache, Day.string(c.madeAt) == Day.today() { plan = c }
    }

    /// 手动生成（或重新梳理）
    func load(_ model: AppModel, force: Bool) async {
        guard model.hasLlm, !loading else { return }
        loading = true
        error = nil
        defer { loading = false }
        do {
            let p = try await QuickStartPlanner.plan(model: model)
            plan = p
            model.quickStartCache = p
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// 快速启动结果卡：开场白、今天做这几件（带理由）、无压启动、留意一下、先放一放
struct QuickStartCard: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var loader = TodayPlanLoader()
    /// 默认折叠；折叠状态记住
    @AppStorage("today.quickStartOpen") private var open = false

    private let green = Color(red: 0.16, green: 0.62, blue: 0.37)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if open { expandedHeader } else { collapsedRow }
            if open {
                if let p = loader.plan {
                    content(p)
                } else if loader.loading {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("AI 正在梳理今天…").font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        if let e = loader.error { Text(e).font(.caption).foregroundStyle(.red) }
                        Text("让 AI 看看今天的待办、最近的笔记和 Daily Note，梳理出先做什么。")
                            .font(.system(size: 13)).foregroundStyle(.secondary)
                        Button { Task { await loader.load(model, force: true) } } label: {
                            Label("生成快速启动", systemImage: "sparkles")
                                .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                                .padding(.horizontal, 12).frame(height: 28)
                                .background(Brand.orange.gradient, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 16).padding(.top, 2).padding(.bottom, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(radius: 16, tint: Brand.orange.opacity(0.10))
        .onAppear { loader.restore(model) }
        // 标题栏的闪电：展开并重新梳理一次
        .onChange(of: model.quickStartTick) { _, _ in
            open = true
            Task { await loader.load(model, force: true) }
        }
    }

    private var chevron: some View {
        Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold)).foregroundStyle(.tertiary)
            .rotationEffect(.degrees(open ? 90 : 0)).frame(width: 16, height: 16)
    }

    private func toggle() { withAnimation(.easeOut(duration: 0.15)) { open.toggle() } }

    /// 折叠时只剩一行：快速启动 + 一句话（和「昨天」一致）
    private var collapsedRow: some View {
        let line = loader.loading ? "AI 正在梳理今天…"
            : loader.plan.map { $0.greeting.isEmpty ? "已生成 · \($0.focus.count) 件要事" : $0.greeting }
            ?? "还没有生成，展开后手动生成"
        return HStack(spacing: 8) {
            chevron
            Text("快速启动").font(.subheadline.weight(.semibold))
            Text(line).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .contentShape(Rectangle())
        .onTapGesture { toggle() }
    }

    private var expandedHeader: some View {
        HStack(spacing: 8) {
            chevron
            Image(systemName: "bolt.fill").foregroundStyle(Brand.orange)
            Text("快速启动").font(.subheadline.weight(.semibold))
            Spacer(minLength: 6)
            if loader.plan != nil {
                Text("AI").font(.caption2.weight(.bold)).foregroundStyle(Brand.orangeDeep)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Brand.orange.opacity(0.14), in: Capsule())
                Button { Task { await loader.load(model, force: true) } } label: {
                    HStack(spacing: 3) {
                        Text("重新梳理")
                        Image(systemName: "arrow.clockwise").font(.system(size: 9, weight: .bold))
                    }
                    .font(.caption.weight(.medium)).foregroundStyle(Brand.orangeDeep)
                }
                .buttonStyle(.plain).disabled(loader.loading)
            }
        }
        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)
        .contentShape(Rectangle())
        .onTapGesture { toggle() }
    }

    @ViewBuilder private func content(_ p: QuickStartPlan) -> some View {
        if !p.greeting.isEmpty {
            Text(p.greeting).font(.system(size: 13)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16).padding(.bottom, 8)
        }
        // 今天做这几件
        ForEach(Array(p.focus.enumerated()), id: \.element.id) { i, f in
            Divider().padding(.leading, 16)
            HStack(alignment: .center, spacing: 12) {
                Text("\(i + 1)").font(.system(size: 11, weight: .heavy)).foregroundStyle(.white)
                    .frame(width: 20, height: 20).background(Brand.orange, in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(f.title).font(.system(size: 13, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                    if !f.why.isEmpty {
                        Text(f.why).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                if let t = f.task {
                    Button { model.openTask(t) } label: {
                        Image(systemName: "arrow.up.right.square").font(.system(size: 14)).frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain).foregroundStyle(.tertiary).help("打开这个待办")
                    Button {
                        model.focus.attach(t)
                        model.focus.quickFocus(25)
                        model.section = .focus
                    } label: {
                        Image(systemName: "play.fill").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 24, height: 24).background(Brand.orange, in: Circle())
                    }
                    .buttonStyle(.plain).help("现在就专注 25 分钟：" + t.cleanTitle)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
        }
        // 无压启动
        if !p.startTitle.isEmpty {
            Divider().padding(.leading, 16)
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("无压启动").font(.caption2.weight(.bold)).foregroundStyle(green)
                    Text(p.startTitle).font(.system(size: 13, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                    if !p.startStep.isEmpty {
                        Text(p.startStep).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    if !p.tip.isEmpty { Text(p.tip).font(.caption).foregroundStyle(green) }
                }
                Spacer(minLength: 8)
                Button {
                    model.focus.attach(p.startTask)
                    model.focus.quickFocus(p.startMinutes)
                    model.section = .focus
                } label: {
                    Label("开始 \(p.startMinutes) 分钟", systemImage: "play.fill")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 12).frame(height: 28)
                        .background(green.gradient, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(green.opacity(0.07))
        }
        // 留意一下
        if !p.watch.isEmpty {
            Divider().padding(.leading, 16)
            VStack(alignment: .leading, spacing: 5) {
                Label("留意一下", systemImage: "eye").font(.caption.weight(.bold)).foregroundStyle(.blue)
                ForEach(p.watch, id: \.self) { w in
                    Text(w).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // 先放一放
        if !p.later.isEmpty {
            Divider().padding(.leading, 16)
            VStack(alignment: .leading, spacing: 6) {
                Label("先放一放", systemImage: "tray").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                ForEach(p.later) { w in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(w.text).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        if let t = w.task { postponeControl(w.id, t) }
                    }
                }
            }
            .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// 改到明天 / 后天 / 下周一，保留原来的时间点；改完这一行显示结果
    @ViewBuilder private func postponeControl(_ id: UUID, _ t: DidaTask) -> some View {
        if let done = loader.postponed[id] {
            Label(done, systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
        } else {
            Menu {
                let today = Day.today()
                ForEach([("明天", 1), ("后天", 2), ("下周一", -1)], id: \.0) { label, n in
                    Button(label) {
                        let day = n > 0 ? Day.add(today, days: n) : Scheduler.nextMonday(from: today)
                        let task = model.localTask(t.id) ?? t
                        Task {
                            await model.edit(task, .schedule(date: day, time: task.time))
                            loader.postponed[id] = "已延期到" + Day.label(day)
                        }
                    }
                }
            } label: {
                Label("延期", systemImage: "clock.arrow.circlepath").font(.caption.weight(.medium))
            }
            .menuStyle(.button).menuIndicator(.hidden).fixedSize()
            .controlSize(.small)
            .help("把「" + t.cleanTitle + "」改期")
        }
    }
}
