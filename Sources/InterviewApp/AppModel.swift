import Foundation
import SwiftUI
import Combine
import AppKit
import CryptoKit
import InterviewCore
import InterviewStorage
import InterviewEvidence
import InterviewMedia
import InterviewReasoning
import InterviewOrchestration

/// Application state shared by all views: encrypted store, configuration, evidence index, capture sources
/// and the current session. Everything stays on this Mac unless a cloud route is explicitly configured.
@MainActor
final class AppModel: ObservableObject {
    static let bundleID = "com.himanshudixit.interviewassistant"
    static let keychainService = "com.himanshudixit.interviewassistant"

    @Published var documents: [ProfileDocument] = []
    @Published var claims: [VerifiedClaim] = []
    @Published var stories: [Story] = []
    @Published var targets: [InterviewTarget] = []
    @Published var contradictions: [ContradictionChecker.Finding] = []
    @Published var selectedTargetID: EntityID?
    @Published var reasoning = ReasoningConfiguration()
    @Published var hasAPIKey = false
    @Published var defaultProcessingMode: ProcessingMode = .hybrid
    @Published var retention = RetentionPolicy()
    @Published var onboardingDone = false
    @Published var coordinator: SessionCoordinator?
    @Published var windows: [CaptureSourceDescriptor] = []
    @Published var applications: [CaptureSourceDescriptor] = []
    @Published var preflight: [PreflightItem] = []
    @Published var onDeviceAvailability = OnDeviceProvider.availability()
    @Published var speechStatus = TranscriptionService.LocaleStatus(supported: false, installed: false, identifier: "en-US")
    @Published var ocrWarm = false
    @Published var statusMessage = ""
    @Published var lastImport: [VerifiedClaim] = []
    @Published var savedSessions: [Session] = []

    let store: AppStore
    let keychain = KeychainStore(service: AppModel.keychainService)
    let telemetry: FileTelemetrySink
    let index = EvidenceIndex()
    let dataDirectory: URL
    let logsDirectory: URL
    let onDevice: OnDeviceProvider?
    let demoMode: Bool

    init() {
        let env = ProcessInfo.processInfo.environment
        let base = env["IA_DATA_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("InterviewAssistant")
        dataDirectory = base
        logsDirectory = base.appendingPathComponent("logs")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        telemetry = FileTelemetrySink(directory: logsDirectory, retentionDays: 14)
        demoMode = env["IA_DEMO"] == "1"
        var vault: DataVault
        var keyNote = ""
        if env["IA_EPHEMERAL_KEY"] == "1" {
            vault = .ephemeral()
        } else {
            do { vault = DataVault(key: try keychain.vaultKey()) }
            catch {
                // Keychain access denied (ad-hoc builds change signature between rebuilds). Fall back to a key file
                // in the data directory so the app keeps working, and say so.
                let keyURL = base.appendingPathComponent("vault.key")
                if let data = try? Data(contentsOf: keyURL), data.count == 32 { vault = DataVault(key: .init(data: data)) }
                else {
                    let key = SymmetricKeyBox.make()
                    try? key.withUnsafeBytes { Data($0) }.write(to: keyURL, options: [.atomic, .completeFileProtection])
                    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)
                    vault = DataVault(key: key)
                }
                keyNote = "Keychain access was declined, so the encryption key is kept in the app's data folder instead. Allow Keychain access next launch to use the Keychain."
            }
        }
        do {
            store = try AppStore(db: try SQLiteDatabase(path: base.appendingPathComponent("assistant.sqlite").path), vault: vault)
        } catch {
            store = (try? AppStore.inMemory())!
            keyNote = "Database could not be opened; running in memory."
        }
        onDevice = OnDeviceProvider.availability().available ? OnDeviceProvider() : nil
        load()
        if store.cannotDecryptExistingData { keyNote = "Existing data cannot be read with the current key. Quit, relaunch, and click Always Allow on the Keychain prompt." }
        if !keyNote.isEmpty { statusMessage = keyNote }
    }

    // MARK: loading and settings

