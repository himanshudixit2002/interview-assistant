import Foundation
import AVFoundation
import Speech
import CoreMedia

/// Thin wrapper over SpeechAnalyzer + SpeechTranscriber (macOS 26+): one input stream, converted to the
/// analyzer's preferred format, with results exposed as an async sequence. Mirrors the plan's
/// TranscriptionService contract (§6.4): partial/final segments with time ranges.
final class LocalTranscriber {
    let transcriber: SpeechTranscriber
    let analyzer: SpeechAnalyzer
    let format: AVAudioFormat
    private var converter: AVAudioConverter?
    private var converterInput: AVAudioFormat?
    private let stream: AsyncStream<AnalyzerInput>
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private(set) var fedSeconds: Double = 0
    private(set) var conversionFailures = 0
    let assetSetupMs: Double
    let prepareMs: Double

    private var startedAtInit = false

    init(locale: Locale, fast: Bool, vocabulary: [String] = [], vocabularyAtInit: Bool = false) async throws {
        let sw = Stopwatch()
        guard let resolved = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw NSError(domain: "spike", code: 1, userInfo: [NSLocalizedDescriptionKey: "locale \(locale.identifier) not supported by SpeechTranscriber"])
        }
        var reporting: Set<SpeechTranscriber.ReportingOption> = [.volatileResults]
        if fast { reporting.insert(.fastResults) }
        transcriber = SpeechTranscriber(locale: resolved, transcriptionOptions: [], reportingOptions: reporting, attributeOptions: [.audioTimeRange])
        let status = await AssetInventory.status(forModules: [transcriber])
        if status != .installed {
            log("speech assets for \(resolved.identifier): \(status); requesting install…")
            if let req = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await req.downloadAndInstall()
                log("assets installed")
            }
        }
        assetSetupMs = sw.ms
        (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        if !vocabulary.isEmpty {
            // F19 vocabulary pack: bias recognition toward company, product and library names.
            let context = AnalysisContext()
            context.contextualStrings = [.general: vocabulary]
            if vocabularyAtInit {
                analyzer = SpeechAnalyzer(inputSequence: stream, modules: [transcriber], options: nil, analysisContext: context)
                startedAtInit = true
            } else {
                analyzer = SpeechAnalyzer(modules: [transcriber])
                try await analyzer.setContext(context)
            }
        } else {
            analyzer = SpeechAnalyzer(modules: [transcriber])
        }
        guard let f = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw NSError(domain: "spike", code: 2, userInfo: [NSLocalizedDescriptionKey: "no compatible audio format"])
        }
        format = f
        let sw2 = Stopwatch()
        if !startedAtInit { try await analyzer.prepareToAnalyze(in: f) }
        prepareMs = sw2.ms
    }

    var results: some AsyncSequence<SpeechTranscriber.Result, Error> & Sendable { transcriber.results }

    func start() async throws { if !startedAtInit { try await analyzer.start(inputSequence: stream) } }

    /// Feed any PCM buffer; it is converted to the analyzer's format. `startTime` is optional media time.
    func feed(_ buffer: AVAudioPCMBuffer, startTime: CMTime? = nil) {
        guard buffer.frameLength > 0 else { return }
        let converted: AVAudioPCMBuffer
        if buffer.format == format {
            converted = buffer
        } else {
            if converter == nil || converterInput != buffer.format {
                converter = AVAudioConverter(from: buffer.format, to: format)
                converterInput = buffer.format
            }
            guard let converter else { return }
            let ratio = format.sampleRate / buffer.format.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
            var consumed = false
            var error: NSError?
            converter.convert(to: outBuf, error: &error) { _, status in
                if consumed { status.pointee = .noDataNow; return nil }
                consumed = true
                status.pointee = .haveData
                return buffer
            }
            if let error { conversionFailures += 1; if conversionFailures < 3 { log("convert error: \(error)") }; return }
            if outBuf.frameLength == 0 { conversionFailures += 1; return }
            converted = outBuf
        }
        fedSeconds += Double(converted.frameLength) / format.sampleRate
        if let startTime {
            continuation.yield(AnalyzerInput(buffer: converted, bufferStartTime: startTime))
        } else {
            continuation.yield(AnalyzerInput(buffer: converted))
        }
    }

    /// Forces finalization of everything fed so far (used by the pause-triggered endpoint experiment).
    func finalizeNow() async throws {
        try await analyzer.finalize(through: CMTime(seconds: fedSeconds, preferredTimescale: 16_000))
    }

    func finish() async throws {
        continuation.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
    }

    func cancel() async { await analyzer.cancelAndFinishNow() }
}

