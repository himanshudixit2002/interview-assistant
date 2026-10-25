import Foundation
import AVFoundation
import ScreenCaptureKit
import CoreAudio
import AudioToolbox
import CoreMedia
import InterviewCore

/// What to listen to. Two routes measured in Phase 0: ScreenCaptureKit (per application bundle, needs Screen
/// Recording) and a Core Audio process tap (per process set, needs only System Audio Recording). Never the
/// microphone here; that is a separate capability (F14).
public enum AudioSource: Sendable, Equatable, Hashable {
    case application(pid: Int32, bundleID: String, name: String)
    case processTap(pid: Int32, bundleID: String, name: String)

    public var pid: Int32 { switch self { case .application(let p, _, _), .processTap(let p, _, _): return p } }
    public var bundleID: String { switch self { case .application(_, let b, _), .processTap(_, let b, _): return b } }
    public var name: String { switch self { case .application(_, _, let n), .processTap(_, _, let n): return n } }
    public var routeLabel: String { switch self { case .application: return "ScreenCaptureKit"; case .processTap: return "Core Audio tap" } }
    public var requiresScreenRecording: Bool { if case .application = self { return true }; return false }
}

public enum AudioPipelineError: Error, CustomStringConvertible {
    case applicationNotFound, noDisplay, permission, noAudioProcesses(String), tapFailed(String), streamFailed(String)
    public var description: String {
        switch self {
        case .applicationNotFound: return "the selected application is not running"
        case .noDisplay: return "no display available for capture"
        case .permission: return "Screen Recording permission is required for the ScreenCaptureKit audio route"
        case .noAudioProcesses(let name): return "\(name) has not produced any audio yet; join the call, then press Start"
        case .tapFailed(let s): return "audio tap failed: \(s)"
        case .streamFailed(let s): return "audio stream failed: \(s)"
        }
    }
}

public struct AudioChunk: @unchecked Sendable {
    public let buffer: AVAudioPCMBuffer
    public let hostTime: CMTime
}

/// Captures system audio from one application and reports levels; the delegate feeds the transcriber.
public final class AudioPipeline: NSObject, @unchecked Sendable, SCStreamOutput, SCStreamDelegate {
    public var onChunk: (@Sendable (AudioChunk) -> Void)?
    public var onLevel: (@Sendable (Double) -> Void)?
    public var onStopped: (@Sendable (String) -> Void)?
    /// Test hook only: silences the tapped processes at the speaker while tapped. Never on for real sessions.
    public var muteTappedProcesses = false

    private let lock = NSLock()
    private var stream: SCStream?
    private var tapID = AudioObjectID(0)
    private var aggregateID = AudioObjectID(0)
    private var ioProc: AudioDeviceIOProcID?
    private var tappedObjects: Set<AudioObjectID> = []
    private var resolveTask: Task<Void, Never>?
    private let queue = DispatchQueue(label: "interview.audio")
    public private(set) var source: AudioSource?
    public private(set) var buffersReceived = 0
    public private(set) var droppedBuffers = 0

