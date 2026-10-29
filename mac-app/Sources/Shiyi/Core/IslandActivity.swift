import AppKit
import Foundation

/// 拖拽时落在岛的哪一半：左 = 保存（自动识别），右 = 暂存
enum DropZone { case save, shelf, evidence, regulation, clue, data }

/// 刚截的一张图 / 剪贴板里的新图片：岛上弹出提示，可以一键保存、暂存，或直接拖走
struct CaptureOffer: Identifiable, Equatable {
    let id = UUID()
    var raw: RawDrop
    var fileURL: URL?
    var thumbnail: NSImage?
    var title: String

    static func == (a: CaptureOffer, b: CaptureOffer) -> Bool { a.id == b.id }
}

/// 灵动岛上的「实时活动」：不用鼠标悬停，事件发生时岛自己弹出来
enum IslandActivity: Identifiable, Equatable {
    case capture(CaptureOffer)
    /// ticket 非空 = 岛左右拉宽成「专注终端」：左边打印这张小票，右边是休息一下的跟练卡；为空时只弹一条小提示
    case focusDone(minutes: Int, nextBreak: FocusKind?, ticket: Celebration?)
    case breakDone(FocusKind)
    case todoDue(DidaTask, leadMin: Int)
    case audit(SjzEvent)

    var id: String {
        switch self {
        case let .capture(o): return "capture-" + o.id.uuidString
        case let .focusDone(m, _, _): return "focusDone-\(m)-\(Date().timeIntervalSince1970)"
        case let .breakDone(k): return "breakDone-" + k.rawValue
        case let .todoDue(t, _): return "todo-" + t.id
        case let .audit(e): return "audit-" + e.id
        }
    }

    /// 没人理它时停留多久
    var duration: TimeInterval {
        switch self {
        case .capture: return 9
        // 小票要留给人慢慢看（和跟练）：岛也跟着多留一会儿
        case let .focusDone(_, _, t): return t == nil ? 25 : 120
        case .breakDone: return 25
        case .todoDue: return 30
        case .audit: return 20
        }
    }
}

/// `extend(m)`：休息前多专注 m 分钟（跳过休息，直接再开一段 m 分钟的专注）
enum ActivityAction: Equatable { case primary, secondary, tertiary, evidence, regulation, dismiss, extend(Int) }
