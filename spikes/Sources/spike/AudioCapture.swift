import Foundation
import AVFoundation
import ScreenCaptureKit
import CoreMedia

/// Day-3 spike (plan §18.9, §7.1): capture system audio with ScreenCaptureKit, app-scoped when --app is
/// given (the scope ScreenCaptureKit actually offers), show a level meter, and feed a live local
/// transcriber. Excludes this process's own audio. No microphone. Writes an optional WAV for inspection.
final class AudioTap: NSObject, SCStreamOutput, SCStreamDelegate {
    let onBuffer: (AVAudioPCMBuffer, CMTime) -> Void
    var dropped = 0
    init(onBuffer: @escaping (AVAudioPCMBuffer, CMTime) -> Void) { self.onBuffer = onBuffer }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid else { return }
        guard let desc = CMSampleBufferGetFormatDescription(sampleBuffer) else { dropped += 1; return }
        let format = AVAudioFormat(cmAudioFormatDescription: desc)
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0, let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { dropped += 1; return }
        pcm.frameLength = AVAudioFrameCount(frames)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(frames), into: pcm.mutableAudioBufferList)
        guard status == noErr else { dropped += 1; return }
        onBuffer(pcm, CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        log("stream stopped with error: \(error)")
    }
}

enum AudioCapture {
    static func run(_ args: Args) async throws {
        let seconds = args.double("seconds", 12)
        let locale = Locale(identifier: args.string("locale", "en-US"))
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        guard let display = content.displays.first else { throw NSError(domain: "spike", code: 5, userInfo: [NSLocalizedDescriptionKey: "no display"]) }

        let filter: SCContentFilter
        if let appName = args.flags["app"] {
            guard let app = content.applications.first(where: { $0.applicationName.localizedCaseInsensitiveContains(appName) }) else {
                let names = Set(content.applications.map(\.applicationName)).sorted()
                throw NSError(domain: "spike", code: 6, userInfo: [NSLocalizedDescriptionKey: "no running app matching '\(appName)'. Known: \(names.joined(separator: ", "))"])
            }
            filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])
            out("scope: audio of application '\(app.applicationName)' (\(app.bundleIdentifier), pid \(app.processID)) — ScreenCaptureKit scopes audio per app, not per window/tab")
        } else if args.has("all") {
            filter = SCContentFilter(display: display, excludingWindows: [])
            out("scope: all system audio on display \(display.displayID) (excluding this process)")
        } else {
            throw NSError(domain: "spike", code: 7, userInfo: [NSLocalizedDescriptionKey: "pass --app <name> or --all; the product never captures without an explicit source choice"])
        }

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 1
        // Video is not consumed; keep it as cheap as the API allows.
        config.width = 64
        config.height = 64
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.showsCursor = false

        let transcriber = try await LocalTranscriber(locale: locale, fast: args.has("fast"), vocabulary: args.list("vocab"), vocabularyAtInit: args.has("vocab-init"))
        out("transcriber ready (assets \(fmt(transcriber.assetSetupMs)) ms, prepare \(fmt(transcriber.prepareMs)) ms, \(Int(transcriber.format.sampleRate)) Hz)")

        var wav: AVAudioFile?
        if let wavPath = args.flags["wav"] {
            let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false]
            wav = try AVAudioFile(forWriting: URL(fileURLWithPath: wavPath), settings: settings)
        }

        let queue = DispatchQueue(label: "spike.audio")
        let state = CaptureState()
        state.usePTS = args.has("pts")
        let tap = AudioTap { buffer, pts in
            state.ingest(buffer, pts: pts, transcriber: transcriber, wav: wav)
        }
        let stream = SCStream(filter: filter, configuration: config, delegate: tap)
        try stream.addStreamOutput(tap, type: .audio, sampleHandlerQueue: queue)

        try await transcriber.start()
        let results = Task {
            for try await r in transcriber.results {
                let text = String(r.text.characters)
                let audioEnd = CMTimeGetSeconds(r.range.end)
                let lag = state.wallSecondsSinceFirstBuffer() - audioEnd
                out("  \(clock()) \(r.isFinal ? "FINAL  " : "partial") audio≤\(fmt(audioEnd, 2))s lag=\(fmt(lag * 1000)) ms: \(text)")
                if !r.isFinal { state.partialLags.append(lag * 1000) } else { state.finals += 1 }
            }
        }

        let sw = Stopwatch()
        try await stream.startCapture()
        out("\(clock()) capture started in \(fmt(sw.ms)) ms; listening for \(fmt(seconds, 0)) s")
        let end = Date().addingTimeInterval(seconds)
        var lastMeter = -1
        let endpointMs = args.double("endpoint-ms", 0)
        while Date() < end {
            try await Task.sleep(nanoseconds: 100_000_000)
            if endpointMs > 0, let silent = state.shouldEndpoint(pauseMs: endpointMs) {
                let fsw = Stopwatch()
                try await transcriber.finalizeNow()
                out("  \(clock()) endpoint: \(fmt(silent)) ms of silence after speech → finalize(through:) returned in \(fmt(fsw.ms)) ms")
            }
            let sec = Int(sw.ms / 1000)
            if sec != lastMeter {
                lastMeter = sec
                out("  \(clock()) t=\(sec)s level=\(fmt(state.recentDbfs(), 1)) dBFS buffers=\(state.buffers) audio=\(fmt(state.audioSeconds, 1))s first_sound=\(state.firstSoundClock ?? "-")")
            }
        }
        try await stream.stopCapture()
        let stopMs = Stopwatch()
        try await transcriber.finish()
        _ = try? await results.value
        out("\(clock()) stopped; finalize took \(fmt(stopMs.ms)) ms")
        out("")
        out("buffers=\(state.buffers) dropped=\(tap.dropped) audio_s=\(fmt(state.audioSeconds, 1)) fed_s=\(fmt(transcriber.fedSeconds, 1)) conversion_failures=\(state.conversionFailures) peak_dbfs=\(fmt(state.peakDbfs, 1)) first_sound_at=\(state.firstSoundClock ?? "none") finals=\(state.finals)")
        out("partial_lag_ms p50=\(fmt(percentile(state.partialLags, 50))) p95=\(fmt(percentile(state.partialLags, 95))) n=\(state.partialLags.count)")
        out("process_footprint_mb=\(fmt(residentFootprintMB(), 1))")
    }
}