struct TranscriptOutcome {
    var firstPartialMs: Double = .nan      // wall ms from first audio fed to first volatile result
    var partialLags: [Double] = []         // wall ms behind the audio position, per volatile result
    var finalAfterAudioEndMs: Double = .nan // wall ms from end of audio to last final result
    var finalText = ""
    var partials = 0
    var finals = 0
    var audioSeconds: Double = 0
    var processingMs: Double = 0
}

enum Transcription {
    static func runFile(_ args: Args) async throws {
        guard let path = args.positional.first else { throw usage("transcribe-file <audio>") }
        let locale = Locale(identifier: args.string("locale", "en-US"))
        let t = try await LocalTranscriber(locale: locale, fast: args.has("fast"), vocabulary: args.list("vocab"), vocabularyAtInit: args.has("vocab-init"))
        out("assets_ready_ms=\(fmt(t.assetSetupMs)) prepare_ms=\(fmt(t.prepareMs)) format=\(Int(t.format.sampleRate))Hz")
        let o = try await transcribeFile(URL(fileURLWithPath: path), with: t, realtime: !args.has("no-realtime"), verbose: true)
        report(o, reference: args.flags["ref"])
    }

    static func runSet(_ args: Args) async throws {
        guard let dir = args.positional.first else { throw usage("transcribe-set <dir>") }
        let locale = Locale(identifier: args.string("locale", "en-US"))
        let listURL = URL(fileURLWithPath: dir).appendingPathComponent("questions.txt")
        let lines = try String(contentsOf: listURL, encoding: .utf8).split(separator: "\n")
        var rows: [(id: String, voice: String, ref: String)] = []
        for l in lines where !l.hasPrefix("#") && l.contains("|") {
            let p = l.split(separator: "|", maxSplits: 2).map(String.init)
            if p.count == 3 { rows.append((p[0], p[1], p[2])) }
        }
        out("| id | voice | audio s | 1st partial ms | partial lag p50/p95 ms | final after end ms | WER | hypothesis |")
        out("|---|---|---|---|---|---|---|---|")
        var allLags: [Double] = []
        var firsts: [Double] = []
        var finalsAfter: [Double] = []
        var errs = 0, refs = 0
        for r in rows {
            let url = URL(fileURLWithPath: dir).appendingPathComponent("\(r.id).aiff")
            guard FileManager.default.fileExists(atPath: url.path) else { out("| \(r.id) | \(r.voice) | missing audio |"); continue }
            // A fresh analyzer per utterance mirrors one question per segment and avoids cross-file timeline state.
            let t = try await LocalTranscriber(locale: locale, fast: args.has("fast"), vocabulary: args.list("vocab"), vocabularyAtInit: args.has("vocab-init"))
            let o = try await transcribeFile(url, with: t, realtime: !args.has("no-realtime"), verbose: false)
            let (e, n) = wordErrors(reference: r.ref, hypothesis: o.finalText)
            errs += e; refs += n
            allLags += o.partialLags
            if o.firstPartialMs.isFinite { firsts.append(o.firstPartialMs) }
            if o.finalAfterAudioEndMs.isFinite { finalsAfter.append(o.finalAfterAudioEndMs) }
            let lagText = o.partialLags.isEmpty ? "-" : "\(fmt(percentile(o.partialLags, 50)))/\(fmt(percentile(o.partialLags, 95)))"
            out("| \(r.id) | \(r.voice) | \(fmt(o.audioSeconds, 1)) | \(fmt(o.firstPartialMs)) | \(lagText) | \(fmt(o.finalAfterAudioEndMs)) | \(e)/\(n) | \(o.finalText.replacingOccurrences(of: "|", with: "/")) |")
        }
        out("")
        out("utterances=\(rows.count) WER=\(fmt(Double(errs) / Double(max(refs, 1)) * 100, 1))% (\(errs)/\(refs) tokens)")
        out("first_partial_ms p50=\(fmt(percentile(firsts, 50))) p95=\(fmt(percentile(firsts, 95)))")
        out("partial_lag_ms p50=\(fmt(percentile(allLags, 50))) p95=\(fmt(percentile(allLags, 95))) n=\(allLags.count)")
        out("final_after_audio_end_ms p50=\(fmt(percentile(finalsAfter, 50))) p95=\(fmt(percentile(finalsAfter, 95)))")
        out("process_footprint_mb=\(fmt(residentFootprintMB(), 1))")
    }