    public var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return stream != nil || ioProc != nil }
    public var tappedProcessCount: Int { lock.lock(); defer { lock.unlock() }; return tappedObjects.count }

    public func start(_ source: AudioSource) async throws {
        await stop()
        lock.lock(); self.source = source; buffersReceived = 0; droppedBuffers = 0; lock.unlock()
        switch source {
        case .application(let pid, _, _): try await startStream(pid: pid)
        case .processTap(let pid, let bundleID, let name):
            let objects = Self.processObjects(matching: bundleID, pid: pid)
            if objects.isEmpty {
                // The meeting app may not have opened audio yet; keep looking while the user waits.
                startResolveLoop(source: source)
                throw AudioPipelineError.noAudioProcesses(name)
            }
            try startTap(objects: objects)
            startResolveLoop(source: source)
        }
    }

    public func stop() async {
        resolveTask?.cancel(); resolveTask = nil
        lock.lock()
        let s = stream; stream = nil
        let proc = ioProc; ioProc = nil
        let agg = aggregateID; aggregateID = 0
        let tap = tapID; tapID = 0
        tappedObjects = []
        lock.unlock()
        if let s { try? await s.stopCapture() }
        if let proc, agg != 0 { AudioDeviceStop(agg, proc); AudioDeviceDestroyIOProcID(agg, proc) }
        if agg != 0 { AudioHardwareDestroyAggregateDevice(agg) }
        if tap != 0 { AudioHardwareDestroyProcessTap(tap) }
    }

    // MARK: ScreenCaptureKit route

    private func startStream(pid: Int32) async throws {
        guard CGPreflightScreenCaptureAccess() else { throw AudioPipelineError.permission }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        guard let display = content.displays.first else { throw AudioPipelineError.noDisplay }
        guard let app = content.applications.first(where: { $0.processID == pid }) else { throw AudioPipelineError.applicationNotFound }
        let filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 1
        config.width = 64; config.height = 64
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.showsCursor = false
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
            try await stream.startCapture()
        } catch { throw AudioPipelineError.streamFailed("\(error)") }
        lock.lock(); self.stream = stream; lock.unlock()
    }

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, let desc = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        let format = AVAudioFormat(cmAudioFormatDescription: desc)
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0, let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { lock.lock(); droppedBuffers += 1; lock.unlock(); return }
        pcm.frameLength = AVAudioFrameCount(frames)
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(frames), into: pcm.mutableAudioBufferList) == noErr else { lock.lock(); droppedBuffers += 1; lock.unlock(); return }
        deliver(pcm, hostTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.lock(); self.stream = nil; lock.unlock()
        onStopped?("\(error)")
    }

    // MARK: Core Audio process tap route

    /// Browsers and Electron apps play audio from helper processes, and Safari from `com.apple.WebKit.GPU`,
    /// so the tap includes every audio process whose bundle matches the app (or a known alias) or whose pid is the app's.
    static let bundleAliases: [String: [String]] = [
        "com.apple.Safari": ["com.apple.WebKit.GPU"],
        "com.apple.SafariTechnologyPreview": ["com.apple.WebKit.GPU"],
        "com.apple.FaceTime": ["com.apple.avconferenced"],
    ]

    public static func processObjects(matching bundleID: String, pid: Int32) -> [AudioObjectID] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        let aliases = bundleAliases[bundleID] ?? []
        var matches: [AudioObjectID] = []
        for id in ids {
            var objectPID: pid_t = 0
            _ = readProperty(id, kAudioProcessPropertyPID, into: &objectPID)
            var bundle: CFString = "" as CFString
            _ = readProperty(id, kAudioProcessPropertyBundleID, into: &bundle)
            let b = bundle as String
            if objectPID == pid || (!bundleID.isEmpty && (b == bundleID || b.hasPrefix(bundleID + "."))) || aliases.contains(b) {
                matches.append(id)
            }
        }
        return matches
    }

    private func startTap(objects: [AudioObjectID]) throws {
        let system = AudioObjectID(kAudioObjectSystemObject)
        let description = CATapDescription(stereoMixdownOfProcesses: objects)
        description.uuid = UUID(); description.name = "interview-assistant"; description.isPrivate = true
        description.muteBehavior = muteTappedProcesses ? .muted : .unmuted
        var tap = AudioObjectID(0)
        guard AudioHardwareCreateProcessTap(description, &tap) == noErr else { throw AudioPipelineError.tapFailed("create tap (System Audio Recording permission?)") }
        var outputDevice = AudioObjectID(0)
        guard Self.readProperty(system, kAudioHardwarePropertyDefaultSystemOutputDevice, into: &outputDevice) == noErr else { AudioHardwareDestroyProcessTap(tap); throw AudioPipelineError.tapFailed("default output") }
        var outputUID: CFString = "" as CFString
        guard Self.readProperty(outputDevice, kAudioDevicePropertyDeviceUID, into: &outputUID) == noErr else { AudioHardwareDestroyProcessTap(tap); throw AudioPipelineError.tapFailed("output uid") }
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "interview-assistant-aggregate",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        var aggregate = AudioObjectID(0)
        guard AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregate) == noErr else { AudioHardwareDestroyProcessTap(tap); throw AudioPipelineError.tapFailed("aggregate device") }
        var asbd = AudioStreamBasicDescription()
        guard Self.readProperty(tap, kAudioTapPropertyFormat, into: &asbd) == noErr, let format = AVAudioFormat(streamDescription: &asbd) else {
            AudioHardwareDestroyAggregateDevice(aggregate); AudioHardwareDestroyProcessTap(tap); throw AudioPipelineError.tapFailed("tap format")
        }
        var proc: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&proc, aggregate, queue) { [weak self] _, inputData, inputTime, _, _ in
            guard let self, let view = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: inputData, deallocator: nil), view.frameLength > 0,
                  let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: view.frameLength) else { return }
            copy.frameLength = view.frameLength
            let dst = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
            let src = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
            for i in 0..<min(dst.count, src.count) { memcpy(dst[i].mData, src[i].mData, Int(min(dst[i].mDataByteSize, src[i].mDataByteSize))) }
            self.deliver(copy, hostTime: CMClockMakeHostTimeFromSystemUnits(inputTime.pointee.mHostTime))
        }
        guard status == noErr, let proc else { AudioHardwareDestroyAggregateDevice(aggregate); AudioHardwareDestroyProcessTap(tap); throw AudioPipelineError.tapFailed("io proc") }
        guard AudioDeviceStart(aggregate, proc) == noErr else {
            AudioDeviceDestroyIOProcID(aggregate, proc); AudioHardwareDestroyAggregateDevice(aggregate); AudioHardwareDestroyProcessTap(tap)
            throw AudioPipelineError.tapFailed("start")
        }
        lock.lock(); tapID = tap; aggregateID = aggregate; ioProc = proc; tappedObjects = Set(objects); lock.unlock()
    }

    private func tearDownTapOnly() {
        lock.lock()
        let proc = ioProc; ioProc = nil
        let agg = aggregateID; aggregateID = 0
        let tap = tapID; tapID = 0
        tappedObjects = []
        lock.unlock()
        if let proc, agg != 0 { AudioDeviceStop(agg, proc); AudioDeviceDestroyIOProcID(agg, proc) }
        if agg != 0 { AudioHardwareDestroyAggregateDevice(agg) }
        if tap != 0 { AudioHardwareDestroyProcessTap(tap) }
    }

    /// Re-resolves the process set every few seconds: a browser that spawns a new audio helper, or a meeting
    /// app that only now opened its audio device, is picked up without the user restarting the session.
    private func startResolveLoop(source: AudioSource) {
        resolveTask?.cancel()
        guard case .processTap(let pid, let bundleID, _) = source else { return }
        resolveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard let self, !Task.isCancelled else { return }
                let objects = Set(Self.processObjects(matching: bundleID, pid: pid))
                let current = self.tappedProcessCount == 0 ? Set<AudioObjectID>() : { self.lock.lock(); defer { self.lock.unlock() }; return self.tappedObjects }()
                guard !objects.isEmpty, objects != current else { continue }
                self.tearDownTapOnly()
                do { try self.startTap(objects: Array(objects)) } catch { self.onStopped?("\(error)") }
            }
        }
    }

    private func deliver(_ buffer: AVAudioPCMBuffer, hostTime: CMTime) {
        lock.lock(); buffersReceived += 1; lock.unlock()
        onLevel?(Self.dbfs(buffer))
        onChunk?(AudioChunk(buffer: buffer, hostTime: hostTime))
    }

    static func readProperty<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, qualifier: UnsafeRawPointer? = nil, qualifierSize: UInt32 = 0, into value: inout T) -> OSStatus {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(object, &address, qualifierSize, qualifier, &size, &value)
    }

    public static func dbfs(_ b: AVAudioPCMBuffer) -> Double {
        let n = Int(b.frameLength)
        guard n > 0 else { return -120 }
        var sum = 0.0
        if let f = b.floatChannelData { for i in 0..<n { let v = Double(f[0][i]); sum += v * v } }
        else if let s = b.int16ChannelData { for i in 0..<n { let v = Double(s[0][i]) / 32768; sum += v * v } }
        else { return -120 }
        let rms = (sum / Double(n)).squareRoot()
        return rms > 0 ? 20 * log10(rms) : -120
    }
}

