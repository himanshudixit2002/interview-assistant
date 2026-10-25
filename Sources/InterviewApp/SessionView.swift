import SwiftUI
import AppKit
import InterviewCore
import InterviewMedia
import InterviewOrchestration

struct SessionView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        if let coordinator = model.coordinator {
            LivePanelView(coordinator: coordinator, compact: false)
        } else {
            SessionSetupView()
        }
    }
}

struct SessionSetupView: View {
    @EnvironmentObject var model: AppModel
    @State private var mode: SessionMode = .live
    @State private var scope = AssistanceScope()
    @State private var processingMode: ProcessingMode = .hybrid
    @State private var audioApp: CaptureSourceDescriptor?
    @State private var audioRoute = 0   // 0 ScreenCaptureKit, 1 Core Audio tap
    @State private var window: CaptureSourceDescriptor?
    @State private var autoAnswer = true
    @State private var preflightRunning = false
    @State private var sourcesLoaded = false
    @State private var permissionRequested = false

    var setup: SessionSetup {
        let audio: AudioSource? = audioApp.map { audioRoute == 0 ? .application(pid: $0.processID, bundleID: $0.bundleIdentifier, name: $0.applicationName) : .processTap(pid: $0.processID, bundleID: $0.bundleIdentifier, name: $0.applicationName) }
        var s = scope
        if mode == .captions { s.answerDrafting = false }
        return SessionSetup(target: model.selectedTarget, mode: mode, scope: s, processingMode: processingMode, audioSource: audio, windowID: window?.windowID, windowCropTopPoints: 0, locale: model.selectedTarget?.language ?? "en-US", vocabulary: model.vocabulary, retention: model.retention, autoAnswer: autoAnswer)
    }

