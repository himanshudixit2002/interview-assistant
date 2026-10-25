import Foundation
import InterviewCore
import InterviewMedia
import InterviewReasoning

public enum PreflightStatus: String, Sendable { case pass, warn, fail, pending }

public struct PreflightItem: Identifiable, Sendable, Equatable {
    public var id: String
    public var title: String
    public var status: PreflightStatus
    public var detail: String
    public var fix: String
    public init(id: String, title: String, status: PreflightStatus, detail: String, fix: String = "") { self.id = id; self.title = title; self.status = status; self.detail = detail; self.fix = fix }
}

/// Preflight (F75): permissions, source availability, speech assets, model readiness, network, memory and
/// allowance. Green means the tested inputs work now, nothing more (§5.2).
public enum PreflightChecker {
    public static func run(setup: SessionSetup, reasoning: ReasoningConfiguration, hasAPIKey: Bool, ocrWarm: Bool) async -> [PreflightItem] {
        var items: [PreflightItem] = []

        if setup.windowID != nil {
            let granted = CaptureManager.screenRecordingGranted()
            items.append(PreflightItem(id: "screen", title: "Screen Recording permission", status: granted ? .pass : .fail, detail: granted ? "Granted" : "Not granted", fix: granted ? "" : "System Settings › Privacy & Security › Screen & System Audio Recording"))
            if granted, let id = setup.windowID {
                let state = await CaptureManager().windowState(id: id)
                items.append(PreflightItem(id: "window", title: "Selected window", status: state.exists ? (state.onScreen ? .pass : .warn) : .fail, detail: state.exists ? (state.onScreen ? "Available" : "Exists but not on screen; capture still works") : "The window is gone", fix: state.exists ? "" : "Choose the window again"))
            }
        } else {
            items.append(PreflightItem(id: "window", title: "Screen analysis", status: .warn, detail: "No window selected; answers will rely on audio only"))
        }

        if let source = setup.audioSource {
            let alive = kill(source.pid, 0) == 0
            items.append(PreflightItem(id: "audio", title: "Audio source (\(source.routeLabel))", status: alive ? .pass : .fail, detail: alive ? "\(source.name) is running; levels show after Start" : "\(source.name) is not running", fix: alive ? "" : "Open the meeting app and select it again"))
            if source.requiresScreenRecording {
                let granted = CaptureManager.screenRecordingGranted()
                items.append(PreflightItem(id: "audio-permission", title: "Screen Recording (needed by this audio route)", status: granted ? .pass : .fail, detail: granted ? "Granted" : "Not granted for this app; grant it, then relaunch the app, or switch to the Core Audio tap route", fix: granted ? "" : "System Settings › Privacy & Security › Screen & System Audio Recording"))
            } else {
                let objects = AudioPipeline.processObjects(matching: source.bundleID, pid: source.pid)
                items.append(PreflightItem(id: "audio-processes", title: "Audio processes of \(source.name)", status: objects.isEmpty ? .warn : .pass, detail: objects.isEmpty ? "None yet; the tap attaches once the app plays audio (join the call first)" : "\(objects.count) process(es) found", fix: "macOS asks once for System Audio Recording permission on first start"))
            }
        } else if setup.scope.captions {
            items.append(PreflightItem(id: "audio", title: "Audio source", status: .fail, detail: "No audio source selected", fix: "Pick the meeting application"))
        }

        if setup.scope.captions {
            let speech = await TranscriptionService.localeStatus(setup.locale)
            let available = TranscriptionService.isAvailable && speech.supported
            items.append(PreflightItem(id: "speech", title: "Local speech (\(speech.identifier))", status: available ? (speech.installed ? .pass : .warn) : .fail, detail: available ? (speech.installed ? "Assets installed" : "Assets will download on first start") : "Unsupported on this Mac", fix: available ? "" : "Choose a supported locale"))
        }

        items.append(PreflightItem(id: "ocr", title: "Text recognition", status: ocrWarm ? .pass : .warn, detail: ocrWarm ? "Warm" : "First recognition can take up to 30 s"))

        let onDevice = OnDeviceProvider.availability()
        items.append(PreflightItem(id: "ondevice", title: "On-device model", status: onDevice.available ? .pass : .warn, detail: onDevice.available ? "Available for question detection and fallback" : onDevice.reason, fix: onDevice.available ? "" : "System Settings › Apple Intelligence & Siri"))

        if setup.processingMode == .hybrid {
            items.append(PreflightItem(id: "key", title: "Cloud provider (\(reasoning.preset.displayName))", status: hasAPIKey ? .pass : .fail, detail: hasAPIKey ? "API key present in Keychain" : "No API key", fix: hasAPIKey ? "" : "Settings › Reasoning"))
            if hasAPIKey, let url = URL(string: reasoning.baseURL) {
                var request = URLRequest(url: url); request.httpMethod = "HEAD"; request.timeoutInterval = 4
                let reachable = (try? await URLSession.shared.data(for: request)) != nil
                items.append(PreflightItem(id: "network", title: "Network to provider", status: reachable ? .pass : .warn, detail: reachable ? "Reachable" : "Not reachable right now; local captions continue"))
            }
            items.append(PreflightItem(id: "budget", title: "Session allowance", status: reasoning.sessionCapUSD > 0 ? .pass : .fail, detail: String(format: "$%.2f cap, %d stronger turns", reasoning.sessionCapUSD, reasoning.strongTurnAllowance), fix: reasoning.sessionCapUSD > 0 ? "" : "Set a cap in Settings"))
        } else {
            items.append(PreflightItem(id: "local", title: "Local-only mode", status: onDevice.available ? .pass : .warn, detail: onDevice.available ? "Captions, detection and structure stay on device" : "Captions only; no on-device model for suggestions"))
        }

        let thermal = ProcessInfo.processInfo.thermalState
        items.append(PreflightItem(id: "thermal", title: "Thermal state", status: thermal == .nominal || thermal == .fair ? .pass : .warn, detail: thermal == .nominal ? "Nominal" : "Elevated; image rate will be reduced"))
        let gb = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        items.append(PreflightItem(id: "memory", title: "Memory", status: gb >= 16 ? .pass : .warn, detail: String(format: "%.0f GB", gb)))

        if setup.scope.prohibitedByInterview {
            items.append(PreflightItem(id: "scope", title: "Assistance scope", status: .warn, detail: "You marked AI help as prohibited: captions only, no suggestions"))
        } else if !setup.scope.permittedByUser && setup.mode == .live {
            items.append(PreflightItem(id: "scope", title: "Assistance scope", status: .warn, detail: "You have not confirmed that live suggestions are permitted for this interview"))
        }
        return items
    }
}