final class CaptureState {
    private let lock = NSLock()
    private(set) var buffers = 0
    private(set) var audioSeconds: Double = 0
    private(set) var peakDbfs: Double = -120
    private var recent: [Double] = []
    private var firstPTS: CMTime?
    private var firstWall: DispatchTime?
    private(set) var firstSoundClock: String?
    var partialLags: [Double] = []
    var finals = 0
    var usePTS = false
    var conversionFailures = 0
    private var lastSpeechWall: DispatchTime?
    private var speechSinceFinalize = false
    private(set) var endpointTriggers: [Double] = []   // wall ms from last speech to finalize call
    var finalizedWallMarks: [DispatchTime] = []

    func ingest(_ buffer: AVAudioPCMBuffer, pts: CMTime, transcriber: LocalTranscriber, wav: AVAudioFile?) {
        lock.lock()
        buffers += 1
        if firstPTS == nil { firstPTS = pts; firstWall = DispatchTime.now() }
        audioSeconds += Double(buffer.frameLength) / buffer.format.sampleRate
        let db = dbfs(buffer)
        recent.append(db); if recent.count > 20 { recent.removeFirst() }
        if db > peakDbfs { peakDbfs = db }
        if firstSoundClock == nil, db > -50 { firstSoundClock = clock() }
        if db > -45 { lastSpeechWall = DispatchTime.now(); speechSinceFinalize = true }
        let rel = CMTimeSubtract(pts, firstPTS!)
        lock.unlock()
        // Per-buffer start times are optional for the analyzer; compare both behaviours with --pts.
        transcriber.feed(buffer, startTime: usePTS ? rel : nil)
        conversionFailures = transcriber.conversionFailures
        if let wav {
            if buffer.format.sampleRate == wav.processingFormat.sampleRate, buffer.format.channelCount == wav.processingFormat.channelCount {
                try? wav.write(from: buffer)
            }
        }
    }

    func recentDbfs() -> Double { lock.lock(); defer { lock.unlock() }; return recent.max() ?? -120 }

    /// Returns true once when speech has been followed by `pauseMs` of silence; the caller then finalizes.
    func shouldEndpoint(pauseMs: Double) -> Double? {
        lock.lock(); defer { lock.unlock() }
        guard speechSinceFinalize, let last = lastSpeechWall else { return nil }
        let silent = Double(DispatchTime.now().uptimeNanoseconds - last.uptimeNanoseconds) / 1_000_000
        guard silent >= pauseMs else { return nil }
        speechSinceFinalize = false
        endpointTriggers.append(silent)
        finalizedWallMarks.append(DispatchTime.now())
        return silent
    }

    func wallSecondsSinceFirstBuffer() -> Double {
        lock.lock(); defer { lock.unlock() }
        guard let firstWall else { return 0 }
        return Double(DispatchTime.now().uptimeNanoseconds - firstWall.uptimeNanoseconds) / 1_000_000_000
    }

    private func dbfs(_ b: AVAudioPCMBuffer) -> Double {
        let n = Int(b.frameLength)
        guard n > 0 else { return -120 }
        var sum: Double = 0
        if let f = b.floatChannelData {
            for i in 0..<n { let v = Double(f[0][i]); sum += v * v }
        } else if let s = b.int16ChannelData {
            for i in 0..<n { let v = Double(s[0][i]) / 32768; sum += v * v }
        } else { return -120 }
        let rms = sqrt(sum / Double(n))
        return rms > 0 ? 20 * log10(rms) : -120
    }
}
