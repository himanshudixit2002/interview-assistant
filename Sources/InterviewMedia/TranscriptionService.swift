import Foundation
import AVFoundation
import Speech
import CoreMedia
import InterviewCore

public struct TranscriptEvent: Sendable, Equatable {
    public enum Kind: Sendable { case partial, final, gap }
    public var kind: Kind
    public var text: String
    public var start: TimeInterval
    public var end: TimeInterval
    public var receivedAt: Date
}

/// Local speech via SpeechAnalyzer/SpeechTranscriber (macOS 26+). Fast-results mode gives ~1 s partials and
/// 0.4–1.0 s finals after a pause (Phase 0). Buffers are fed contiguously without host timestamps, because
/// per-buffer start times silenced the engine in the spike; gaps are reported separately.
public final class TranscriptionService: @unchecked Sendable {
    public struct LocaleStatus: Sendable, Equatable {
        public let supported: Bool; public let installed: Bool; public let identifier: String
        public init(supported: Bool, installed: Bool, identifier: String) { self.supported = supported; self.installed = installed; self.identifier = identifier }
    }

    private var transcriber: SpeechTranscriber?
    private var analyzer: SpeechAnalyzer?
    private var format: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var converterInput: AVAudioFormat?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private let lock = NSLock()
    private var fedSeconds: Double = 0
    private var lastHostTime: CMTime?
    private var eventsContinuation: AsyncStream<TranscriptEvent>.Continuation?
    public private(set) var isRunning = false
    public var corrector: VocabularyCorrector?

    public init() {}

    public static var isAvailable: Bool { SpeechTranscriber.isAvailable }

    public static func localeStatus(_ identifier: String) async -> LocaleStatus {
        guard let equivalent = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: identifier)) else {
            return LocaleStatus(supported: false, installed: false, identifier: identifier)
        }
        let installed = await SpeechTranscriber.installedLocales.contains { $0.identifier == equivalent.identifier }
        return LocaleStatus(supported: true, installed: installed, identifier: equivalent.identifier)
    }

    /// Downloads assets if needed. Progress is reported through the returned Progress when a download starts.
    public static func ensureAssets(locale: Locale) async throws -> Progress? {
        let t = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        let status = await AssetInventory.status(forModules: [t])
        guard status != .installed, let request = try await AssetInventory.assetInstallationRequest(supporting: [t]) else { return nil }
        let progress = request.progress
        try await request.downloadAndInstall()
        return progress
    }

    /// Starts a new analyzer and returns the event stream for this run; each start gets its own stream so a
    /// paused and resumed session keeps receiving events (an AsyncStream has a single consumer).
    @discardableResult
    public func start(locale: Locale, fastResults: Bool = true) async throws -> AsyncStream<TranscriptEvent> {
        try await stop()
        guard let resolved = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else { throw AssistantError.unsupportedCapability("speech locale \(locale.identifier)") }
        var reporting: Set<SpeechTranscriber.ReportingOption> = [.volatileResults]
        if fastResults { reporting.insert(.fastResults) }
        let transcriber = SpeechTranscriber(locale: resolved, transcriptionOptions: [], reportingOptions: reporting, attributeOptions: [.audioTimeRange])
        if await AssetInventory.status(forModules: [transcriber]) != .installed, let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else { throw AssistantError.unsupportedCapability("speech audio format") }
        try await analyzer.prepareToAnalyze(in: format)
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let (events, sink) = AsyncStream<TranscriptEvent>.makeStream()
        lock.lock()
        self.transcriber = transcriber; self.analyzer = analyzer; self.format = format; self.continuation = continuation; self.eventsContinuation = sink
        fedSeconds = 0; lastHostTime = nil; isRunning = true
        lock.unlock()
        try await analyzer.start(inputSequence: stream)
        let corrector = self.corrector
        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    var text = String(result.text.characters).trimmingCharacters(in: .whitespaces)
                    if result.isFinal, let corrector { text = corrector.correct(text).text }
                    sink.yield(TranscriptEvent(kind: result.isFinal ? .final : .partial, text: text, start: CMTimeGetSeconds(result.range.start), end: CMTimeGetSeconds(result.range.end), receivedAt: Date()))
                }
            } catch {
                if !(error is CancellationError) { sink.yield(TranscriptEvent(kind: .gap, text: "transcription stopped: \(error)", start: self?.fedSeconds ?? 0, end: self?.fedSeconds ?? 0, receivedAt: Date())) }
            }
            sink.finish()
        }
        return events
    }

    /// Feeds captured audio. A host-time jump larger than one second is reported as a gap marker (F22).
    public func feed(_ chunk: AudioChunk) {
        lock.lock()
        guard isRunning, let format, let continuation else { lock.unlock(); return }
        if let last = lastHostTime {
            let gap = CMTimeGetSeconds(CMTimeSubtract(chunk.hostTime, last))
            if gap > 1.0 { eventsContinuation?.yield(TranscriptEvent(kind: .gap, text: "audio gap of \(Int(gap)) s", start: fedSeconds, end: fedSeconds + gap, receivedAt: Date())) }
        }
        lastHostTime = CMTimeAdd(chunk.hostTime, CMTime(seconds: Double(chunk.buffer.frameLength) / chunk.buffer.format.sampleRate, preferredTimescale: 1_000_000_000))
        let converted: AVAudioPCMBuffer?
        if chunk.buffer.format == format { converted = chunk.buffer }
        else {
            if converter == nil || converterInput != chunk.buffer.format { converter = AVAudioConverter(from: chunk.buffer.format, to: format); converterInput = chunk.buffer.format }
            let ratio = format.sampleRate / chunk.buffer.format.sampleRate
            let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Double(chunk.buffer.frameLength) * ratio) + 64)
            var consumed = false
            var error: NSError?
            converter?.convert(to: out!, error: &error) { _, status in
                if consumed { status.pointee = .noDataNow; return nil }
                consumed = true; status.pointee = .haveData; return chunk.buffer
            }
            converted = error == nil ? out : nil
        }
        if let converted, converted.frameLength > 0 {
            fedSeconds += Double(converted.frameLength) / format.sampleRate
            continuation.yield(AnalyzerInput(buffer: converted))
        }
        lock.unlock()
    }

    public var secondsFed: Double { lock.lock(); defer { lock.unlock() }; return fedSeconds }

    /// Forces finalization of everything fed so far (used after a detected pause). Returned in ~70 ms in Phase 0.
    public func finalizeNow() async throws {
        lock.lock(); let analyzer = self.analyzer; let through = fedSeconds; lock.unlock()
        try await analyzer?.finalize(through: CMTime(seconds: through, preferredTimescale: 16_000))
    }

    public func stop() async throws {
        lock.lock()
        let analyzer = self.analyzer
        let continuation = self.continuation
        let sink = self.eventsContinuation
        self.analyzer = nil; self.continuation = nil; self.transcriber = nil; self.eventsContinuation = nil; isRunning = false
        lock.unlock()
        continuation?.finish()
        if let analyzer { try? await analyzer.finalizeAndFinishThroughEndOfInput() }
        resultsTask?.cancel(); resultsTask = nil
        sink?.finish()
    }
}
