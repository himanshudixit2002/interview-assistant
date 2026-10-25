import Foundation
import CoreGraphics
import AVFoundation
import ScreenCaptureKit
import Speech
import Vision
import FoundationModels
import NaturalLanguage

enum Capabilities {
    static func run(_ args: Args) async throws {
        let pi = ProcessInfo.processInfo
        let v = pi.operatingSystemVersion
        out("== Machine ==")
        out("macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)  arch=\(arch())  cpu=\(sysctlString("machdep.cpu.brand_string"))  ram_gb=\(pi.physicalMemory / 1_073_741_824)")
        out("thermal=\(pi.thermalState.rawValue) low_power=\(pi.isLowPowerModeEnabled) free_disk_gb=\(fmt(freeDiskGB(), 1))")

        out("\n== Permissions (no prompts triggered) ==")
        out("screen_recording_preflight=\(CGPreflightScreenCaptureAccess())")
        out("microphone=\(describe(AVCaptureDevice.authorizationStatus(for: .audio)))")

        out("\n== ScreenCaptureKit shareable content ==")
        do {
            let sw = Stopwatch()
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            out("enumerated in \(fmt(sw.ms)) ms: displays=\(content.displays.count) on_screen_windows=\(content.windows.count) apps=\(content.applications.count)")
            for d in content.displays {
                let mode = CGDisplayCopyDisplayMode(d.displayID)
                let px = mode.map { "\($0.pixelWidth)x\($0.pixelHeight)" } ?? "?"
                out("  display \(d.displayID): points=\(d.width)x\(d.height) pixels=\(px) frame=\(d.frame)")
            }
            let titled = content.windows.filter { ($0.title ?? "").isEmpty == false && $0.windowLayer == 0 }
            out("  titled normal-layer windows: \(titled.count)")
            for w in titled.prefix(12) {
                out("    [\(w.windowID)] \(w.owningApplication?.applicationName ?? "?") — \(w.title ?? "") \(Int(w.frame.width))x\(Int(w.frame.height))")
            }
        } catch {
            out("shareable content error: \(error)")
        }

        out("\n== Speech (SpeechAnalyzer / SpeechTranscriber) ==")
        out("transcriber_available=\(SpeechTranscriber.isAvailable)")
        let supported = await SpeechTranscriber.supportedLocales
        let installed = await SpeechTranscriber.installedLocales
        out("supported_locales=\(supported.count) installed=\(installed.map(\.identifier).sorted())")
        for id in ["en-US", "en-IN", "en-GB", "hi-IN"] {
            let want = Locale(identifier: id)
            let eq = await SpeechTranscriber.supportedLocale(equivalentTo: want)
            var statusText = "unsupported"
            if let eq {
                let t = SpeechTranscriber(locale: eq, preset: .progressiveTranscription)
                let st = await AssetInventory.status(forModules: [t])
                statusText = "\(st)"
            }
            out("  \(id): equivalent=\(eq?.identifier ?? "-") assets=\(statusText)")
        }
        let probe = SpeechTranscriber(locale: Locale(identifier: "en-US"), preset: .progressiveTranscription)
        if let f = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [probe]) {
            out("best_audio_format=\(Int(f.sampleRate)) Hz ch=\(f.channelCount) \(f.commonFormat.rawValue == 1 ? "float32" : "fmt\(f.commonFormat.rawValue)")")
        }
        out("reserved_locales=\(await AssetInventory.reservedLocales.map(\.identifier)) max=\(AssetInventory.maximumReservedLocales)")

        out("\n== Vision OCR ==")
        let req = RecognizeTextRequest()
        let langs = req.supportedRecognitionLanguages.map(\.minimalIdentifier)
        out("ocr_languages=\(langs.count): \(langs.prefix(12).joined(separator: ","))\(langs.count > 12 ? ",…" : "")")

        out("\n== Foundation Models (on-device LLM) ==")
        switch SystemLanguageModel.default.availability {
        case .available: out("system_language_model=available")
        case .unavailable(let reason): out("system_language_model=unavailable reason=\(reason)")
        }

        out("\n== NaturalLanguage ==")
        out("sentence_embedding_en=\(NLEmbedding.sentenceEmbedding(for: .english) != nil) word_embedding_en=\(NLEmbedding.wordEmbedding(for: .english) != nil)")
        out("\nprocess_footprint_mb=\(fmt(residentFootprintMB(), 1))")
    }

    static func describe(_ s: AVAuthorizationStatus) -> String {
        switch s {
        case .notDetermined: return "notDetermined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .authorized: return "authorized"
        @unknown default: return "unknown"
        }
    }

    static func arch() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafePointer(to: &info.machine) { $0.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) } }
    }

    static func sysctlString(_ name: String) -> String {
        var size = 0
        sysctlbyname(name, nil, &size, nil, 0)
        var buf = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname(name, &buf, &size, nil, 0)
        return String(cString: buf)
    }

    static func freeDiskGB() -> Double {
        let attrs = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())
        let free = (attrs?[.systemFreeSize] as? NSNumber)?.doubleValue ?? 0
        return free / 1_073_741_824
    }
}
