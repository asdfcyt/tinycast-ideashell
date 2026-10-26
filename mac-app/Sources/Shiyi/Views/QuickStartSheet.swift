import SwiftUI

/// 快速启动：AI 梳理今天要做的事、值得留意的事，并给一个 10~25 分钟的小目标，点一下就开始专注。
struct QuickStartSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var plan: QuickStartPlan?
    @State private var error: String?
    @State private var loading = false
    @State private var postponed: [UUID: String] = [:]

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if loading {
                        loadingView
                    } else if let error {
                        errorView(error)
                    } else if let plan {
                        result(plan)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
            Divider()
            footer
        }
        .frame(width: 520, height: 600)
        .task { await load(force: false) }
    }

    // MARK: - 框架

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(Brand.orange.gradient, in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text("快速启动").font(.title3.weight(.bold))
                Text("AI 帮你理一理今天，不用一下子做完").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { dismiss() } label: { Image(systemName: "xmark") }
                .buttonStyle(FloatingChipStyle()).keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let p = plan, !loading {
                Text("梳理于 " + p.madeAt.formatted(date: .omitted, time: .shortened)).font(.caption).foregroundStyle(.tertiary)
            }
            Spacer()
            Button { Task { await load(force: true) } } label: { Label("重新梳理", systemImage: "arrow.clockwise") }
                .disabled(loading)
            if let p = plan, !loading {
                Button { start(p) } label: { Label("开始 \(p.startMinutes) 分钟", systemImage: "play.fill") }
                    .buttonStyle(.borderedProminent).tint(Brand.orange)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .controlSize(.large)
        .padding(.horizontal, 20).padding(.vertical, 12)
    }

    // MARK: - 状态

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("正在梳理今天的待办、笔记和 Daily Note…").font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 300)
    }

    private func errorView(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            if !model.hasLlm {
                Button("去设置 AI 模型") { dismiss(); SettingsWindow.show(.ai) }.buttonStyle(.borderedProminent).tint(Brand.orange)
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(radius: 14, tint: Color.orange.opacity(0.08))
    }

    // MARK: - 结果

    @ViewBuilder private func result(_ p: QuickStartPlan) -> some View {
        if !p.greeting.isEmpty {
            Text(p.greeting).font(.title3.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
        }

        // 今天做这几件
        block("今天做这几件", icon: "target", tint: Brand.orange) {
            ForEach(Array(p.focus.enumerated()), id: \.element.id) { i, f in
                HStack(alignment: .top, spacing: 10) {
                    Text("\(i + 1)").font(.caption.weight(.bold)).foregroundStyle(.white)
                        .frame(width: 20, height: 20).background(Brand.orange, in: Circle())
                    VStack(alignment: .leading, spacing: 3) {
                        Text(f.title).font(.callout.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                        if !f.why.isEmpty { Text(f.why).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                    }
                    Spacer(minLength: 0)
                    if let t = f.task {
                        // 两个按钮同样大小、整组在这一行里垂直居中
                        HStack(alignment: .center, spacing: 8) {
                            Button { model.openTask(t); dismiss() } label: {
                                Image(systemName: "arrow.up.right.square").font(.system(size: 15))
                                    .frame(width: 24, height: 24)
                            }
                            .buttonStyle(.plain).foregroundStyle(.tertiary).help("打开这个待办")
                            Button { startFocus(task: t, minutes: 25) } label: {
                                Image(systemName: "play.fill").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                                    .frame(width: 24, height: 24).background(Brand.orange, in: Circle())
                            }
                            .buttonStyle(.plain).help("现在就专注 25 分钟：" + t.cleanTitle)
                        }
                        .frame(maxHeight: .infinity, alignment: .center)
                    }
                }
            }
        }

        // 无压启动
        VStack(alignment: .leading, spacing: 8) {
            Label("无压启动", systemImage: "leaf.fill").font(.subheadline.weight(.bold)).foregroundStyle(.green)
            Text(p.startTitle).font(.headline).fixedSize(horizontal: false, vertical: true)
            if !p.startStep.isEmpty {
                Label(p.startStep, systemImage: "figure.walk").font(.callout).foregroundStyle(.primary.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                TagChip(text: "\(p.startMinutes) 分钟", tint: .green)
                if let t = p.startTask { TagChip(text: "关联：" + t.cleanTitle, tint: .secondary) }
            }
            if !p.tip.isEmpty { Text(p.tip).font(.caption).foregroundStyle(.secondary) }
            Button { start(p) } label: {
                Label("现在就开始 \(p.startMinutes) 分钟", systemImage: "play.fill")
                    .font(.callout.weight(.semibold)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).padding(.vertical, 8)
                    .background(Color.green.gradient, in: Capsule())
            }
            .buttonStyle(.plain).padding(.top, 4)
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(radius: 14, tint: Color.green.opacity(0.10))
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .onTapGesture { start(p) }
        .help("点一下，直接开始专注")

        if !p.watch.isEmpty {
            block("留意一下", icon: "eye", tint: .blue) {
                ForEach(p.watch, id: \.self) { w in
                    HStack(alignment: .top, spacing: 8) {
                        Circle().fill(Color.blue.opacity(0.6)).frame(width: 5, height: 5).padding(.top, 7)
                        Text(w).font(.callout).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        if !p.later.isEmpty {
            block("可以先放一放", icon: "tray.and.arrow.down", tint: .secondary) {
                ForEach(p.later) { w in
                    HStack(alignment: .center, spacing: 8) {
                        Text("· " + w.text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        if let t = w.task { postponeControl(w.id, t) }
                    }
                }
            }
        }
    }

    /// 「延期」：改到明天 / 后天 / 下周一，保留原来的时间点；改完这一行显示结果
    @ViewBuilder private func postponeControl(_ id: UUID, _ t: DidaTask) -> some View {
        if let done = postponed[id] {
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
                            postponed[id] = "已延期到" + Day.label(day)
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

    private func block<C: View>(_ title: String, icon: String, tint: Color, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon).font(.subheadline.weight(.bold)).foregroundStyle(tint)
            content()
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(radius: 14)
    }

    // MARK: - 动作

    private func load(force: Bool) async {
        if !force, let c = model.quickStartCache, Date().timeIntervalSince(c.madeAt) < 30 * 60, Day.string(c.madeAt) == Day.today() {
            plan = c
            return
        }
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

    private func start(_ p: QuickStartPlan) { startFocus(task: p.startTask, minutes: p.startMinutes) }

    private func startFocus(task: DidaTask?, minutes: Int) {
        model.focus.attach(task)
        model.focus.quickFocus(minutes)
        dismiss()
        model.section = .focus
    }
}
