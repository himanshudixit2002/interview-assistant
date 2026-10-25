import SwiftUI
import AppKit
import InterviewCore
import InterviewReasoning
import InterviewOrchestration

struct ReviewView: View {
    @EnvironmentObject var model: AppModel
    @State private var selectedID: EntityID?
    @State private var questions: [Question] = []
    @State private var suggestions: [Suggestion] = []
    @State private var review: SessionReview?

    var body: some View {
        HSplitView {
            VStack(alignment: .leading) {
                Text("Saved sessions").font(.title2.bold()).padding([.top, .horizontal])
                Text("Only sessions you chose to save. Auto-deleted after \(model.retention.savedSessionDays) days.").font(.caption).foregroundStyle(.secondary).padding(.horizontal)
                List(model.savedSessions, id: \.id, selection: $selectedID) { s in
                    VStack(alignment: .leading) { Text(s.startedAt.formatted(date: .abbreviated, time: .shortened)).font(.headline); Text("\(s.mode.rawValue) · \(s.scope.summary)").font(.caption).foregroundStyle(.secondary) }.tag(s.id)
                }
            }.frame(minWidth: 260)
            VStack(alignment: .leading, spacing: 10) {
                if let s = model.savedSessions.first(where: { $0.id == selectedID }) {
                    HStack {
                        Text("Review").font(.title3.bold()); Spacer()
                        Button("Export notes…") { exportNotes(s) }
                        Button("Delete", role: .destructive) { try? model.store.deleteSession(s.id); model.savedSessions.removeAll { $0.id == s.id }; selectedID = nil }
                    }
                    if let r = review {
                        GroupBox("Three things") {
                            VStack(alignment: .leading, spacing: 6) { Text("Strongest: " + r.strongest); Text("Gap: " + r.gap); Text("Next: " + r.next) }.font(.callout)
                        }
                    }
                    List {
                        ForEach(questions) { q in
                            SwiftUI.Section("\(q.kind.label): \(q.text)") {
                                ForEach(suggestions.filter { $0.questionID == q.id }) { sug in
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(sug.shortAnswer).font(.body)
                                        ForEach(Array(sug.keyPoints.enumerated()), id: \.offset) { _, p in Text("• \(p.text) (\(p.status.label))").font(.callout) }
                                        ForEach(sug.missingInformation, id: \.self) { Text($0).font(.callout).foregroundStyle(.orange) }
                                    }
                                }
                            }
                        }
                    }
                } else {
                    ContentUnavailableView("Select a session", systemImage: "chart.bar.doc.horizontal", description: Text("The review shows the strongest answer, the most important gap and the next exercise."))
                }
            }.padding().frame(minWidth: 420)
        }
        .onChange(of: selectedID) { _, id in
            guard let id else { questions = []; suggestions = []; review = nil; return }
            questions = (try? model.store.questions(sessionID: id)) ?? []
            suggestions = (try? model.store.suggestions(sessionID: id)) ?? []
            review = ReviewBuilder.heuristic(questions: questions, suggestions: suggestions)
        }
    }

    private func exportNotes(_ s: Session) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "interview-notes.md"
        if panel.runModal() == .OK, let url = panel.url { try? model.exportNotes(for: s).write(to: url, atomically: true, encoding: .utf8) }
    }
}

/// Basic mock interviewer (F61, F62): role-appropriate questions, timer, unaided baseline, then a reviewed suggestion.
struct MockView: View {
    @EnvironmentObject var model: AppModel
    @State private var kinds: Set<QuestionKind> = [.behavioral, .coding]
    @State private var queue: [MockQuestion] = []
    @State private var index = 0
    @State private var answer = ""
    @State private var started: Date?
    @State private var unaided = true
    @State private var revealed = false
    @State private var now = Date()
    @State private var scores: [String: Int] = [:]
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var current: MockQuestion? { queue.indices.contains(index) ? queue[index] : nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Practice").font(.title2.bold())
            if queue.isEmpty {
                Text("Start with an unaided baseline so improvement can be measured (F62). Questions are original; no third-party banks.").font(.callout).foregroundStyle(.secondary)
                HStack { ForEach([QuestionKind.behavioral, .coding, .systemDesign, .debugging, .sql, .conceptual], id: \.self) { k in Toggle(k.label, isOn: Binding(get: { kinds.contains(k) }, set: { if $0 { kinds.insert(k) } else { kinds.remove(k) } })) } }
                Toggle("Unaided first: hide the suggested answer until I finish", isOn: $unaided)
                Button("Start a 3-question mock") { queue = MockQuestionBank.pick(kinds: Array(kinds), count: 3); index = 0; answer = ""; started = Date(); revealed = false; scores = [:] }.disabled(kinds.isEmpty)
            } else if let q = current {
                HStack { Text("Question \(index + 1) of \(queue.count) · \(q.kind.label)").font(.headline); Spacer(); if let s = started { Text("\(Int(now.timeIntervalSince(s))) s").monospacedDigit() } }
                Text(q.text).font(.title3)
                TextEditor(text: $answer).frame(minHeight: 140).font(.body)
                HStack {
                    Button(revealed ? "Suggestion shown" : (unaided ? "I'm done — show the suggestion" : "Show the suggestion")) { revealed = true }.disabled(revealed)
                    Spacer()
                    Button(index + 1 < queue.count ? "Next question" : "Finish") { if index + 1 < queue.count { index += 1; answer = ""; started = Date(); revealed = false } else { queue = [] } }
                }
                if revealed {
                    GroupBox("Rubric — score yourself") {
                        ForEach(q.rubric, id: \.self) { item in
                            HStack { Text(item); Spacer(); Picker("", selection: Binding(get: { scores[q.id + item] ?? 0 }, set: { scores[q.id + item] = $0 })) { Text("missed").tag(0); Text("partly").tag(1); Text("covered").tag(2) }.pickerStyle(.segmented).frame(width: 220) }
                        }
                    }
                    MockSuggestionView(question: q)
                }
            }
        }
        .padding()
        .onReceive(ticker) { now = $0 }
    }
}