    func load() {
        documents = (try? store.documents()) ?? []
        claims = (try? store.claims()) ?? []
        stories = (try? store.stories()) ?? []
        targets = (try? store.targets()) ?? []
        savedSessions = (try? store.sessions()) ?? []
        reasoning = (try? store.setting(ReasoningConfiguration.self, ReasoningConfiguration.settingsKey)) ?? ReasoningConfiguration()
        retention = (try? store.setting(RetentionPolicy.self, "retention")) ?? RetentionPolicy()
        defaultProcessingMode = (try? store.setting(ProcessingMode.self, "processingMode")) ?? .hybrid
        onboardingDone = (try? store.setting(Bool.self, "onboardingDone")) ?? false
        selectedTargetID = (try? store.setting(EntityID.self, "selectedTarget")) ?? targets.first?.id
        hasAPIKey = (try? keychain.getString(account: reasoning.keychainAccount)).map { !$0.isEmpty } ?? false
        contradictions = ContradictionChecker.check(claims)
        rebuildIndex()
        try? store.purgeSessions(olderThan: Date().addingTimeInterval(-Double(retention.savedSessionDays) * 86_400))
        Task { await self.refreshCapabilities() }
    }

    func rebuildIndex() { index.rebuild(claims: claims, stories: stories) }

    func refreshCapabilities() async {
        onDeviceAvailability = OnDeviceProvider.availability()
        speechStatus = await TranscriptionService.localeStatus("en-US")
        if !ocrWarm { await ScreenUnderstanding().warmUp(); ocrWarm = true }
        onDevice?.prewarm()
    }

    func saveReasoning(_ config: ReasoningConfiguration, apiKey: String?) {
        reasoning = config
        try? store.setSetting(ReasoningConfiguration.settingsKey, config)
        if let apiKey {
            if apiKey.isEmpty { try? keychain.delete(account: config.keychainAccount) } else { try? keychain.setString(apiKey, account: config.keychainAccount) }
        }
        hasAPIKey = (try? keychain.getString(account: config.keychainAccount)).map { !$0.isEmpty } ?? false
    }

    func saveRetention(_ r: RetentionPolicy) { retention = r; try? store.setSetting("retention", r) }
    func saveProcessingMode(_ m: ProcessingMode) { defaultProcessingMode = m; try? store.setSetting("processingMode", m) }
    func finishOnboarding() { onboardingDone = true; try? store.setSetting("onboardingDone", true) }
    func selectTarget(_ id: EntityID?) { selectedTargetID = id; if let id { try? store.setSetting("selectedTarget", id) } }
    var selectedTarget: InterviewTarget? { targets.first { $0.id == selectedTargetID } }

    // MARK: evidence

    func importDocument(at url: URL) {
        do {
            let imported = try DocumentIngestion.importFile(at: url)
            if let existing = documents.first(where: { $0.contentHash == imported.document.contentHash }) {
                statusMessage = "\(existing.filename) was already imported (same content)."
                return
            }
            try store.saveDocument(imported.document)
            let proposed = ClaimExtractor.propose(from: imported.text, documentID: imported.document.id)
            try store.saveClaims(proposed)
            documents.append(imported.document)
            claims.append(contentsOf: proposed)
            lastImport = proposed
            contradictions = ContradictionChecker.check(claims)
            statusMessage = "Imported \(imported.document.filename): \(proposed.count) claims proposed, none approved yet."
            telemetry.record(TelemetryEvent(name: "document.imported", category: "evidence", attributes: ["kind": imported.document.kind.rawValue, "claims": String(proposed.count)]))
        } catch let e as AssistantError { statusMessage = e.description } catch { statusMessage = "Import failed." }
    }

    func deleteDocument(_ id: EntityID) {
        try? store.deleteDocument(id)
        documents.removeAll { $0.id == id }
        claims.removeAll { $0.documentID == id }
        rebuildIndex()
    }

    func updateClaim(_ claim: VerifiedClaim, state: ApprovalState? = nil, text: String? = nil, category: ClaimCategory? = nil) {
        var c = claim
        if let state { c.state = state }
        if let text, text != c.text { c.text = text; c.userEdited = true }
        if let category { c.category = category }
        c.updatedAt = Date()
        try? store.saveClaim(c)
        if let i = claims.firstIndex(where: { $0.id == c.id }) { claims[i] = c }
        contradictions = ContradictionChecker.check(claims)
        rebuildIndex()
    }

    func approveAll(in documentID: EntityID?) {
        for c in claims where c.state == .proposed && c.category != .contact && (documentID == nil || c.documentID == documentID) { updateClaim(c, state: .approved) }
    }