    var canStart: Bool {
        guard audioApp != nil || window != nil, !preflightRunning else { return false }
        if window != nil && !model.screenRecordingGranted { return false }
        if audioRoute == 0 && audioApp != nil && !model.screenRecordingGranted { return false }
        return true
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Live session").font(.title2.bold())
                GroupBox("Context and scope") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Picker("Target", selection: Binding(get: { model.selectedTargetID }, set: { model.selectTarget($0) })) {
                                Text("None").tag(EntityID?.none)
                                ForEach(model.targets) { Text("\($0.role) · \($0.company)").tag(EntityID?.some($0.id)) }
                            }
                            Picker("Mode", selection: $mode) { Text("Permitted live assistance").tag(SessionMode.live); Text("Captions only").tag(SessionMode.captions) }
                        }
                        Toggle("Captions (transcription)", isOn: $scope.captions)
                        Toggle("Screen analysis of the selected window", isOn: $scope.screenAnalysis)
                        Toggle("Answer suggestions", isOn: $scope.answerDrafting).disabled(mode == .captions)
                        Toggle("Answer automatically when a question is detected (otherwise press ⌘⇧A)", isOn: $autoAnswer)
                        Toggle("I understand this interview permits assistance of this kind", isOn: $scope.permittedByUser)
                        Toggle("AI help is prohibited in this interview (captions only, no suggestions)", isOn: $scope.prohibitedByInterview)
                        Picker("Processing", selection: $processingMode) { Text("Hybrid: local capture, cloud reasoning").tag(ProcessingMode.hybrid); Text("Local only").tag(ProcessingMode.localOnly) }
                        if processingMode == .hybrid {
                            Text(model.hasAPIKey ? "Cloud route: \(model.reasoning.preset.displayName) · \(model.reasoning.routineModel) (routine) / \(model.reasoning.strongModel) (deeper) · cap $\(String(format: "%.2f", model.reasoning.sessionCapUSD)) per session" : "No API key yet: suggestions will use the on-device model only (Settings › Reasoning to add a key).").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                GroupBox("Permissions") {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Image(systemName: model.screenRecordingGranted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill").foregroundStyle(model.screenRecordingGranted ? .green : .orange)
                            Text(model.screenRecordingGranted ? "Screen Recording: granted (window reading and the ScreenCaptureKit audio route are available)." : "Screen Recording: not granted. Needed to read a window and for the ScreenCaptureKit audio route. The Core Audio tap route works without it.").font(.callout)
                        }
                        if !model.screenRecordingGranted {
                            HStack {
                                Button("Grant Screen Recording…") { model.requestScreenRecording(); permissionRequested = true }
                                Button("Relaunch app") { model.relaunch() }
                                Text(permissionRequested ? "If you allowed it in the dialog or in System Settings, relaunch to apply." : "macOS applies the grant after a relaunch.").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Text("System Audio Recording: macOS asks once when the first session starts with the Core Audio tap route.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                GroupBox("Sources (nothing is captured until Start)") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Picker("Meeting audio from", selection: $audioApp) {
                                Text("None").tag(CaptureSourceDescriptor?.none)
                                ForEach(model.applications) { Text($0.applicationName).tag(CaptureSourceDescriptor?.some($0)) }
                            }
                            Picker("Route", selection: $audioRoute) { Text("Core Audio tap (per process)").tag(1); Text("ScreenCaptureKit (per app)").tag(0) }.frame(maxWidth: 320)
                            Button("Refresh") { Task { await model.refreshSources() } }
                        }
                        Text(model.applications.isEmpty ? "No running applications found. Open the meeting app, then press Refresh." : "The tap follows the app's audio processes (browser helpers included) and needs no Screen Recording. ScreenCaptureKit scopes audio to the whole application and needs Screen Recording.").font(.caption).foregroundStyle(.secondary)
                        Picker("Window to read", selection: $window) {
                            Text("None").tag(CaptureSourceDescriptor?.none)
                            ForEach(model.windows) { Text($0.title.isEmpty ? "\($0.applicationName) — window \($0.windowID ?? 0) (\($0.width)×\($0.height))" : $0.displayLabel).tag(CaptureSourceDescriptor?.some($0)) }
                        }
                        if window != nil && !model.screenRecordingGranted {
                            Text("Reading this window needs Screen Recording (grant above, then relaunch).").font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
                GroupBox("Preflight") {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack { Button(preflightRunning ? "Checking…" : "Run preflight") { runPreflight() }.disabled(preflightRunning); Text("Green means the tested inputs work right now.").font(.caption).foregroundStyle(.secondary) }
                        ForEach(model.preflight) { item in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: item.status == .pass ? "checkmark.circle.fill" : item.status == .warn ? "exclamationmark.triangle.fill" : item.status == .fail ? "xmark.octagon.fill" : "circle").foregroundStyle(item.status == .pass ? .green : item.status == .warn ? .orange : item.status == .fail ? .red : .secondary)
                                VStack(alignment: .leading) { Text(item.title).font(.callout.bold()); Text(item.detail).font(.caption); if !item.fix.isEmpty { Text(item.fix).font(.caption).foregroundStyle(.secondary) } }
                            }
                        }
                    }
                }
                HStack {
                    Text("Scope: " + setup.scope.summary).font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Start session") { start() }.keyboardShortcut(.defaultAction).disabled(!canStart)
                }
            }
            .padding()
        }
        .task { if !sourcesLoaded { await model.refreshSources(); sourcesLoaded = true; processingMode = model.defaultProcessingMode; audioRoute = model.screenRecordingGranted ? 0 : 1 } }
    }

    private func runPreflight() {
        preflightRunning = true
        let s = setup
        Task { model.preflight = await PreflightChecker.run(setup: s, reasoning: model.reasoning, hasAPIKey: model.hasAPIKey, ocrWarm: model.ocrWarm); preflightRunning = false }
    }

    private func start() {
        let coordinator = model.makeCoordinator(setup: setup)
        Task { await coordinator.start() }
    }
}