struct MockSuggestionView: View {
    @EnvironmentObject var model: AppModel
    let question: MockQuestion
    @State private var suggestion: Suggestion?
    @State private var note = ""
    var body: some View {
        GroupBox("Suggested structure (uses only your approved evidence)") {
            VStack(alignment: .leading, spacing: 6) {
                if let s = suggestion {
                    Text(s.shortAnswer).font(.body)
                    ForEach(Array(s.keyPoints.enumerated()), id: \.offset) { _, p in Text("• \(p.text) (\(p.status.label))").font(.callout) }
                    ForEach(s.missingInformation, id: \.self) { Text($0).font(.callout).foregroundStyle(.orange) }
                    if let d = s.optionalDetail { Text(d).font(.system(.caption, design: .monospaced)) }
                } else if !note.isEmpty { Text(note).foregroundStyle(.secondary) } else { ProgressView().controlSize(.small) }
            }
        }
        .task { await generate() }
    }

    private func generate() async {
        let orchestrator = model.makeOrchestrator(processingMode: model.defaultProcessingMode)
        let sessionID = EntityID()
        let q = Question(sessionID: sessionID, text: question.text, kind: question.kind, source: .manual)
        let request = AnswerRequest(question: q, screen: nil, target: model.selectedTarget, recentTurns: [], summary: nil, control: .standard, correctionNote: nil, stamp: GenerationStamp(epoch: 0, questionID: q.id, questionRevision: 1, screenRevision: nil))
        do {
            let outcome = try await orchestrator.generate(request, sessionID: sessionID, processingMode: model.defaultProcessingMode, offline: false, isCurrent: { true }, publish: { s in Task { @MainActor in suggestion = s } })
            suggestion = outcome.suggestion
        } catch let e as AssistantError { note = e.description + " " + e.recovery } catch { note = "Could not generate a suggestion." }
    }
}

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var config = ReasoningConfiguration()
    @State private var apiKey = ""
    @State private var retentionDays = 30
    @State private var processing: ProcessingMode = .hybrid
    @State private var confirmDelete = false
    @State private var deletionReport = ""
    @State private var saveNote = ""
    @State private var testResult = ""
    @State private var testing = false

    var body: some View {
        TabView {
            reasoningTab.tabItem { Text("Reasoning") }
            privacyTab.tabItem { Text("Privacy & data") }
            aboutTab.tabItem { Text("About") }
        }
        .padding()
        .onAppear { config = model.reasoning; retentionDays = model.retention.savedSessionDays; processing = model.defaultProcessingMode }
    }

    private var reasoningTab: some View {
        Form {
            Picker("Provider", selection: $config.providerID) { ForEach(ProviderPresets.all) { Text($0.displayName).tag($0.id) } }
                .onChange(of: config.providerID) { _, id in if let p = ProviderPresets.preset(id: id) { config.baseURL = p.baseURL; config.routineModel = p.routineModel; config.strongModel = p.strongModel } }
            TextField("Base URL", text: $config.baseURL)
            TextField("Routine model", text: $config.routineModel)
            TextField("Stronger model (used only on “Go deeper”)", text: $config.strongModel)
            SecureField(model.hasAPIKey ? "API key (stored in Keychain; leave blank to keep)" : "API key", text: $apiKey)
            Text(config.preset.notes).font(.caption).foregroundStyle(.secondary)
            if let price = PriceRegistry.builtIn.price(provider: config.providerID, model: config.routineModel) {
                Text(String(format: "List price (%@): $%.2f in / $%.2f out per million tokens.", price.verifiedOn, price.inputPerMillion, price.outputPerMillion)).font(.caption).foregroundStyle(.secondary)
            }
            Stepper(value: $config.sessionCapUSD, in: 0.1...20, step: 0.25) { Text(String(format: "Session cap: $%.2f", config.sessionCapUSD)) }
            Stepper(value: $config.strongTurnAllowance, in: 0...20) { Text("Stronger turns per session: \(config.strongTurnAllowance)") }
            Toggle("Use the on-device model for question detection", isOn: $config.onDeviceForQuestionDetection)
            Toggle("Allow the on-device model as a fallback route", isOn: $config.onDeviceEnabled)
            Picker("Default processing", selection: $processing) { Text("Hybrid").tag(ProcessingMode.hybrid); Text("Local only").tag(ProcessingMode.localOnly) }
            HStack {
                Button(testing ? "Testing…" : "Test connection") { testing = true; Task { testResult = await model.testProviderConnection(); testing = false } }.disabled(testing || !model.hasAPIKey)
                Spacer()
                Text(saveNote).font(.caption).foregroundStyle(.secondary)
                Button("Save") { model.saveReasoning(config, apiKey: apiKey.isEmpty ? nil : apiKey); apiKey = ""; model.saveProcessingMode(processing); saveNote = model.hasAPIKey ? "Saved. Key is in the Keychain." : "Saved (no key)." }
            }
            if !testResult.isEmpty { Text(testResult).font(.caption).textSelection(.enabled) }
            Text("On-device model: \(model.onDeviceAvailability.available ? "available" : model.onDeviceAvailability.reason). Local speech: \(model.speechStatus.supported ? (model.speechStatus.installed ? "installed" : "downloadable") : "unsupported").").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var privacyTab: some View {
        Form {
            Stepper(value: $retentionDays, in: 1...365) { Text("Auto-delete saved sessions after \(retentionDays) days") }
                .onChange(of: retentionDays) { _, d in var r = model.retention; r.savedSessionDays = d; model.saveRetention(r) }
            Text("Raw audio: never written to disk. Screenshots: processed in memory only. Transcripts and suggestions: kept in memory until you press Save after a session. Logs: content-free, 14 days.").font(.caption).foregroundStyle(.secondary)
            Text("Cloud reasoning sends the current question, the selected window's recognised text, the retrieved evidence snippets and recent interviewer turns to \(model.reasoning.preset.displayName). Nothing is sent in local-only mode.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Export my data (JSON)…") { if let url = model.exportAllData() { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
                Button("Reveal diagnostics logs") { NSWorkspace.shared.activateFileViewerSelecting([model.logsDirectory]) }
            }
            Button("Delete all data…", role: .destructive) { confirmDelete = true }
                .confirmationDialog("Delete every document, claim, story, target, saved session, key and log on this Mac?", isPresented: $confirmDelete) {
                    Button("Delete everything", role: .destructive) { let job = model.deleteAllData(); deletionReport = job.failures.isEmpty ? "Deleted \(job.completed.count) items." : "Completed with failures: \(job.failures.joined(separator: "; "))" }
                }
            if !deletionReport.isEmpty { Text(deletionReport).font(.caption) }
        }
    }

    private var aboutTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Interview Assistant (alpha)").font(.headline)
            Text("Native macOS 26+, Apple Silicon. Local capture, local speech and OCR; optional cloud reasoning through an OpenAI-compatible provider you configure. The panel is an ordinary window and stays visible to screen sharing.")
            Text("Data directory: \(model.dataDirectory.path)").font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
    }
}

/// Headless scenarios for verification without synthetic input: `IA_SCENARIO=import|mock` with IA_DATA_DIR.
enum DebugScenario {
    @MainActor static func runIfRequested(_ model: AppModel) {
        let env = ProcessInfo.processInfo.environment
        guard let scenario = env["IA_SCENARIO"] else { return }
        Task { @MainActor in
            switch scenario {
            case "import":
                if let path = env["IA_RESUME"] { model.importDocument(at: URL(fileURLWithPath: path)); model.approveAll(in: nil) }
                if model.targets.isEmpty { model.saveTarget(InterviewTarget(role: "Backend Engineer", company: "Example Co", jobDescription: "Experience with Go and PostgreSQL. Strong knowledge of Kafka.")) }
                model.finishOnboarding()
            case "setup":
                model.finishOnboarding()
            case "session":
                model.finishOnboarding()
                let setup = SessionSetup(target: model.selectedTarget, mode: .live, scope: AssistanceScope(permittedByUser: true), processingMode: .hybrid, audioSource: nil, windowID: nil, autoAnswer: true)
                let c = model.makeCoordinator(setup: setup)
                await c.start()
                try? await Task.sleep(nanoseconds: 500_000_000)
                c.ask(manualText: env["IA_QUESTION"] ?? "Tell me about a time you improved the performance of a system.")
            default: break
            }
            if let shot = env["IA_SCREENSHOT"] {
                try? await Task.sleep(nanoseconds: UInt64((Double(env["IA_SCREENSHOT_DELAY"] ?? "6") ?? 6) * 1_000_000_000))
                if let number = NSApp.windows.first(where: { $0.isVisible && !($0 is NSPanel) })?.windowNumber {
                    let task = Process(); task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture"); task.arguments = ["-x", "-l", String(number), shot]; try? task.run(); task.waitUntilExit()
                }
                if env["IA_QUIT_AFTER"] == "1" { NSApp.terminate(nil) }
            }
        }
    }
}