/// Speech-activity tracking for endpointing (§7.2): a question is "probably complete" after `pauseMs`
/// of silence following speech. The transcriber's own finals are used when they arrive first.
public final class SpeechActivityTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var lastSpeech: Date?
    private var speechSinceEndpoint = false
    public private(set) var peakDbfs: Double = -120
    public private(set) var recentDbfs: Double = -120
    public private(set) var firstSoundAt: Date?
    public let speechThresholdDbfs: Double

    public init(speechThresholdDbfs: Double = -45) { self.speechThresholdDbfs = speechThresholdDbfs }

    public func observe(dbfs: Double) {
        lock.lock(); defer { lock.unlock() }
        recentDbfs = dbfs
        if dbfs > peakDbfs { peakDbfs = dbfs }
        if dbfs > speechThresholdDbfs {
            lastSpeech = Date(); speechSinceEndpoint = true
            if firstSoundAt == nil { firstSoundAt = Date() }
        }
    }

    public func endpointIfSilent(pauseMs: Double) -> Double? {
        lock.lock(); defer { lock.unlock() }
        guard speechSinceEndpoint, let last = lastSpeech else { return nil }
        let silent = Date().timeIntervalSince(last) * 1000
        guard silent >= pauseMs else { return nil }
        speechSinceEndpoint = false
        return silent
    }

    public var hasHeardSpeech: Bool { lock.lock(); defer { lock.unlock() }; return firstSoundAt != nil }
}