    func saveStory(_ s: Story) {
        var story = s; story.updatedAt = Date()
        try? store.saveStory(story)
        if let i = stories.firstIndex(where: { $0.id == story.id }) { stories[i] = story } else { stories.append(story) }
        rebuildIndex()
    }

    func deleteStory(_ id: EntityID) { try? store.deleteStory(id); stories.removeAll { $0.id == id }; rebuildIndex() }

    func saveTarget(_ t: InterviewTarget) {
        var target = t
        target.requiredSkills = JobDescriptionMapper.skills(in: t.jobDescription)
        try? store.saveTarget(target)
        if let i = targets.firstIndex(where: { $0.id == target.id }) { targets[i] = target } else { targets.append(target) }
        if selectedTargetID == nil { selectTarget(target.id) }
    }

    func deleteTarget(_ id: EntityID) { try? store.deleteTarget(id); targets.removeAll { $0.id == id }; if selectedTargetID == id { selectTarget(targets.first?.id) } }

    func requirementMatches(for target: InterviewTarget) -> [RequirementMatch] {
        JobDescriptionMapper.map(jobDescription: target.jobDescription, approvedClaims: claims.filter { $0.state == .approved }, stories: stories)
    }

    var vocabulary: [String] {
        var terms: [String] = ["Kubernetes", "PostgreSQL", "Postgres", "Kafka", "RabbitMQ", "idempotent", "GraphQL", "gRPC", "Terraform", "LangGraph"]
        if let t = selectedTarget { terms += [t.company] + t.requiredSkills.map { $0.capitalized } }
        for c in claims where c.state == .approved {
            for word in c.text.split(separator: " ") where word.first?.isUppercase == true && word.count >= 5 && word.allSatisfy({ $0.isLetter || $0.isNumber }) { terms.append(String(word)) }
        }
        return Array(Set(terms)).sorted()
    }

    // MARK: capture sources

    /// Permission-free listings: running apps from NSWorkspace, windows from the window server. Titles for
    /// other apps' windows appear only once Screen Recording is granted.
    func refreshSources() async {
        applications = CaptureManager.runningApplications()
        windows = CaptureManager.windowsViaWindowList()
        screenRecordingGranted = CaptureManager.screenRecordingGranted()
    }

    @Published var screenRecordingGranted = CaptureManager.screenRecordingGranted()

    func requestScreenRecording() {
        _ = CaptureManager.requestScreenRecording()
        screenRecordingGranted = CaptureManager.screenRecordingGranted()
    }

