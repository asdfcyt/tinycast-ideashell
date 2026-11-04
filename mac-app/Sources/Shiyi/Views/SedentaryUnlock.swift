import AppKit
import Combine
import SwiftUI

/// 黑白期间想提前恢复彩色：输入解锁口令，或者完成挑战（连续答对 3 道加减法 + 手敲 30 个随机字母，禁粘贴）。
struct SedentaryUnlockView: View {
    let close: () -> Void
    @ObservedObject private var r = SedentaryReminder.shared

    private enum Mode: Hashable { case pin, challenge }
    private enum Stage { case math, typing }

    @State private var mode: Mode = SedentaryPin.isSet && !SedentaryPin.isLocked ? .pin : .challenge
    @State private var message: String?
    @FocusState private var focused: Bool

    // 口令
    @State private var pin = ""
    @State private var now = Date()

    // 挑战
    @State private var stage: Stage = .math
    @State private var streak = 0
    @State private var a = 0
    @State private var b = 0
    @State private var plus = true
    @State private var answer = ""
    @State private var target = ""
    @State private var typed = ""

    private static let needStreak = 3
    private static let alphabet = Array("abcdefghjkmnpqrstuvwxyz")
    private static let targetLength = 30
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var pinAvailable: Bool { SedentaryPin.isSet }
    private var pinLocked: Bool { SedentaryPin.isLocked }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 9) {
                Image(systemName: "lock.fill").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 28, height: 28).background(Color.green.gradient, in: Circle())
                VStack(alignment: .leading, spacing: 1) {
                    Text("提前退出黑白").font(.system(size: 14, weight: .semibold))
                    Text("已连续使用 \(r.usedMinutes) 分钟，真的要现在恢复彩色吗？").font(.caption).foregroundStyle(.secondary)
                }
            }

            if pinAvailable {
                Picker("", selection: $mode) {
                    Text("解锁口令").tag(Mode.pin)
                    Text("完成挑战").tag(Mode.challenge)
                }
                .pickerStyle(.segmented).labelsHidden()
            }

            if mode == .pin { pinBody } else { challengeBody }

            if let message {
                Text(message).font(.system(size: 11.5)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            if !pinAvailable {
                Text("想更快退出？在「设置 › 久坐提醒」里设一个解锁口令。").font(.system(size: 10.5)).foregroundStyle(.tertiary)
            }
        }
        .padding(18)
        .frame(width: 400)
        .onAppear { newMath(); newTarget(); DispatchQueue.main.async { focused = true } }
        .onChange(of: mode) { _ in message = nil; DispatchQueue.main.async { focused = true } }
        .onReceive(tick) { now = $0 }
    }

    // MARK: 口令

    @ViewBuilder private var pinBody: some View {
        if pinLocked, let until = SedentaryPin.lockedUntil {
            let left = max(Int(until.timeIntervalSince(now)), 0)
            Text("输错太多次，口令暂时锁定，\(left / 60):\(String(format: "%02d", left % 60)) 后再试，或者完成挑战。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        } else {
            HStack(spacing: 8) {
                SecureField("输入解锁口令", text: $pin)
                    .textFieldStyle(.roundedBorder).focused($focused)
                    .onSubmit(submitPin)
                button("解锁", enabled: !pin.isEmpty, action: submitPin)
            }
        }
    }

    private func submitPin() {
        guard !pin.isEmpty else { return }
        if SedentaryPin.verify(pin) {
            grant()
        } else {
            pin = ""
            message = SedentaryPin.isLocked ? "连续输错 3 次，口令锁定 5 分钟。" : "口令不对。"
            if SedentaryPin.isLocked { mode = .challenge }
        }
    }

    // MARK: 挑战

    @ViewBuilder private var challengeBody: some View {
        switch stage {
        case .math:
            VStack(alignment: .leading, spacing: 8) {
                Text("第一关：连续答对 \(Self.needStreak) 题（答错从头开始）  \(streak) / \(Self.needStreak)")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                ProgressView(value: Double(streak), total: Double(Self.needStreak)).tint(.green)
                HStack(spacing: 8) {
                    Text("\(a) \(plus ? "+" : "−") \(b) =").font(.system(size: 18, weight: .semibold, design: .rounded)).monospacedDigit()
                    TextField("答案", text: $answer)
                        .textFieldStyle(.roundedBorder).frame(width: 90).focused($focused)
                        .onSubmit(submitMath)
                    button("提交", enabled: !answer.isEmpty, action: submitMath)
                }
            }
        case .typing:
            VStack(alignment: .leading, spacing: 8) {
                Text("第二关：照着手敲下面 \(Self.targetLength) 个字母（不能粘贴，空格和大小写不限）  \(typedCount) / \(Self.targetLength)")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Text(spaced(target))
                    .font(.system(size: 15, weight: .medium, design: .monospaced))
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .fixedSize(horizontal: false, vertical: true)
                TextField("在这里输入", text: $typed)
                    .textFieldStyle(.roundedBorder).font(.system(size: 13, design: .monospaced)).focused($focused)
                    .onChange(of: typed) { [typed] new in handleTyping(old: typed, new: new) }
                if let bad = firstMismatch {
                    Text("第 \(bad + 1) 个字符不对").font(.system(size: 11)).foregroundStyle(.orange)
                }
            }
        }
    }

    private var cleaned: String { typed.lowercased().filter { !$0.isWhitespace } }
    private var typedCount: Int { cleaned.count }
    private var firstMismatch: Int? {
        let t = Array(target), s = Array(cleaned)
        for i in 0 ..< min(t.count, s.count) where t[i] != s[i] { return i }
        return s.count > t.count ? t.count : nil
    }

    private func spaced(_ s: String) -> String {
        stride(from: 0, to: s.count, by: 5).map { i in
            String(s.dropFirst(i).prefix(5))
        }.joined(separator: " ")
    }

    private func newMath() {
        plus = Bool.random()
        if plus {
            a = Int.random(in: 21 ... 79)
            b = Int.random(in: 11 ... 69)
        } else {
            a = Int.random(in: 51 ... 99)
            b = Int.random(in: 11 ... 49)
        }
        answer = ""
    }

    private func newTarget() {
        target = String((0 ..< Self.targetLength).map { _ in Self.alphabet.randomElement()! })
        typed = ""
    }

    private func submitMath() {
        guard let v = Int(answer.trimmingCharacters(in: .whitespaces)) else { answer = ""; return }
        if v == (plus ? a + b : a - b) {
            streak += 1
            message = nil
            if streak >= Self.needStreak {
                stage = .typing
                DispatchQueue.main.async { focused = true }
            }
        } else {
            streak = 0
            message = "答错了，重新开始。"
        }
        newMath()
        if stage == .math { DispatchQueue.main.async { focused = true } }
    }

    /// 一次多出好几个字符 = 粘贴（或程序塞进来的），拒绝
    private func handleTyping(old: String, new: String) {
        if new.count - old.count > 2 {
            typed = old
            message = "不能粘贴，请手敲。"
            return
        }
        message = nil
        if cleaned == target { grant() }
    }

    // MARK: 通用

    private func grant() {
        r.earlyExitGranted()
        close()
    }

    private func button(_ title: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.white)
                .padding(.horizontal, 14).frame(height: 26)
                .background(Color.green.opacity(enabled ? 1 : 0.35), in: Capsule())
        }
        .buttonStyle(.plain).disabled(!enabled)
    }
}

/// 解锁窗口：浮在最上面，要能接收键盘输入；黑白一结束就自动关
@MainActor
final class SedentaryUnlockController: NSObject, NSWindowDelegate {
    static let shared = SedentaryUnlockController()
    private var window: NSWindow?
    private var bag = Set<AnyCancellable>()

    func show() {
        if let w = window {
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            return
        }
        let host = NSHostingController(rootView: SedentaryUnlockView(close: { [weak self] in self?.close() }))
        let w = NSWindow(contentViewController: host)
        w.title = "提前退出黑白"
        w.styleMask = [.titled, .closable]
        w.level = .floating
        w.isReleasedWhenClosed = false
        w.delegate = self
        let mouse = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main {
            let f = w.frame
            w.setFrameOrigin(NSPoint(x: screen.frame.midX - f.width / 2, y: screen.frame.midY - f.height / 2 + 60))
        } else {
            w.center()
        }
        window = w
        SedentaryReminder.shared.$phase
            .sink { [weak self] p in if p != .gray { DispatchQueue.main.async { self?.close() } } }
            .store(in: &bag)
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        bag.removeAll()
    }
}
