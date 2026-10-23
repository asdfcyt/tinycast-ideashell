import Foundation
import ImageIO
import Vision

/// 截图文字识别：用系统自带的 Vision，在本机识别，图片不会上传到别处。
/// 保存截图为笔记时，把图里的字附在笔记正文里，之后在闪念贝壳里也能搜到。
enum ImageOCR {
    static let key = "capture.ocr"

    static var enabled: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }

    /// 识别一张图里的文字，按从上到下、从左到右的阅读顺序拼成多行；没有文字返回空串
    nonisolated static func text(in data: Data) -> String {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil),
              cg.width >= 24, cg.height >= 24 else { return "" }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        do { try VNImageRequestHandler(cgImage: cg, options: [:]).perform([request]) } catch { return "" }

        let items = (request.results ?? []).compactMap { o -> (box: CGRect, text: String)? in
            guard let t = o.topCandidates(1).first?.string.trimmingCharacters(in: .whitespaces), !t.isEmpty else { return nil }
            return (o.boundingBox, t)
        }
        // Vision 的坐标原点在左下角：y 大的在上面。同一行（y 相差不到半个行高）按 x 排
        let sorted = items.sorted { a, b in
            let tol = min(a.box.height, b.box.height) * 0.5
            if abs(a.box.midY - b.box.midY) > tol { return a.box.midY > b.box.midY }
            return a.box.minX < b.box.minX
        }
        return String(sorted.map(\.text).joined(separator: "\n").prefix(6000))
    }
}
