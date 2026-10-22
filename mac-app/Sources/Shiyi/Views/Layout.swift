import SwiftUI

/// 左右两栏。不用 `HSplitView`：它按自己记住的分栏宽度布局，窗口缩小时某一栏不肯收缩，整页内容就被挤出窗口（侧边栏被切、右侧被切）。
/// 这里每次都按当前宽度重新算：左栏占 [leadingFraction]，夹在 [leadingMin, leadingMax] 之间，右栏拿剩下的（不少于 [trailingMin]）。
struct TwoPane<Leading: View, Trailing: View>: View {
    var leadingFraction: CGFloat = 0.4
    var leadingMin: CGFloat = 280
    var leadingMax: CGFloat = 520
    var trailingMin: CGFloat = 320
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        GeometryReader { geo in
            let total = geo.size.width
            let wanted = min(max(total * leadingFraction, leadingMin), leadingMax)
            let lw = max(min(wanted, total - trailingMin - 1), 160)
            let tw = max(total - lw - 1, 0)
            HStack(spacing: 0) {
                leading().frame(width: lw, height: geo.size.height)
                Divider()
                trailing().frame(width: tw, height: geo.size.height)
            }
            .frame(width: total, height: geo.size.height, alignment: .leading)
            .clipped()
        }
        .background(AmbientBackground())
    }
}
