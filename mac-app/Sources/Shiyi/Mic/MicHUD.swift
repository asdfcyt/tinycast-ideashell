import AppKit

/// 屏幕顶部居中的轻量提示(静音、不抢焦点、鼠标穿透)。
@MainActor
final class MicHUD {
    enum Style {
        case recording, info, success, warning

        var symbol: String {
            switch self {
            case .recording: return "mic.fill"
            case .info: return "text.bubble"
            case .success: return "checkmark.circle.fill"
            case .warning: return "mic.slash.fill"
            }
        }
        var tint: NSColor {
            switch self {
            case .recording: return .systemRed
            case .info: return .labelColor
            case .success: return .systemGreen
            case .warning: return .systemOrange
            }
        }
    }

    private var panel: NSPanel?
    private let label = NSTextField(labelWithString: "")
    private let icon = NSImageView()
    private var hideTask: Task<Void, Never>?

    func show(_ text: String, style: Style, autoHide: TimeInterval?) {
        let panel = ensurePanel()
        label.stringValue = text
        label.sizeToFit()
        icon.image = NSImage(systemSymbolName: style.symbol, accessibilityDescription: nil)
        icon.contentTintColor = style.tint

        let height: CGFloat = 40
        let width = label.frame.width + 62
        let screen = NSScreen.main ?? NSScreen.screens.first
        let vf = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = NSRect(x: vf.midX - width / 2, y: vf.maxY - height - 12, width: width, height: height)
        panel.setFrame(frame, display: true)
        icon.frame = NSRect(x: 16, y: 9, width: 22, height: 22)
        label.frame = NSRect(x: 46, y: (height - label.frame.height) / 2, width: label.frame.width, height: label.frame.height)
        panel.orderFrontRegardless()

        hideTask?.cancel()
        if let t = autoHide {
            hideTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(t * 1_000_000_000))
                if !Task.isCancelled { self?.hide() }
            }
        }
    }

    func hide() {
        hideTask?.cancel()
        panel?.orderOut(nil)
    }

    private func ensurePanel() -> NSPanel {
        if let p = panel { return p }
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 240, height: 40),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .statusBar
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let bg = NSVisualEffectView(frame: p.contentRect(forFrameRect: p.frame))
        bg.material = .hudWindow
        bg.blendingMode = .behindWindow
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 20
        bg.layer?.masksToBounds = true
        bg.autoresizingMask = [.width, .height]

        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = .labelColor
        label.lineBreakMode = .byClipping
        bg.addSubview(icon)
        bg.addSubview(label)
        p.contentView = bg
        panel = p
        return p
    }
}
