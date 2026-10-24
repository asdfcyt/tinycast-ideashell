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
    case focusDone(minutes: Int, nextBreak: FocusKind?)
    case breakDone(FocusKind)
    case todoDue(DidaTask, leadMin: Int)
    case audit(SjzEvent)

    var id: String {
        switch self {
        case let .capture(o): return "capture-" + o.id.uuidString
        case let .focusDone(m, _): return "focusDone-\(m)-\(Date().timeIntervalSince1970)"
        case let .breakDone(k): return "breakDone-" + k.rawValue
        case let .todoDue(t, _): return "todo-" + t.id
        case let .audit(e): return "audit-" + e.id
        }
    }

    /// 没人理它时停留多久
    var duration: TimeInterval {
        switch self {
        case .capture: return 9
        case .focusDone, .breakDone: return 25
        case .todoDue: return 30
        case .audit: return 20
        }
    }
}

enum ActivityAction { case primary, secondary, tertiary, evidence, regulation, dismiss }
