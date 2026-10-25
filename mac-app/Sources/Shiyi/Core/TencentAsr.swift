import CryptoKit
import Foundation

struct AsrError: LocalizedError {
    let message: String
    var code = ""
    var errorDescription: String? { message }
}

/// 腾讯云「一句话识别」（SentenceRecognition，60 秒以内的短语音，松手后一次返回），对应安卓端 `TencentAsr`。
/// 需要在腾讯云控制台单独开通「语音识别」；TC3-HMAC-SHA256 签名，不引入腾讯云 SDK。
/// 文档：https://cloud.tencent.com/document/api/1093/35646
struct TencentAsr: Sendable {
    let secretId: String
    let secretKey: String

    var configured: Bool { !secretId.trimmed.isEmpty && !secretKey.trimmed.isEmpty }

    private static let host = "asr.tencentcloudapi.com"
    private static let service = "asr"
    private static let action = "SentenceRecognition"
    private static let version = "2019-06-14"

    /// 识别 16kHz / 单声道 / 16 位的 PCM 录音；hotwords 是热词，被服务拒绝时自动去掉热词重试一次
    func recognize(pcm: Data, hotwords: [String]) async throws -> String {
        if hotwords.isEmpty { return try await request(pcm, []) }
        do {
            return try await request(pcm, hotwords)
        } catch let e as AsrError where e.code.hasPrefix("InvalidParameter") {
            return try await request(pcm, [])
        }
    }

    private func request(_ pcm: Data, _ hotwords: [String]) async throws -> String {
        guard configured else { throw AsrError(message: "还没有配置腾讯云密钥") }
        let wav = Self.wav(pcm)
        var payload: [String: Any] = [
            "ProjectId": 0, "SubServiceType": 2, "EngSerViceType": "16k_zh", "SourceType": 1,
            "VoiceFormat": "wav", "UsrAudioKey": UUID().uuidString,
            "Data": wav.base64EncodedString(), "DataLen": wav.count,
            // 数字转阿拉伯数字（「三点半」→「3点半」），方便后面的日期时间识别
            "ConvertNumMode": 1,
        ]
        if !hotwords.isEmpty { payload["HotwordList"] = hotwords.map { "\($0)|8" }.joined(separator: ",") }
        let body = try JSONSerialization.data(withJSONObject: payload)

        let data: Data
        do {
            data = try await URLSession.shared.data(for: signed(body)).0
        } catch is URLError {
            throw AsrError(message: "网络不可用，无法识别语音", code: "Network")
        }
        guard let root = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["Response"] as? [String: Any] else {
            throw AsrError(message: "识别服务返回了无法解析的内容")
        }
        if let err = root["Error"] as? [String: Any] {
            let code = err["Code"] as? String ?? ""
            throw AsrError(message: Self.describe(code, err["Message"] as? String ?? ""), code: code)
        }
        return (root["Result"] as? String)?.trimmed ?? ""
    }

    private func signed(_ body: Data) -> URLRequest {
        let ts = Int(Date().timeIntervalSince1970)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        let date = f.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))

        let contentType = "application/json; charset=utf-8"
        let signedHeaders = "content-type;host;x-tc-action"
        let canonical = [
            "POST", "/", "",
            "content-type:\(contentType)\nhost:\(Self.host)\nx-tc-action:\(Self.action.lowercased())\n",
            signedHeaders, Self.sha256Hex(body),
        ].joined(separator: "\n")
        let scope = "\(date)/\(Self.service)/tc3_request"
        let toSign = ["TC3-HMAC-SHA256", String(ts), scope, Self.sha256Hex(Data(canonical.utf8))].joined(separator: "\n")

        let kDate = Self.hmac(Data("TC3\(secretKey.trimmed)".utf8), date)
        let kService = Self.hmac(kDate, Self.service)
        let kSigning = Self.hmac(kService, "tc3_request")
        let signature = Self.hmac(kSigning, toSign).map { String(format: "%02x", $0) }.joined()

        var req = URLRequest(url: URL(string: "https://\(Self.host)/")!, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.httpBody = body
        req.setValue("TC3-HMAC-SHA256 Credential=\(secretId.trimmed)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)", forHTTPHeaderField: "Authorization")
        req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        req.setValue(Self.action, forHTTPHeaderField: "X-TC-Action")
        req.setValue(Self.version, forHTTPHeaderField: "X-TC-Version")
        req.setValue(String(ts), forHTTPHeaderField: "X-TC-Timestamp")
        return req
    }

    private static func sha256Hex(_ d: Data) -> String {
        SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
    }

    private static func hmac(_ key: Data, _ message: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: key)))
    }

    /// 给裸 PCM（16kHz / 单声道 / 16 位）加上 44 字节的 WAV 头
    static func wav(_ pcm: Data) -> Data {
        var h = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; h.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; h.append(Data(bytes: &x, count: 2)) }
        h.append(Data("RIFF".utf8)); u32(UInt32(36 + pcm.count))
        h.append(Data("WAVE".utf8)); h.append(Data("fmt ".utf8))
        u32(16); u16(1); u16(1); u32(16_000); u32(32_000); u16(2); u16(16)
        h.append(Data("data".utf8)); u32(UInt32(pcm.count))
        return h + pcm
    }

    private static func describe(_ code: String, _ message: String) -> String {
        switch true {
        case code.hasPrefix("AuthFailure.SecretIdNotFound"): return "SecretId 不存在，请检查设置里的密钥"
        case code.hasPrefix("AuthFailure.SignatureFailure"): return "SecretKey 不正确，请检查设置里的密钥"
        case code.hasPrefix("AuthFailure.SignatureExpire"): return "电脑时间与标准时间相差太大，请校准时间后重试"
        case code.hasPrefix("AuthFailure"): return "密钥验证失败（\(code)）"
        case code == "FailedOperation.UserNotRegistered", code.hasPrefix("UnauthorizedOperation"):
            return "还没有开通腾讯云「语音识别」，请到腾讯云控制台开通（有每月免费额度）"
        case code == "FailedOperation.ServiceIsolate", code == "ResourceUnavailable.InArrears": return "腾讯云账号已欠费"
        case code.hasPrefix("FailedOperation.NoFreeAmount"), code.hasPrefix("ResourceInsufficient"), code == "ResourceUnavailable.ResourcePackageRunOut":
            return "语音识别免费额度已用完，请到腾讯云控制台查看"
        case code.hasPrefix("RequestLimitExceeded"), code.hasPrefix("LimitExceeded"): return "识别请求太频繁，请稍后再试"
        default:
            let t = [code, message].filter { !$0.isEmpty }.joined(separator: "：")
            return t.isEmpty ? "识别失败" : t
        }
    }
}