    /// macOS applies a new Screen Recording grant only to a fresh process.
    func relaunch() {
        let url = Bundle.main.bundleURL
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { NSApp.terminate(nil) }
        }
    }

    /// Sends one tiny request through the configured cloud provider and reports what happened.
    func testProviderConnection() async -> String {
        guard hasAPIKey else { return "No API key saved yet." }
        let config = reasoning
        let keychain = self.keychain
        let provider = OpenAICompatibleProvider(preset: config.preset, baseURL: config.baseURL, apiKey: { try? keychain.getString(account: config.keychainAccount) })
        let executor = ReasoningExecutor(ledger: BudgetLedger(capUSD: 0.05), prices: .builtIn, telemetry: telemetry)
        let request = ReasoningRequest(model: config.routineModel, messages: [ChatMessage(role: .system, content: "Reply with the single word OK."), ChatMessage(role: .user, content: "Connection test.")], maxOutputTokens: 8, temperature: 0, deadline: 20)
        let collector = TextCollector()
        do {
            let run = try await executor.execute(request, provider: provider, route: .routineCloud, sessionID: nil) { event in if case .delta(let d) = event { collector.append(d) } }
            let reply = collector.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return String(format: "Connected to %@ (%@): replied \"%@\" in %.0f ms, %d in / %d out tokens, about $%.5f.", config.preset.displayName, config.routineModel, reply.prefix(40) as CVarArg, run.totalMs ?? 0, run.inputTokens, run.outputTokens, run.estimatedCostUSD)
        } catch let e as AssistantError { return "Failed: \(e.description). \(e.recovery)" } catch { return "Failed: \(error)" }
    }

    // MARK: sessions

    /// Builds the reasoning stack for one session or practice run; it never touches the live session slot.
    func makeOrchestrator(processingMode: ProcessingMode) -> AnswerOrchestrator {
        let ledger = BudgetLedger(capUSD: processingMode == .hybrid ? reasoning.sessionCapUSD : 0, strongTurnAllowance: reasoning.strongTurnAllowance)
        let executor = ReasoningExecutor(ledger: ledger, prices: .builtIn, telemetry: telemetry)
        var cloud: ReasoningProvider? = nil
        if demoMode {
            cloud = MockProvider(id: "demo", displayName: "Demo provider", behaviour: .succeed(MockProvider.sampleAnswer), chunkDelayNanoseconds: 15_000_000)
        } else if hasAPIKey && processingMode == .hybrid {
            let config = reasoning
            let keychain = self.keychain
            cloud = OpenAICompatibleProvider(preset: config.preset, baseURL: config.baseURL, apiKey: { try? keychain.getString(account: config.keychainAccount) })
        }
        return AnswerOrchestrator(index: index, executor: executor, cloud: cloud, onDevice: reasoning.onDeviceEnabled ? onDevice : nil, configuration: reasoning, telemetry: telemetry)
    }

    func makeCoordinator(setup: SessionSetup) -> SessionCoordinator {
        let orchestrator = makeOrchestrator(processingMode: setup.processingMode)
        let detector = QuestionDetector(onDevice: reasoning.onDeviceForQuestionDetection ? onDevice : nil, telemetry: telemetry)
        let coordinator = SessionCoordinator(setup: setup, store: store, telemetry: telemetry, answers: orchestrator, detector: detector, pricePolicyVersion: PriceRegistry.builtIn.version, deviceClass: deviceClass)
        self.coordinator = coordinator
        return coordinator
    }

    func endSession() {
        coordinator = nil
        savedSessions = (try? store.sessions()) ?? []
    }

    var deviceClass: String {
        let gb = ProcessInfo.processInfo.physicalMemory / 1_073_741_824
        return "apple-silicon-\(gb)gb"
    }

    // MARK: privacy

    func deleteAllData() -> DeletionJob {
        let job = store.deleteEverything(extraPaths: [logsDirectory])
        try? keychain.delete(account: reasoning.keychainAccount)
        load()
        return job
    }

    func exportNotes(for session: Session) -> String {
        let questions = (try? store.questions(sessionID: session.id)) ?? []
        let suggestions = (try? store.suggestions(sessionID: session.id)) ?? []
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short
        var md = "# Interview notes — \(f.string(from: session.startedAt))\n\nMode: \(session.mode.rawValue). Scope: \(session.scope.summary).\n\n"
        for q in questions {
            md += "## \(q.kind.label): \(q.text)\n\n"
            for s in suggestions where s.questionID == q.id {
                md += "**Say first:** \(s.shortAnswer)\n\n"
                for p in s.keyPoints { md += "- \(p.text) _(\(p.status.label))_\n" }
                if !s.assumptions.isEmpty { md += "\nAssumptions: " + s.assumptions.joined(separator: "; ") + "\n" }
                if !s.missingInformation.isEmpty { md += "\nNeeds confirmation: " + s.missingInformation.joined(separator: "; ") + "\n" }
                if let d = s.optionalDetail { md += "\n<details><summary>Detail</summary>\n\n\(d)\n\n</details>\n" }
                md += "\n"
            }
        }
        let review = ReviewBuilder.heuristic(questions: questions, suggestions: suggestions)
        md += "## Review\n\n- Strongest: \(review.strongest)\n- Gap: \(review.gap)\n- Next: \(review.next)\n"
        return md
    }

    func exportAllData() -> URL? {
        struct Export: Codable { var documents: [ProfileDocument]; var claims: [VerifiedClaim]; var stories: [Story]; var targets: [InterviewTarget]; var sessions: [Session] }
        let export = Export(documents: documents, claims: claims, stories: stories, targets: targets, sessions: savedSessions)
        guard let data = try? JSONCoding.encoder.encode(export) else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("interview-assistant-export.json")
        try? data.write(to: url)
        return url
    }
}


final class TextCollector: @unchecked Sendable {
    private let lock = NSLock(); private var parts: [String] = []
    func append(_ s: String) { lock.lock(); parts.append(s); lock.unlock() }
    var text: String { lock.lock(); defer { lock.unlock() }; return parts.joined() }
}

enum SymmetricKeyBox {
    static func make() -> CryptoKit.SymmetricKey { CryptoKit.SymmetricKey(size: .bits256) }
}
