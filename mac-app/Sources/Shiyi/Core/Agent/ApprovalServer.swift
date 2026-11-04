import Foundation
import Network

/// 本机小服务：只听 127.0.0.1，钩子进程（shiyi-hook）把 Agent 的请求 POST 进来，批完再把结果回给它。
/// 防滥用：只绑回环地址；请求必须带令牌（`X-Shiyi-Token`）；带 `Origin` 头的（浏览器发来的）一律拒绝。
final class ApprovalServer: @unchecked Sendable {
    static let shared = ApprovalServer()

    private let queue = DispatchQueue(label: "shiyi.agent.server")
    private var listener: NWListener?
    private(set) var port: UInt16 = 0

    private final class Conn {
        let id = UUID()
        let nw: NWConnection
        var buf = Data()
        var routed = false
        init(_ c: NWConnection) { nw = c }
    }

    private struct Request {
        var method: String
        var path: String
        var headers: [String: String]
        var body: Data
    }

    var isRunning: Bool { port > 0 }

    func start() {
        queue.async { [self] in
            guard listener == nil else { return }
            listen(preferred: AgentBridge.preferredPort())
        }
    }

    func stop() {
        queue.async { [self] in
            listener?.cancel()
            listener = nil
            port = 0
        }
    }

    private func listen(preferred: UInt16?) {
        let params = NWParameters.tcp
        params.acceptLocalOnly = true
        params.requiredInterfaceType = .loopback
        let l: NWListener
        do {
            let p = preferred.flatMap { NWEndpoint.Port(rawValue: $0) } ?? NWEndpoint.Port.any
            l = try NWListener(using: params, on: p)
        } catch {
            if preferred != nil { listen(preferred: nil) }
            return
        }
        l.stateUpdateHandler = { [weak self, weak l] st in
            guard let self, let l else { return }
            switch st {
            case .ready:
                if let p = l.port?.rawValue {
                    self.port = p
                    AgentBridge.write(port: p)
                }
            case .failed:
                l.cancel()
                if self.listener === l { self.listener = nil }
                self.port = 0
                // 首选端口被占用：换一个随机端口（钩子每次都从桥接文件读端口，不受影响）
                if preferred != nil { self.listen(preferred: nil) }
            default:
                break
            }
        }
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        listener = l
        l.start(queue: queue)
    }

    // MARK: 连接 / 解析

    private func accept(_ nw: NWConnection) {
        let c = Conn(nw)
        nw.start(queue: queue)
        read(c)
    }

    private func read(_ c: Conn) {
        c.nw.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, done, err in
            guard let self else { return }
            if let data { c.buf.append(data) }
            if let req = Self.parse(c.buf) {
                c.routed = true
                self.route(c, req)
                return
            }
            if done || err != nil || c.buf.count > 8_000_000 { c.nw.cancel(); return }
            self.read(c)
        }
    }

    /// 请求头 + 正文都收齐了才返回
    private static func parse(_ data: Data) -> Request? {
        guard let sep = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let head = String(data: data[data.startIndex ..< sep.lowerBound], encoding: .utf8) else { return nil }
        var lines = head.components(separatedBy: "\r\n")
        let first = lines.removeFirst().split(separator: " ").map(String.init)
        guard first.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for l in lines {
            guard let i = l.firstIndex(of: ":") else { continue }
            headers[l[..<i].lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces)
        }
        let need = Int(headers["content-length"] ?? "0") ?? 0
        let body = data[sep.upperBound...]
        guard body.count >= need else { return nil }
        return Request(method: first[0], path: first[1], headers: headers, body: Data(body.prefix(need)))
    }

    private func route(_ c: Conn, _ req: Request) {
        guard req.headers["origin"] == nil, req.headers["x-shiyi-token"] == AgentBridge.token else {
            reply(c, status: 401, body: Data("{\"error\":\"unauthorized\"}".utf8)); return
        }
        if req.method == "GET", req.path == "/v1/ping" {
            reply(c, status: 200, body: Data("{\"ok\":true}".utf8)); return
        }
        guard req.method == "POST", req.path.hasPrefix("/v1/hook/") else {
            reply(c, status: 404, body: Data("{\"error\":\"not found\"}".utf8)); return
        }
        let agent = String(req.path.dropFirst("/v1/hook/".count))
        watchClose(c)
        let body = req.body
        Task { @MainActor [weak self] in
            let out = await ApprovalCenter.shared.handleHook(agent: agent, body: body, conn: c.id)
            self?.reply(c, status: 200, body: out)
        }
    }

    /// 等批期间盯着连接：对方断了（Agent 被中止 / 钩子被杀）就撤掉这张审批请求
    private func watchClose(_ c: Conn) {
        c.nw.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self] _, _, done, err in
            if done || err != nil {
                let id = c.id
                Task { @MainActor in ApprovalCenter.shared.dropConnection(id) }
            } else {
                self?.watchClose(c)
            }
        }
    }

    private func reply(_ c: Conn, status: Int, body: Data) {
        let text = status == 200 ? "OK" : (status == 401 ? "Unauthorized" : "Not Found")
        var out = Data("HTTP/1.1 \(status) \(text)\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        out.append(body)
        c.nw.send(content: out, completion: .contentProcessed { _ in c.nw.cancel() })
    }
}