/// The live surface: four stable regions (interpreted question, short suggestion, evidence/assumptions,
/// optional detail), a compact status strip, and controls (§5.3). No animated reflow while reading.
struct LivePanelView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var coordinator: SessionCoordinator
    let compact: Bool
    @State private var questionDraft = ""
    @State private var correction = ""
    @State private var showDetail = false
    @State private var showTranscript = true
    @State private var now = Date()
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            statusStrip
            if let e = coordinator.lastError {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    VStack(alignment: .leading) { Text(e.description).font(.callout); if !e.recovery.isEmpty { Text(e.recovery).font(.caption).foregroundStyle(.secondary) } }
                    Spacer()
                }.padding(8).background(.orange.opacity(0.12))
            }
            if coordinator.setup.audioSource?.requiresScreenRecording == false && coordinator.status.isCapturing && coordinator.audioProcessCount == 0 {
                Text("Waiting for \(coordinator.setup.audioSource?.name ?? "the app") to play audio; the tap attaches automatically.").font(.caption).foregroundStyle(.secondary).padding(.vertical, 4)
            }
            Divider()
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    questionRegion
                    suggestionRegion
                    evidenceRegion
                    detailRegion
                    Spacer(minLength: 0)
                    controls
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                if showTranscript && !compact { Divider(); transcriptColumn.frame(width: 300) }
            }
            if let pending = coordinator.pendingSave { Divider(); saveBar(pending) }
        }
        .onReceive(ticker) { now = $0 }
    }

    private var statusStrip: some View {
        HStack(spacing: 12) {
            Label(coordinator.status.readableText, systemImage: coordinator.status.isCapturing ? "record.circle" : "circle")
                .foregroundStyle(coordinator.status.isCapturing ? .red : .secondary).font(.callout)
                .accessibilityLabel(coordinator.status.announcement)
            LevelMeter(dbfs: coordinator.levelDbfs).frame(width: 90, height: 10)
            if coordinator.setup.processingMode == .hybrid {
                Text(String(format: "Cloud left: $%.2f · %d stronger turns used", coordinator.usage.remainingUSD, coordinator.usage.strongTurnsUsed)).font(.caption).foregroundStyle(.secondary)
            } else { Text("Local only").font(.caption).foregroundStyle(.secondary) }
            if coordinator.screen != nil {
                Text("Screen rev \(coordinator.screen?.revision ?? 0)" + (coordinator.screenStale ? " (stale)" : "") + (coordinator.screenSourceLost ? " — window closed" : "")).font(.caption).foregroundStyle(coordinator.screenSourceLost ? .orange : .secondary)
            }
            Spacer()
            if !compact { Toggle("Transcript", isOn: $showTranscript).toggleStyle(.switch).controlSize(.mini) }
            Button("Compact panel") { CompactPanelController.shared.toggle(model: model) }.controlSize(.small)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.bar)
    }

    private var questionRegion: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack { Text("Interpreted question").font(.caption.bold()).foregroundStyle(.secondary); if !coordinator.detectionNote.isEmpty { Text(coordinator.detectionNote).font(.caption2).foregroundStyle(.secondary) } }
            if let q = coordinator.activeQuestion {
                HStack(alignment: .top) {
                    Text(q.text).font(.body).textSelection(.enabled)
                    Spacer()
                    Text(q.kind.label).font(.caption).padding(3).background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                }
                HStack {
                    TextField("Correct the question…", text: $correction).onSubmit { coordinator.correctActiveQuestion(correction); correction = "" }
                    Button("Dismiss") { coordinator.dismissActiveQuestion() }.controlSize(.small)
                }
            } else {
                Text(coordinator.partial.isEmpty ? "Waiting for a question. Type one below or press Ask." : "Hearing: " + coordinator.partial).font(.body).foregroundStyle(.secondary)
                HStack { TextField("Type a question and press return", text: $questionDraft).onSubmit { coordinator.ask(manualText: questionDraft); questionDraft = "" } }
            }
        }
        .padding(10).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    private var suggestionRegion: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Say first").font(.caption.bold()).foregroundStyle(.secondary)
                if let s = coordinator.suggestion { Text(s.verificationStatus.label).font(.caption2).padding(3).background(badgeColor(s.verificationStatus).opacity(0.2), in: RoundedRectangle(cornerRadius: 4)); Text(routeLabel(s.route)).font(.caption2).foregroundStyle(.secondary) }
                if !coordinator.routeNote.isEmpty { Text(coordinator.routeNote).font(.caption2).foregroundStyle(.orange) }
            }
            if let s = coordinator.suggestion ?? coordinator.pinned {
                if !s.shortAnswer.isEmpty { Text(s.shortAnswer).font(.title3).textSelection(.enabled) }
                ForEach(Array(s.keyPoints.enumerated()), id: \.offset) { _, p in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: p.status == .supported ? "checkmark.seal.fill" : p.status == .needsConfirmation ? "questionmark.circle" : "circle").foregroundStyle(badgeColor(p.status)).font(.caption)
                        Text(p.text).textSelection(.enabled)
                    }
                }
                if s.superseded { Text("Previous answer (superseded)").font(.caption).foregroundStyle(.orange) }
                if coordinator.status.phase == .generating && !s.completed { ProgressView().controlSize(.small) }
            } else if coordinator.status.phase == .generating {
                HStack { ProgressView().controlSize(.small); Text("Drafting…").foregroundStyle(.secondary) }
            } else if let e = coordinator.lastError {
                VStack(alignment: .leading) { Text(e.description).foregroundStyle(.red).font(.callout); Text(e.recovery).font(.caption) }
            } else {
                Text("No suggestion yet.").foregroundStyle(.secondary)
            }
            if let prev = coordinator.previousSuggestion, coordinator.suggestion == nil, !prev.shortAnswer.isEmpty {
                Text("Previous: " + prev.shortAnswer).font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(10).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    private var evidenceRegion: some View {
        let s = coordinator.suggestion ?? coordinator.pinned
        return VStack(alignment: .leading, spacing: 4) {
            Text("Evidence, assumptions, missing").font(.caption.bold()).foregroundStyle(.secondary)
            if let s {
                let supported = s.keyPoints.filter { $0.status == .supported }.count
                Text(supported > 0 ? "\(supported) point(s) rest on your confirmed evidence." : "No point rests on your confirmed evidence; treat personal details as unverified.").font(.callout)
                ForEach(s.assumptions, id: \.self) { Text("Assumes: " + $0).font(.callout) }
                ForEach(s.missingInformation, id: \.self) { Text($0).font(.callout).foregroundStyle(.orange) }
            } else { Text("—").foregroundStyle(.secondary) }
        }
        .padding(10).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    private var detailRegion: some View {
        VStack(alignment: .leading, spacing: 4) {
            DisclosureGroup(isExpanded: $showDetail) {
                if let d = (coordinator.suggestion ?? coordinator.pinned)?.optionalDetail {
                    ScrollView { Text(d).font(.system(.callout, design: d.contains("```") ? .monospaced : .default)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: compact ? 120 : 220)
                    if d.contains("```") { Text("Code shown here was not executed.").font(.caption).foregroundStyle(.orange) }
                } else { Text("No detail for this answer.").font(.callout).foregroundStyle(.secondary) }
            } label: { Text("Detail").font(.caption.bold()).foregroundStyle(.secondary) }
        }
        .padding(10).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    private var controls: some View {
        let actions = coordinator.status.allowedActions
        return HStack(spacing: 8) {
            Button("Ask") { coordinator.ask() }.disabled(!actions.contains(.ask)).help("Ask for help with the current question (⌘⇧A)")
            Menu("Adjust") {
                ForEach(AnswerControl.allCases.filter { $0 != .standard }, id: \.self) { c in Button(c.label) { coordinator.ask(control: c) } }
            }.disabled(!actions.contains(.ask)).frame(width: 90)
            Button("Pin") { coordinator.pin() }.disabled(!actions.contains(.pinAnswer))
            Button("Recapture") { Task { await coordinator.recapture() } }.disabled(!actions.contains(.recapture) || coordinator.setup.windowID == nil)
            Spacer()
            if coordinator.status.phase == .paused { Button("Resume") { Task { await coordinator.resume() } } } else { Button("Pause") { coordinator.pause() }.disabled(!actions.contains(.pause)) }
            if coordinator.status.phase == .stopped { Button("Close") { model.endSession() } } else { Button("Stop", role: .destructive) { coordinator.stop() }.disabled(!actions.contains(.stop)) }
        }
    }

    private var transcriptColumn: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Transcript (\(coordinator.finals.count))" + (coordinator.gapCount > 0 ? " · \(coordinator.gapCount) gap(s)" : "")).font(.caption.bold()).foregroundStyle(.secondary)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(coordinator.finals) { seg in
                            Text(seg.text).font(.callout).foregroundStyle(seg.isGap ? .orange : .primary).textSelection(.enabled).id(seg.id)
                        }
                        if !coordinator.partial.isEmpty { Text(coordinator.partial).font(.callout).foregroundStyle(.secondary).id("partial") }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: coordinator.finals.count) { _, _ in if let last = coordinator.finals.last { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
        }
        .padding(10)
    }

    private func saveBar(_ pending: PendingSave) -> some View {
        let remaining = max(0, Int(pending.deadline.timeIntervalSince(now)))
        return HStack {
            Text("Session stopped. Keep a transcript and the suggestions? Discarded automatically in \(remaining / 60):\(String(format: "%02d", remaining % 60)).").font(.callout)
            Spacer()
            Button("Discard") { coordinator.discard() }
            Button("Save") { coordinator.save() }.keyboardShortcut(.defaultAction)
        }.padding(10).background(.bar)
    }

    private func badgeColor(_ s: VerificationStatus) -> Color {
        switch s { case .supported: return .green; case .needsConfirmation, .failed: return .orange; case .unexecuted: return .purple; case .generalExplanation: return .secondary }
    }
    private func routeLabel(_ r: RouteKind) -> String {
        switch r { case .onDevice: return "on-device"; case .routineCloud: return "cloud"; case .strongCloud: return "cloud (deeper)"; case .none: return "" }
    }
}

struct LevelMeter: View {
    let dbfs: Double
    var body: some View {
        GeometryReader { geo in
            let fraction = max(0, min(1, (dbfs + 60) / 60))
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3).fill(.quaternary)
                RoundedRectangle(cornerRadius: 3).fill(fraction > 0.85 ? Color.red : fraction > 0.5 ? Color.green : Color.secondary).frame(width: geo.size.width * fraction)
            }
        }
        .accessibilityLabel("Audio level \(Int(dbfs)) dBFS")
    }
}

/// Floating compact panel (F73): a normal, screen-share-visible window that keeps keyboard focus elsewhere.
@MainActor
final class CompactPanelController {
    static let shared = CompactPanelController()
    private var panel: NSPanel?

    func toggle(model: AppModel) {
        if let panel, panel.isVisible { panel.orderOut(nil); return }
        guard let coordinator = model.coordinator else { return }
        let panel = self.panel ?? NSPanel(contentRect: NSRect(x: 80, y: 120, width: 460, height: 520), styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .utilityWindow], backing: .buffered, defer: false)
        panel.title = "Assistant"
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.sharingType = .readOnly   // deliberately visible to screen capture (no concealment)
        panel.setFrameAutosaveName("CompactPanel")
        panel.contentView = NSHostingView(rootView: LivePanelView(coordinator: coordinator, compact: true).environmentObject(model))
        panel.orderFront(nil)
        self.panel = panel
    }
}
