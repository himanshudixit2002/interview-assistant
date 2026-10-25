import Foundation
import ScreenCaptureKit
import Vision
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
import AppKit

/// Day-5 spike (plan §18.9): capture one selected window with ScreenCaptureKit and run local Vision OCR,
/// keeping geometry so code indentation can be reconstructed (F26, F30). Never captures a whole display.
enum ScreenOCR {
    struct Line { let text: String; let confidence: Float; let box: CGRect } // box in image pixels, top-left origin

    static func run(_ args: Args) async throws {
        let total = Stopwatch()
        var renderWindow: NSWindow?
        var expectPath = args.flags["expect"]
        let window: SCWindow
        let sw = Stopwatch()
        if let renderPath = args.flags["render"] {
            // Render the file in this process's own window on the desktop Space, without activating the app,
            // so the capture path is exercised on a window that is not in the user's current Space.
            let text = try String(contentsOfFile: renderPath, encoding: .utf8)
            let title = "spike-render " + URL(fileURLWithPath: renderPath).lastPathComponent
            let w = await MainActor.run { () -> NSWindow in
                let w = makeRenderWindow(text: text, title: title)
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.8))
                return w
            }
            renderWindow = w
            if expectPath == nil { expectPath = renderPath }
            let myID = CGWindowID(w.windowNumber)
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
            guard let found = content.windows.first(where: { $0.windowID == myID }) else {
                throw NSError(domain: "spike", code: 3, userInfo: [NSLocalizedDescriptionKey: "rendered window \(myID) not listed by ScreenCaptureKit"])
            }
            window = found
        } else {
            guard let query = args.positional.first else { throw Transcription.usage("ocr-window <title-substring> | --render <file>") }
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
            let matches = content.windows.filter { w in
                w.windowLayer == 0 && w.frame.width > 50 && w.frame.height > 50 &&
                ((w.title ?? "").localizedCaseInsensitiveContains(query) ||
                 (w.owningApplication?.applicationName ?? "").localizedCaseInsensitiveContains(query))
            }
            guard let best = matches.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else {
                throw NSError(domain: "spike", code: 3, userInfo: [NSLocalizedDescriptionKey: "no window matching '\(query)'"])
            }
            window = best
        }
        defer { if let renderWindow { Task { @MainActor in renderWindow.orderOut(nil) } } }
        out("window [\(window.windowID)] \(window.owningApplication?.applicationName ?? "?") — \(window.title ?? "") frame=\(window.frame) on_screen=\(window.isOnScreen) (enumerate \(fmt(sw.ms)) ms)")

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = CGFloat(filter.pointPixelScale)
        let config = SCStreamConfiguration()
        config.width = Int(filter.contentRect.width * scale)
        config.height = Int(filter.contentRect.height * scale)
        config.showsCursor = false
        config.captureResolution = .best
        let cropTop = CGFloat(args.double("crop-top", 0))
        if cropTop > 0 {
            // Region capture (F27): exclude the title bar so the window chrome never reaches OCR.
            config.sourceRect = CGRect(x: 0, y: cropTop, width: filter.contentRect.width, height: filter.contentRect.height - cropTop)
            config.height = Int((filter.contentRect.height - cropTop) * scale)
        }
        let sw2 = Stopwatch()
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        out("captured \(image.width)x\(image.height) px at scale \(scale) in \(fmt(sw2.ms)) ms")

        if let png = args.flags["png"] { try writePNG(image, to: png); out("saved \(png)") }

        let code = args.has("code")
        var request = RecognizeTextRequest()
        request.recognitionLevel = args.has("fast-ocr") ? .fast : .accurate
        request.usesLanguageCorrection = !code   // language correction damages code (plan §8.2)
        request.recognitionLanguages = [Locale.Language(identifier: "en-US")]
        if code { request.customWords = ["def", "elif", "enumerate", "ValueError", "len", "range", "sorted"] }
        let sw3 = Stopwatch()
        let observations = try await request.perform(on: image)
        let ocrMs = sw3.ms
        let size = CGSize(width: image.width, height: image.height)
        var lines: [Line] = []
        for obs in observations {
            guard let cand = obs.topCandidates(1).first else { continue }
            let xs = [obs.topLeft.x, obs.topRight.x, obs.bottomLeft.x, obs.bottomRight.x]
            let ys = [obs.topLeft.y, obs.topRight.y, obs.bottomLeft.y, obs.bottomRight.y]
            let minX = xs.min()!, maxX = xs.max()!, minY = ys.min()!, maxY = ys.max()!
            // Vision uses a lower-left origin; convert to top-left pixel coordinates.
            let box = CGRect(x: minX * size.width, y: (1 - maxY) * size.height, width: (maxX - minX) * size.width, height: (maxY - minY) * size.height)
            lines.append(Line(text: cand.string, confidence: cand.confidence, box: box))
        }
        lines.sort { a, b in
            if abs(a.box.midY - b.box.midY) > min(a.box.height, b.box.height) * 0.5 { return a.box.midY < b.box.midY }
            return a.box.minX < b.box.minX
        }
        out("ocr \(observations.count) observations in \(fmt(ocrMs)) ms (level=\(args.has("fast-ocr") ? "fast" : "accurate"), languageCorrection=\(!code)); total \(fmt(total.ms)) ms")
        let lowConf = lines.filter { $0.confidence < 0.5 }
        out("confidence: min=\(fmt(Double(lines.map(\.confidence).min() ?? 0), 2)) low(<0.5)=\(lowConf.count)")

        // Indentation reconstruction: estimate monospace character width from the widest line, then
        // convert each line's x offset from the left margin into leading spaces.
        let reconstructed = reconstruct(lines)
        out("\n--- reconstructed text ---")
        for (l, text) in zip(lines, reconstructed) {
            let flag = l.confidence < 0.5 ? " ⚠︎\(fmt(Double(l.confidence), 2))" : ""
            out(text + flag)
        }

        if let expectPath {
            let expected = try String(contentsOfFile: expectPath, encoding: .utf8)
            compare(expected: expected, actual: reconstructed)
        }
        if let renderWindow {
            await MainActor.run { renderWindow.orderOut(nil) }
        }
    }

    /// Groups observations into rows (same vertical band), then lays each row out by x position using an
    /// estimated monospace character width, so indentation and intra-line gaps survive (F30).
    static func reconstruct(_ lines: [Line]) -> [String] {
        guard !lines.isEmpty else { return [] }
        let leftMargin = lines.map(\.box.minX).min()!
        let widths = lines.filter { $0.text.count >= 12 }.map { $0.box.width / CGFloat($0.text.count) }
        let charW = widths.isEmpty ? (lines.map { $0.box.width / CGFloat(max($0.text.count, 1)) }.max() ?? 10) : widths.sorted()[widths.count / 2]
        var rows: [[Line]] = []
        for l in lines {
            if let last = rows.last, let ref = last.first, abs(ref.box.midY - l.box.midY) < min(ref.box.height, l.box.height) * 0.6 {
                rows[rows.count - 1].append(l)
            } else {
                rows.append([l])
            }
        }
        return rows.map { row in
            var text = ""
            var cursor = 0
            for seg in row.sorted(by: { $0.box.minX < $1.box.minX }) {
                let col = Int(((seg.box.minX - leftMargin) / charW).rounded())
                if col > cursor { text += String(repeating: " ", count: col - cursor) } else if !text.isEmpty { text += " " }
                text += seg.text
                cursor = col + seg.text.count
            }
            return text
        }
    }

    static func compare(expected: String, actual: [String]) {
        let exp = expected.split(separator: "\n", omittingEmptySubsequences: false).map { String($0).trimmingTrailingSpaces() }.filter { !$0.isEmpty }
        let act = actual.map { $0.trimmingTrailingSpaces() }.filter { !$0.isEmpty }
        var remaining = act
        var exact = 0, indentOnly = 0
        var missed: [String] = []
        for e in exp {
            if let i = remaining.firstIndex(of: e) { exact += 1; remaining.remove(at: i); continue }
            if let i = remaining.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == e.trimmingCharacters(in: .whitespaces) }) { indentOnly += 1; remaining.remove(at: i); continue }
            missed.append(e)
        }
        let (charErr, charTotal) = charDistance(exp.joined(separator: "\n"), act.joined(separator: "\n"))
        out("\n--- comparison: \(exp.count) expected lines, \(act.count) recognized ---")
        out("lines_exact=\(exact)/\(exp.count) indent_only_mismatch=\(indentOnly) unmatched_expected=\(missed.count) extra_recognized=\(remaining.count) char_error_rate=\(fmt(Double(charErr) / Double(max(charTotal, 1)) * 100, 1))%")
        for m in missed { out("  missing: \(m)") }
        for r in remaining { out("  extra:   \(r)") }
    }

    static func charDistance(_ a: String, _ b: String) -> (Int, Int) {
        let x = Array(a), y = Array(b)
        if x.isEmpty { return (y.count, 0) }
        var prev = Array(0...y.count), cur = Array(repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            cur[0] = i
            for j in stride(from: 1, through: y.count, by: 1) {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            if y.isEmpty { cur = [i] }
            swap(&prev, &cur)
        }
        return (prev[y.count], x.count)
    }

    @MainActor
    static func makeRenderWindow(text: String, title: String) -> NSWindow {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let rect = NSRect(x: 120, y: 120, width: 1100, height: 760)
        let w = NSWindow(contentRect: rect, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = title
        w.isReleasedWhenClosed = false
        let scroll = NSScrollView(frame: w.contentView!.bounds)
        scroll.autoresizingMask = [.width, .height]
        let tv = NSTextView(frame: scroll.bounds)
        tv.isEditable = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        tv.textContainerInset = NSSize(width: 18, height: 18)
        tv.string = text
        scroll.documentView = tv
        w.contentView = scroll
        w.orderFrontRegardless()
        w.displayIfNeeded()
        return w
    }

    static func writePNG(_ image: CGImage, to path: String) throws {
        let url = URL(fileURLWithPath: path)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw NSError(domain: "spike", code: 4, userInfo: [NSLocalizedDescriptionKey: "cannot create \(path)"])
        }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }
}

extension String {
    func trimmingTrailingSpaces() -> String {
        var s = Substring(self)
        while let last = s.last, last == " " || last == "\t" { s.removeLast() }
        return String(s)
    }
}
