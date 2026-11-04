import Foundation

/// 把任务交给 opencode：直接在指定目录里跑 `opencode run`（无界面，用你 opencode 里配好的模型和账号）。
/// 进程里会加载全局插件 shiyi.js（设置里开了 opencode 接入就装好了），所以运行状态、审批和验收卡都走岛上，
/// 和你自己在终端里开的 opencode 一样。环境变量 SHIYI_DISPATCH 告诉插件「这一轮是拾忆派的」，验收卡上就能接着追问。
enum OpenCodeRunner {
    /// opencode 命令行的位置（找不到说明没装）
    static let binary: String? = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var dirs = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        dirs += ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.opencode/bin", "\(home)/.bun/bin", "\(home)/.local/bin"]
        for d in dirs {
            let p = d + "/opencode"
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }()

    /// opencode 最近的会话（读它自己的数据库，只读）：新的在前；只要主会话，目录已不存在的略过
    nonisolated static func recentSessions(limit: Int = 30) -> [OpenCodeSession] {
        let db = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/opencode/opencode.db").path
        guard FileManager.default.fileExists(atPath: db) else { return [] }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        p.arguments = ["-readonly", "-cmd", ".timeout 800", "-json", db,
                       "select id, title, directory from session where parent_id is null and time_archived is null order by time_updated desc limit \(limit)"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        let fm = FileManager.default
        var out: [OpenCodeSession] = []
        for r in rows {
            guard let id = r["id"] as? String, let dir = r["directory"] as? String,
                  dir != "/", !dir.hasPrefix("/private/tmp"), !dir.hasPrefix("/tmp") else { continue }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else { continue }
            out.append(OpenCodeSession(id: id, title: (r["title"] as? String) ?? "", dir: dir))
        }
        return out
    }
}

/// opencode 的一个会话
struct OpenCodeSession: Identifiable, Hashable {
    let id: String
    let title: String
    let dir: String

    var dirName: String { (dir as NSString).lastPathComponent }
    /// 没起名的会话（New session - …）用目录名代替
    var displayTitle: String { title.isEmpty || title.hasPrefix("New session") ? dirName : title }
}

/// opencode 的会话 / 目录缓存：启动时和输入框打开后在后台刷新，界面只读缓存——展开时不做任何磁盘 / 子进程操作
@MainActor
final class OpenCodeStore: ObservableObject {
    static let shared = OpenCodeStore()

    @Published private(set) var sessions: [OpenCodeSession] = []
    private var loading = false
    private var last = Date.distantPast

    /// 最近用过的项目目录（去重，新的在前）
    var dirs: [String] {
        var seen = Set<String>()
        return sessions.map(\.dir).filter { seen.insert($0).inserted }.prefix(8).map { $0 }
    }

    /// delay：稍等一会儿再读，避开展开动画；15 秒内不重复读
    func refresh(after delay: TimeInterval = 0, force: Bool = false) {
        guard OpenCodeRunner.binary != nil, !loading else { return }
        if !force, Date().timeIntervalSince(last) < 15 { return }
        loading = true
        Task { [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            let list = await Task.detached(priority: .utility) { OpenCodeRunner.recentSessions() }.value
            guard let self else { return }
            self.loading = false
            self.last = Date()
            if list != self.sessions { self.sessions = list }
        }
    }
}