    /// Feeds a file in 100 ms chunks. In realtime mode the chunks are paced like a live stream, so result
    /// timing can be compared with the audio position (plan §14.1 "partial transcription from audio reaching the app").
    static func transcribeFile(_ url: URL, with t: LocalTranscriber, realtime: Bool, verbose: Bool) async throws -> TranscriptOutcome {
        let file = try AVAudioFile(forReading: url)
        let inFormat = file.processingFormat
        let chunk = AVAudioFrameCount(inFormat.sampleRate / 10)
        var outcome = TranscriptOutcome()
        outcome.audioSeconds = Double(file.length) / inFormat.sampleRate

        let feedStart = DispatchTime.now()
        func wallMs() -> Double { Double(DispatchTime.now().uptimeNanoseconds - feedStart.uptimeNanoseconds) / 1_000_000 }
        var audioEndWallMs: Double = .nan

        try await t.start()
        let collector = Task { () -> TranscriptOutcome in
            var o = outcome
            var lastFinalWall: Double = .nan
            var finalParts: [String] = []
            for try await r in t.results {
                let now = wallMs()
                let text = String(r.text.characters)
                let end = CMTimeGetSeconds(r.range.end)
                if r.isFinal {
                    o.finals += 1
                    finalParts.append(text)
                    lastFinalWall = now
                    if verbose { out("  [final  @\(fmt(now)) ms, audio \(fmt(CMTimeGetSeconds(r.range.start), 2))–\(fmt(end, 2)) s] \(text)") }
                } else {
                    o.partials += 1
                    if !o.firstPartialMs.isFinite { o.firstPartialMs = now }
                    let lag = now - end * 1000
                    o.partialLags.append(lag)
                    if verbose { out("  [partial @\(fmt(now)) ms, lag \(fmt(lag)) ms] \(text)") }
                }
            }
            o.finalText = finalParts.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            o.finalAfterAudioEndMs = lastFinalWall - audioEndWallMs
            return o
        }

        var fed: AVAudioFramePosition = 0
        while fed < file.length {
            guard let buf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: chunk) else { break }
            try file.read(into: buf, frameCount: chunk)
            if buf.frameLength == 0 { break }
            fed += AVAudioFramePosition(buf.frameLength)
            t.feed(buf)
            if realtime {
                let target = Double(fed) / inFormat.sampleRate * 1000
                let ahead = target - wallMs()
                if ahead > 0 { try await Task.sleep(nanoseconds: UInt64(ahead * 1_000_000)) }
            }
        }
        audioEndWallMs = wallMs()
        try await t.finish()
        var result = try await collector.value
        result.processingMs = wallMs()
        result.finalAfterAudioEndMs = result.finalAfterAudioEndMs.isNaN ? .nan : result.finalAfterAudioEndMs
        // collector computed finalAfterAudioEndMs before audioEndWallMs was known in some orderings; recompute safely.
        if result.finals > 0 { result.finalAfterAudioEndMs = result.processingMs - audioEndWallMs }
        return result
    }

    static func report(_ o: TranscriptOutcome, reference: String?) {
        out("")
        out("audio_s=\(fmt(o.audioSeconds, 2)) processing_ms=\(fmt(o.processingMs)) rtf=\(fmt(o.processingMs / 1000 / max(o.audioSeconds, 0.001), 2))")
        out("partials=\(o.partials) finals=\(o.finals) first_partial_ms=\(fmt(o.firstPartialMs)) partial_lag_p50=\(fmt(percentile(o.partialLags, 50))) p95=\(fmt(percentile(o.partialLags, 95))) final_after_audio_end_ms=\(fmt(o.finalAfterAudioEndMs))")
        out("final: \(o.finalText)")
        if let reference {
            let (e, n) = wordErrors(reference: reference, hypothesis: o.finalText)
            out("ref:   \(reference)")
            out("WER=\(fmt(Double(e) / Double(max(n, 1)) * 100, 1))% (\(e)/\(n))")
        }
        out("process_footprint_mb=\(fmt(residentFootprintMB(), 1))")
    }

    static func usage(_ s: String) -> Error {
        NSError(domain: "spike", code: 2, userInfo: [NSLocalizedDescriptionKey: "usage: spike \(s)"])
    }
}
