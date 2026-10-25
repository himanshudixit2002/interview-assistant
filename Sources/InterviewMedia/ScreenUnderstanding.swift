import Foundation
import Vision
import CoreGraphics
import InterviewCore

public struct OCRResult: Sendable, Equatable {
    public var text: String
    public var regions: [OCRRegion]
    public var looksLikeCode: Bool
    public var contentHash: String
    public var durationMs: Double
    public var lowConfidenceLines: Int
    public init(text: String, regions: [OCRRegion], looksLikeCode: Bool, contentHash: String, durationMs: Double, lowConfidenceLines: Int) {
        self.text = text; self.regions = regions; self.looksLikeCode = looksLikeCode; self.contentHash = contentHash; self.durationMs = durationMs; self.lowConfidenceLines = lowConfidenceLines
    }
}

/// Local OCR with code-aware settings and row reconstruction (F26, F30, §8.2). Accurate level only: the fast
/// level returned nothing on dark-theme code in Phase 0. `warmUp()` absorbs the one-time ~28 s model load.
public final class ScreenUnderstanding: @unchecked Sendable {
    public init() {}

    public func warmUp() async {
        let size = 64
        guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        if let image = ctx.makeImage() { _ = try? await recognize(image: image, codeHint: false) }
    }

    public func recognize(image: CGImage, codeHint: Bool) async throws -> OCRResult {
        let start = DispatchTime.now()
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = !codeHint
        request.recognitionLanguages = [Locale.Language(identifier: "en-US")]
        if codeHint { request.customWords = ["def", "elif", "return", "func", "const", "let", "var", "null", "None", "True", "False", "import", "class", "self", "async", "await"] }
        let observations = try await request.perform(on: image)
        let size = CGSize(width: image.width, height: image.height)
        struct Line { let text: String; let confidence: Float; let box: CGRect }
        var lines: [Line] = []
        for obs in observations {
            guard let cand = obs.topCandidates(1).first else { continue }
            let xs = [obs.topLeft.x, obs.topRight.x, obs.bottomLeft.x, obs.bottomRight.x]
            let ys = [obs.topLeft.y, obs.topRight.y, obs.bottomLeft.y, obs.bottomRight.y]
            let minX = xs.min()!, maxX = xs.max()!, minY = ys.min()!, maxY = ys.max()!
            lines.append(Line(text: cand.string, confidence: cand.confidence, box: CGRect(x: minX * size.width, y: (1 - maxY) * size.height, width: (maxX - minX) * size.width, height: (maxY - minY) * size.height)))
        }
        lines.sort { a, b in
            if abs(a.box.midY - b.box.midY) > min(a.box.height, b.box.height) * 0.5 { return a.box.midY < b.box.midY }
            return a.box.minX < b.box.minX
        }
        // Row grouping and indentation from geometry.
        var rows: [[Line]] = []
        for l in lines {
            if let last = rows.last, let ref = last.first, abs(ref.box.midY - l.box.midY) < min(ref.box.height, l.box.height) * 0.6 { rows[rows.count - 1].append(l) } else { rows.append([l]) }
        }
        let leftMargin = lines.map(\.box.minX).min() ?? 0
        let widths = lines.filter { $0.text.count >= 12 }.map { $0.box.width / CGFloat($0.text.count) }
        let charW = widths.isEmpty ? (lines.map { $0.box.width / CGFloat(max($0.text.count, 1)) }.max() ?? 10) : widths.sorted()[widths.count / 2]
        let reconstructed = rows.map { row -> String in
            var text = ""; var cursor = 0
            for seg in row.sorted(by: { $0.box.minX < $1.box.minX }) {
                let col = Int(((seg.box.minX - leftMargin) / charW).rounded())
                if col > cursor { text += String(repeating: " ", count: col - cursor) } else if !text.isEmpty { text += " " }
                text += seg.text; cursor = col + seg.text.count
            }
            return text
        }.joined(separator: "\n")
        let normalized = OCRNormalizer.normalize(reconstructed)
        let regions = lines.map { OCRRegion(text: $0.text, confidence: Double($0.confidence), x: $0.box.minX / size.width, y: $0.box.minY / size.height, width: $0.box.width / size.width, height: $0.box.height / size.height) }
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
        return OCRResult(text: normalized, regions: regions, looksLikeCode: codeHint || OCRNormalizer.looksLikeCode(normalized), contentHash: TextHash.sha256(normalized), durationMs: ms, lowConfidenceLines: lines.filter { $0.confidence < 0.5 }.count)
    }

    /// Meaningful-change test (F29, §8.3): hash plus numeric-constraint comparison so a one-digit change
    /// ("one million" → "one billion", "<=" → "<") is never dismissed as noise.
    public static func changed(previous: OCRResult?, current: OCRResult) -> Bool {
        guard let previous else { return true }
        if previous.contentHash == current.contentHash { return false }
        let a = Set(Tokenizer.words(previous.text)), b = Set(Tokenizer.words(current.text))
        let numbersA = a.filter { $0.first?.isNumber == true }, numbersB = b.filter { $0.first?.isNumber == true }
        if numbersA != numbersB { return true }
        let union = a.union(b).count
        return union == 0 ? false : Double(a.symmetricDifference(b).count) / Double(union) > 0.02
    }
}
