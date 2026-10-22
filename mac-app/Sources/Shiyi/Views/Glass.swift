import SwiftUI

/// 液态玻璃（Liquid Glass）。
///
/// macOS 26 及以上直接用 SwiftUI 原生的 `.glassEffect()`；更低版本退回系统材质（毛玻璃）。
/// 窗口 / 侧边栏 / 工具栏的玻璃由系统在新 SDK 下自动套用。
extension View {
    /// 玻璃底板（圆角矩形）。用在卡片、统计块、提示条这类「浮在内容上」的元素上
    @ViewBuilder
    func glassCard(radius: CGFloat = 14, tint: Color? = nil) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular.tint(tint), in: .rect(cornerRadius: radius))
        } else {
            self
                .background {
                    ZStack {
                        RoundedRectangle(cornerRadius: radius, style: .continuous).fill(.regularMaterial)
                        if let tint { RoundedRectangle(cornerRadius: radius, style: .continuous).fill(tint) }
                    }
                }
                .overlay { RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5) }
        }
    }

    /// 玻璃胶囊（提示条、标签底）
    @ViewBuilder
    func glassCapsule(tint: Color? = nil) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular.tint(tint), in: .capsule)
        } else {
            self
                .background {
                    ZStack {
                        Capsule().fill(.regularMaterial)
                        if let tint { Capsule().fill(tint) }
                    }
                }
                .overlay { Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5) }
        }
    }
}

/// 页面背景：很淡的品牌暖色光晕，让玻璃有东西可折射
struct AmbientBackground: View {
    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            RadialGradient(colors: [Color(red: 0.96, green: 0.71, blue: 0.25).opacity(0.20), .clear],
                           center: .topTrailing, startRadius: 0, endRadius: 560)
            RadialGradient(colors: [Color(red: 0.93, green: 0.49, blue: 0.24).opacity(0.13), .clear],
                           center: .bottomLeading, startRadius: 0, endRadius: 520)
        }
        .ignoresSafeArea()
    }
}
