import SwiftUI

enum OfficeMood {
    case idle, working, waiting, error

    var label: String {
        switch self {
        case .idle: return "待命"
        case .working: return "工作中"
        case .waiting: return "等你拍板"
        case .error: return "没跑成"
        }
    }

    var tint: Color {
        switch self {
        case .idle: return .secondary
        case .working: return .green
        case .waiting: return .orange
        case .error: return .red
        }
    }
}

struct OfficeAgent: Identifiable {
    let id: String
    var name: String
    var color: Color
    var mood: OfficeMood
    /// 头上气泡里的短句
    var say: String?
    /// 完整的任务内容
    var task = ""
    var activity: String?
    var started: Date?
    var jobId: UUID?
    var jobActive = false
    var canRerun = false
}

struct OfficeBoard {
    var active = 0
    var waiting = 0
    var done = 0
}

