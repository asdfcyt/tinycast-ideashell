import Foundation

/// 猛犸 LARK A2 接收器 (USB 3547:0411) 私有 HID 协议(Report ID 0x55,63 字节载荷)。
///
/// 请求:AA DD <cmd> <dev> <lenH> <lenL> <payload>   dev: 0x40=RX 0x41=TX1 0x42=TX2
/// 回包:BB DD <cmd> <dev> <lenH> <lenL> <payload>   dev: 0x80=RX 0x81=TX1 0x82=TX2
///
/// 逆向得到的指令(固件 3.0.2.008,空载荷即可读取):
///   0x03 版本类      0x04/0x05/0x08/0x09/0x12/0x13/0x14/0x18  状态寄存器(含义待定)
///   0x10 心跳        0x11 降噪档位     0x15 设备 ID / TX 序列号(ASCII)   0x16 状态汇总
///   0x06 设置降噪档位  0x19 降噪开关(任意载荷均为翻转)
///   0x41 规则版本
/// 危险指令(勿发送):0x0C 接收器重启,0x0D 链路重连,0x30 进入固件升级模式。
enum MicProto {
    static let vid = 0x3547
    static let pid = 0x0411
    static let reportID: UInt8 = 0x55

    static let devRX: UInt8 = 0x40
    static let devTX1: UInt8 = 0x41
    static let devTX2: UInt8 = 0x42

    static let cmdHeart: UInt8 = 0x10
    static let cmdNoiseLevelSet: UInt8 = 0x06
    static let cmdNoiseSwitchSet: UInt8 = 0x19
    static let cmdVersion: UInt8 = 0x41
    static let cmdSerial: UInt8 = 0x15

    /// 构造 64 字节输出报告(首字节为 Report ID)。
    static func packet(cmd: UInt8, payload: [UInt8] = [], dev: UInt8 = devRX) -> [UInt8] {
        var p = [UInt8](repeating: 0, count: 63)
        p[0] = 0xAA
        p[1] = 0xDD
        p[2] = cmd
        p[3] = dev
        p[4] = UInt8((payload.count >> 8) & 0xFF)
        p[5] = UInt8(payload.count & 0xFF)
        for (i, b) in payload.enumerated() where 6 + i < p.count { p[6 + i] = b }
        return [reportID] + p
    }

    /// 解析回包;兼容缓冲区带/不带 Report ID 前缀。
    static func parse(_ d: [UInt8]) -> (cmd: UInt8, dev: UInt8, payload: [UInt8])? {
        var o = 0
        if let f = d.first, f == reportID { o = 1 }
        guard d.count >= o + 6, d[o] == 0xBB, d[o + 1] == 0xDD else { return nil }
        let cmd = d[o + 2]
        let dev = d[o + 3]
        let len = (Int(d[o + 4]) << 8) | Int(d[o + 5])
        let start = o + 6
        let end = min(d.count, start + len)
        guard start <= end else { return nil }
        return (cmd, dev, Array(d[start..<end]))
    }

    static func ascii(_ bytes: [UInt8]) -> String {
        let printable = bytes.filter { $0 >= 0x20 && $0 < 0x7F }
        return String(bytes: printable, encoding: .ascii) ?? ""
    }
}

/// 心跳状态(接收器 0x10 命令回包的载荷)。
struct MicHeart: Equatable {
    var tx1Online = false
    var tx2Online = false
    var tx1Battery = 0
    var tx2Battery = 0
    var noise = 0
    var tx1Muted = false
    var tx2Muted = false
    var tx1Charging = false
    var tx2Charging = false
    var raw: [UInt8] = []

    init() {}

    init(payload: [UInt8]) {
        raw = payload
        var p = payload
        if p.count < 16 { p += [UInt8](repeating: 0, count: 16 - p.count) }
        let flags = p[15]
        tx1Online = p[0] == 1
        tx2Online = p[1] == 1
        tx1Battery = Int(p[2])
        tx2Battery = Int(p[3])
        noise = Int(p[6])
        tx1Muted = flags & 0x01 != 0
        tx2Muted = flags & 0x02 != 0
        tx1Charging = flags & 0x04 != 0
        tx2Charging = flags & 0x08 != 0
    }

    /// 任一在线 TX 处于静音。
    var anyMuted: Bool { (tx1Online && tx1Muted) || (tx2Online && tx2Muted) }
    var anyOnline: Bool { tx1Online || tx2Online }

    var rawHex: String { raw.map { String(format: "%02X", $0) }.joined(separator: " ") }
}
