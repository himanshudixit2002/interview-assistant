import Foundation
import CoreAudio
import AudioToolbox
import AVFoundation
import CoreMedia

/// Alternative audio route (macOS 14.2+): a Core Audio process tap. Compared with ScreenCaptureKit audio
/// (plan §7.1) it is per-process rather than per-app-bundle, works for processes without a bundle, can
/// silence the tapped process at the speaker (`muteBehavior`), and needs the narrower "System Audio
/// Recording Only" permission instead of Screen Recording. Candidate for a captions-only mode (§3.4, §12.1).
enum ProcessTap {
    struct TapError: Error, CustomStringConvertible { let what: String; let status: OSStatus; var description: String { "\(what) failed: \(status) (\(fourCC(status)))" } }

    static func run(_ args: Args) async throws {
        guard let pidValue = args.flags["pid"].flatMap({ Int32($0) }) else {
            throw NSError(domain: "spike", code: 9, userInfo: [NSLocalizedDescriptionKey: "usage: spike tap-audio --pid <pid> [--seconds N] [--mute] [--locale en-US] [--wav out.wav]"])
        }
        let seconds = args.double("seconds", 12)
        let mute = args.has("mute")
        let locale = Locale(identifier: args.string("locale", "en-US"))
        let system = AudioObjectID(kAudioObjectSystemObject)

        // A process only has an audio object once it has become a Core Audio client, so poll briefly.
        var pid = pidValue
        var procObj = AudioObjectID(0)
        let resolveStart = Stopwatch()
        while procObj == 0 && resolveStart.ms < 3000 {
            let st = withUnsafePointer(to: &pid) { p in readProperty(system, kAudioHardwarePropertyTranslatePIDToProcessObject, qualifier: UnsafeRawPointer(p), qualifierSize: UInt32(MemoryLayout<pid_t>.size), into: &procObj) }
            if st != noErr { procObj = 0 }
            if procObj == 0 { try await Task.sleep(nanoseconds: 50_000_000) }
        }
        guard procObj != 0 else { throw TapError(what: "translate pid \(pid) to audio process object (process has produced no audio yet?)", status: -1) }
        out("pid \(pid) → audio object \(procObj) after \(fmt(resolveStart.ms)) ms")

        let desc = CATapDescription(stereoMixdownOfProcesses: [procObj])
        desc.uuid = UUID()
        desc.name = "spike-tap"
        desc.isPrivate = true
        desc.muteBehavior = mute ? .muted : .unmuted
        var tapID = AudioObjectID(0)
        let swTap = Stopwatch()
        try check(AudioHardwareCreateProcessTap(desc, &tapID), "AudioHardwareCreateProcessTap")
        out("tap \(tapID) created in \(fmt(swTap.ms)) ms (mute_at_output=\(mute))")
        defer { AudioHardwareDestroyProcessTap(tapID) }

        var outDev = AudioObjectID(0)
        try check(readProperty(system, kAudioHardwarePropertyDefaultSystemOutputDevice, into: &outDev), "default output device")
        var outUID: CFString = "" as CFString
        try check(readProperty(outDev, kAudioDevicePropertyDeviceUID, into: &outUID), "output device UID")

        let aggDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "spike-aggregate",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: desc.uuid.uuidString]],
        ]
        var aggID = AudioObjectID(0)
        try check(AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &aggID), "AudioHardwareCreateAggregateDevice")
        defer { AudioHardwareDestroyAggregateDevice(aggID) }

        var asbd = AudioStreamBasicDescription()
        try check(readProperty(tapID, kAudioTapPropertyFormat, into: &asbd), "tap format")
        guard let tapFormat = AVAudioFormat(streamDescription: &asbd) else { throw TapError(what: "tap format", status: -2) }
        out("tap format: \(Int(tapFormat.sampleRate)) Hz ch=\(tapFormat.channelCount) \(tapFormat.commonFormat == .pcmFormatFloat32 ? "float32" : "other") interleaved=\(tapFormat.isInterleaved)")

        let transcriber = try await LocalTranscriber(locale: locale, fast: args.has("fast"), vocabulary: args.list("vocab"), vocabularyAtInit: args.has("vocab-init"))
        out("transcriber ready (assets \(fmt(transcriber.assetSetupMs)) ms, prepare \(fmt(transcriber.prepareMs)) ms)")
        var wav: AVAudioFile?
        if let wavPath = args.flags["wav"] {
            wav = try AVAudioFile(forWriting: URL(fileURLWithPath: wavPath), settings: tapFormat.settings, commonFormat: tapFormat.commonFormat, interleaved: tapFormat.isInterleaved)
        }

        let state = CaptureState()
        state.usePTS = args.has("pts")
        let queue = DispatchQueue(label: "spike.tap")
        var ioProc: AudioDeviceIOProcID?
        try check(AudioDeviceCreateIOProcIDWithBlock(&ioProc, aggID, queue) { _, inInputData, inInputTime, _, _ in
            // The buffer list belongs to the IO cycle; copy before handing it to async consumers.
            guard let view = AVAudioPCMBuffer(pcmFormat: tapFormat, bufferListNoCopy: inInputData, deallocator: nil), view.frameLength > 0 else { return }
            guard let copy = AVAudioPCMBuffer(pcmFormat: tapFormat, frameCapacity: view.frameLength) else { return }
            copy.frameLength = view.frameLength
            let abl = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
            let src = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
            for i in 0..<min(abl.count, src.count) {
                memcpy(abl[i].mData, src[i].mData, Int(min(abl[i].mDataByteSize, src[i].mDataByteSize)))
            }
            let pts = CMClockMakeHostTimeFromSystemUnits(inInputTime.pointee.mHostTime)
            state.ingest(copy, pts: pts, transcriber: transcriber, wav: wav)
        }, "AudioDeviceCreateIOProcIDWithBlock")
        defer { if let ioProc { AudioDeviceDestroyIOProcID(aggID, ioProc) } }

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
        try check(AudioDeviceStart(aggID, ioProc), "AudioDeviceStart")
        out("\(clock()) tap running after \(fmt(sw.ms)) ms; listening \(fmt(seconds, 0)) s")
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
        AudioDeviceStop(aggID, ioProc)
        let stopMs = Stopwatch()
        try await transcriber.finish()
        _ = try? await results.value
        out("\(clock()) stopped; finalize took \(fmt(stopMs.ms)) ms")
        out("")
        out("buffers=\(state.buffers) audio_s=\(fmt(state.audioSeconds, 1)) fed_s=\(fmt(transcriber.fedSeconds, 1)) conversion_failures=\(state.conversionFailures) peak_dbfs=\(fmt(state.peakDbfs, 1)) first_sound_at=\(state.firstSoundClock ?? "none") finals=\(state.finals)")
        out("partial_lag_ms p50=\(fmt(percentile(state.partialLags, 50))) p95=\(fmt(percentile(state.partialLags, 95))) n=\(state.partialLags.count)")
        out("process_footprint_mb=\(fmt(residentFootprintMB(), 1))")
    }

    static func readProperty<T>(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector, qualifier: UnsafeRawPointer? = nil, qualifierSize: UInt32 = 0, into value: inout T) -> OSStatus {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(obj, &addr, qualifierSize, qualifier, &size, &value)
    }

    static func check(_ status: OSStatus, _ what: String) throws {
        if status != noErr { throw TapError(what: what, status: status) }
    }

    static func fourCC(_ s: OSStatus) -> String {
        let u = UInt32(bitPattern: s)
        let chars = [24, 16, 8, 0].map { Character(UnicodeScalar(UInt8((u >> $0) & 0xff))) }
        return chars.allSatisfy({ $0.isASCII && !$0.isWhitespace && $0 != "\0" }) ? String(chars) : "\(s)"
    }
}
