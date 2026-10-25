import Foundation
import Combine
import CoreGraphics
import InterviewCore
import InterviewStorage
import InterviewEvidence
import InterviewMedia
import InterviewReasoning

public struct SessionSetup: Sendable {
    public var target: InterviewTarget?
    public var mode: SessionMode
    public var scope: AssistanceScope
    public var processingMode: ProcessingMode
    public var audioSource: AudioSource?
    public var windowID: UInt32?
    public var windowCropTopPoints: CGFloat
    public var locale: String
    public var vocabulary: [String]
    public var retention: RetentionPolicy
    public var autoAnswer: Bool
    public var endpointPauseMs: Double
    public var screenIntervalSeconds: Double
    public init(target: InterviewTarget?, mode: SessionMode, scope: AssistanceScope, processingMode: ProcessingMode, audioSource: AudioSource?, windowID: UInt32?, windowCropTopPoints: CGFloat = 0, locale: String = "en-US", vocabulary: [String] = [], retention: RetentionPolicy = RetentionPolicy(), autoAnswer: Bool = true, endpointPauseMs: Double = 500, screenIntervalSeconds: Double = 1.0) {
        self.target = target; self.mode = mode; self.scope = scope; self.processingMode = processingMode; self.audioSource = audioSource; self.windowID = windowID
        self.windowCropTopPoints = windowCropTopPoints; self.locale = locale; self.vocabulary = vocabulary; self.retention = retention; self.autoAnswer = autoAnswer
        self.endpointPauseMs = endpointPauseMs; self.screenIntervalSeconds = screenIntervalSeconds
    }
}

/// Material held in memory after Stop for the save-or-discard step (§5.4). Never staged on disk.
public struct PendingSave: Sendable {
    public var deadline: Date
    public var segments: [TranscriptSegment]
    public var questions: [Question]
    public var suggestions: [Suggestion]
    public var evidence: [ScreenEvidence]
}

final class ContextHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var value: ActiveContext
    init(_ v: ActiveContext) { value = v }
    var current: ActiveContext { get { lock.lock(); defer { lock.unlock() }; return value } set { lock.lock(); value = newValue; lock.unlock() } }
}

/// Owns one session: capture, transcription, question detection, answer generation, cancellation,
/// pause/stop semantics and the save-or-discard step (plan §6.4 SessionCoordinator, §5.3, §5.4, §14.3).
@MainActor
public final class SessionCoordinator: ObservableObject {
    @Published public private(set) var status = SessionStatus()
    @Published public private(set) var finals: [TranscriptSegment] = []
    @Published public private(set) var partial = ""
    @Published public private(set) var questions: [Question] = []
    @Published public private(set) var activeQuestion: Question?
    @Published public private(set) var suggestion: Suggestion?
    @Published public private(set) var previousSuggestion: Suggestion?
    @Published public private(set) var pinned: Suggestion?
    @Published public private(set) var screen: ScreenEvidence?
    @Published public private(set) var usage: UsageSnapshot
    @Published public private(set) var levelDbfs: Double = -120
    @Published public private(set) var lastError: AssistantError?
    @Published public private(set) var routeNote = ""
    @Published public private(set) var detectionNote = ""
    @Published public private(set) var pendingSave: PendingSave?
    @Published public private(set) var gapCount = 0
    @Published public private(set) var events: [SessionEvent] = []
    @Published public private(set) var screenSourceLost = false
    @Published public private(set) var screenStale = false

    public private(set) var session: Session
    public let setup: SessionSetup
    public let answers: AnswerOrchestrator
    let store: AppStore
    let telemetry: TelemetrySink
    let detector: QuestionDetector
    let audio = AudioPipeline()
    let transcription = TranscriptionService()
    let activity = SpeechActivityTracker()
    let capture = CaptureManager()
    let ocr = ScreenUnderstanding()
    let clock = RevisionClock()
    private let context: ContextHolder
    private var transcriptTask: Task<Void, Never>?
    private var endpointTask: Task<Void, Never>?
    private var screenTask: Task<Void, Never>?
    private var generationTask: Task<Void, Never>?
    private var saveTimer: Task<Void, Never>?
    private var seq = 0
    private var allSuggestions: [Suggestion] = []
    private var allEvidence: [ScreenEvidence] = []
    private var lastOCR: OCRResult?
    private var lastImageHash: String?
    private var recentTurns: [String] = []
    private var lastLevelPublish = Date.distantPast
    private var reconnectAttempts = 0
    private var offline = false

    public init(setup: SessionSetup, store: AppStore, telemetry: TelemetrySink, answers: AnswerOrchestrator, detector: QuestionDetector, pricePolicyVersion: String, deviceClass: String) {
        self.setup = setup; self.store = store; self.telemetry = telemetry; self.answers = answers; self.detector = detector
        self.session = Session(targetID: setup.target?.id, mode: setup.mode, scope: setup.scope, processingMode: setup.processingMode, retention: setup.retention, pricePolicyVersion: pricePolicyVersion, deviceClass: deviceClass)
        self.usage = UsageSnapshot(capUSD: 0, reservedUSD: 0, settledUSD: 0, routineTurnsUsed: 0, strongTurnsUsed: 0, imageAnalysesUsed: 0)
        self.context = ContextHolder(ActiveContext(epoch: 0, questionID: nil, questionRevision: 0, screenRevision: nil))
        transcription.corrector = setup.vocabulary.isEmpty ? nil : VocabularyCorrector(terms: setup.vocabulary)
    }

    public var audioProcessCount: Int { audio.tappedProcessCount }

    public var scopeSentence: String {
        var parts = [setup.scope.summary]
        if let a = setup.audioSource { parts.append("audio from \(a.name) via \(a.routeLabel)") }
        parts.append(setup.windowID != nil ? "selected window" : "no screen analysis")
        parts.append(setup.processingMode.label.lowercased())
        return parts.joined(separator: "; ")
    }

    // MARK: lifecycle

    public func start() async {
        guard PhaseTransition.canTransition(from: status.phase, to: .listening) || status.phase == .idle else { return }
        setPhase(.preparing)
        usage = await answers.executor.ledger.snapshot()
        do {
            if setup.windowID != nil, !CaptureManager.screenRecordingGranted() {
                status.blockers.insert(.permissionRequired)
                fail(.permissionDenied("Screen Recording"))
                return
            }
            if setup.scope.captions {
                let events = try await transcription.start(locale: Locale(identifier: setup.locale), fastResults: true)
                startTranscriptConsumer(events)
                try await startAudio()
            }
            if setup.windowID != nil && setup.scope.screenAnalysis { startScreenWatcher() }
            startEndpointLoop()
            setPhase(.ready)
            setPhase(.listening)
            record(.stateChanged, .status(status))
            telemetry.record(TelemetryEvent(name: "session.started", category: "session", attributes: ["mode": setup.mode.rawValue, "processing": setup.processingMode.rawValue, "audio_route": setup.audioSource?.routeLabel ?? "none", "screen": setup.windowID == nil ? "no" : "yes"]))
        } catch let e as AssistantError { fail(e); setPhase(.idle) }
        catch let e as AudioPipelineError {
            switch e {
            case .permission: status.blockers.insert(.permissionRequired); fail(.permissionDenied("Screen Recording"))
            case .noAudioProcesses:
                // The tap keeps looking for the app's audio processes; the session can run with manual questions meanwhile.
                fail(.sourceLost(e.description)); status.degradations.insert(.reconnecting)
                setPhase(.ready); setPhase(.listening); return
            default: fail(.sourceLost(e.description)); status.blockers.insert(.sourceUnavailable)
            }
            Task { try? await self.transcription.stop() }
            setPhase(.idle)
        }
        catch { fail(.internalFailure("\(error)")); setPhase(.idle) }
    }

    public func pause() {
        guard status.isCapturing else { return }
        cancelGeneration(reason: "paused")
        Task { await self.audio.stop(); try? await self.transcription.stop() }
        endpointTask?.cancel(); screenTask?.cancel(); transcriptTask?.cancel()
        partial = ""
        setPhase(.paused)
        telemetry.record(TelemetryEvent(name: "session.paused", category: "session"))
    }

    public func resume() async {
        guard status.phase == .paused else { return }
        do {
            if setup.scope.captions {
                let events = try await transcription.start(locale: Locale(identifier: setup.locale), fastResults: true)
                startTranscriptConsumer(events)
                try await startAudio()
            }
            if setup.windowID != nil && setup.scope.screenAnalysis { startScreenWatcher() }
            startEndpointLoop()
            setPhase(.listening)
        } catch { fail(.sourceLost("\(error)")); status.blockers.insert(.sourceUnavailable) }
    }

    /// Stops collection, invalidates pending work, discards media, and opens the save-or-discard window.
    public func stop() {
        cancelGeneration(reason: "stopped")
        clock.bumpEpoch(); syncContext()
        Task { await self.audio.stop(); try? await self.transcription.stop() }
        endpointTask?.cancel(); screenTask?.cancel(); transcriptTask?.cancel()
        partial = ""
        session.endedAt = Date()
        let deadline = Date().addingTimeInterval(Double(setup.retention.saveOrDiscardWindowSeconds))
        pendingSave = PendingSave(deadline: deadline, segments: finals, questions: questions, suggestions: allSuggestions, evidence: allEvidence)
        setPhase(.stopped)
        saveTimer?.cancel()
        saveTimer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(1, deadline.timeIntervalSinceNow) * 1_000_000_000))
            await MainActor.run { self?.discard(expired: true) }
        }
        Task { self.usage = await self.answers.executor.ledger.snapshot() }
        telemetry.record(TelemetryEvent(name: "session.stopped", category: "session", attributes: ["questions": String(questions.count), "suggestions": String(allSuggestions.count), "gaps": String(gapCount)]))
    }

    public func save() {
        guard let pending = pendingSave else { return }
        do {
            var s = session; s.scope.retainTranscript = true
            try store.saveSession(s)
            try store.saveSegments(pending.segments)
            for q in pending.questions { try store.saveQuestion(q) }
            for sug in pending.suggestions { try store.saveSuggestion(sug, sessionID: session.id) }
            for e in pending.evidence { try store.saveEvidence(e) }
            telemetry.record(TelemetryEvent(name: "session.saved", category: "session"))
        } catch { lastError = .internalFailure("save failed") }
        saveTimer?.cancel()
        pendingSave = nil
    }

    public func discard(expired: Bool = false) {
        guard pendingSave != nil else { return }
        pendingSave = nil
        saveTimer?.cancel()
        finals = []; questions = []; allSuggestions = []; allEvidence = []; suggestion = nil; previousSuggestion = nil; activeQuestion = nil; screen = nil
        telemetry.record(TelemetryEvent(name: expired ? "session.discard_expired" : "session.discarded", category: "session"))
    }

    // MARK: user actions

    /// Manual trigger (F16 fallback) and answer controls (F39). With no text, re-asks the active question.
    public func ask(manualText: String? = nil, control: AnswerControl = .standard, correction: String? = nil) {
        guard status.isCapturing || status.phase == .ready else { return }
        guard setup.scope.allowsAnswerGeneration else { routeNote = "Answer suggestions are off for this session (scope)."; return }
        if let text = manualText?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            let kind = QuestionTypeClassifier.kind(for: text, screenLooksLikeCode: lastOCR?.looksLikeCode ?? false, utterance: .question)
            let q = Question(sessionID: session.id, text: text, kind: kind, revision: clock.nextRevision(for: "question"), source: .manual, screenEvidenceID: screen?.id, screenRevision: screen?.revision)
            activate(q)
        } else if activeQuestion == nil, let screenText = screen?.text, !screenText.isEmpty {
            let kind = QuestionTypeClassifier.kind(for: screenText, screenLooksLikeCode: lastOCR?.looksLikeCode ?? false, utterance: .question)
            let q = Question(sessionID: session.id, text: "Help with what is on the shared screen.", kind: kind, revision: clock.nextRevision(for: "question"), source: .screen, screenEvidenceID: screen?.id, screenRevision: screen?.revision)
            activate(q)
        }
        guard activeQuestion != nil else { detectionNote = "No question yet. Type one, or wait for the interviewer."; return }
        generate(control: control, correction: correction)
    }

    public func correctActiveQuestion(_ text: String) {
        guard var q = activeQuestion else { return }
        cancelGeneration(reason: "question corrected")
        q.text = text
        q.revision = clock.nextRevision(for: "question")
        q.updatedAt = Date()
        replaceActive(q)
        record(.questionUpdated, .question(q))
        if setup.autoAnswer && setup.scope.allowsAnswerGeneration { generate(control: .standard, correction: nil) }
    }

    public func dismissActiveQuestion() {
        cancelGeneration(reason: "dismissed")
        if var q = activeQuestion { q.status = .dismissed; replaceActive(q) }
        activeQuestion = nil
        if status.isCapturing { setPhase(.listening) }
    }

    public func pin() { pinned = suggestion }

    /// Test hooks: silence the tapped test process at the speaker; clear a surfaced error.
    public func enableTestMute() { audio.muteTappedProcesses = true }
    public func clearErrorForTest() { lastError = nil }

    public func recapture() async {
        guard let id = setup.windowID else { return }
        await captureScreen(windowID: id, force: true)
    }

    // MARK: audio and transcript

    private func startAudio() async throws {
        guard let source = setup.audioSource else { return }
        audio.onChunk = { [transcription] chunk in transcription.feed(chunk) }
        audio.onLevel = { [weak self, activity] db in
            activity.observe(dbfs: db)
            Task { @MainActor [weak self] in
                guard let self, Date().timeIntervalSince(self.lastLevelPublish) > 0.1 else { return }
                self.lastLevelPublish = Date(); self.levelDbfs = db
                if self.status.degradations.contains(.reconnecting) && self.audio.isRunning { self.status.degradations.remove(.reconnecting); self.lastError = nil }
            }
        }
        audio.onStopped = { [weak self] reason in Task { @MainActor in await self?.audioStopped(reason) } }
        try await audio.start(source)
        reconnectAttempts = 0
    }

    private func audioStopped(_ reason: String) async {
        guard status.isCapturing, let source = setup.audioSource else { return }
        status.degradations.insert(.reconnecting)
        record(.degradationChanged, .degradation(.reconnecting, active: true))
        while reconnectAttempts < 3 {
            reconnectAttempts += 1
            try? await Task.sleep(nanoseconds: UInt64(0.5 * Double(reconnectAttempts) * 1_000_000_000))
            if (try? await audio.start(source)) != nil {
                status.degradations.remove(.reconnecting)
                gapCount += 1
                finals.append(TranscriptSegment(sessionID: session.id, stream: .remote, start: transcription.secondsFed, end: transcription.secondsFed, text: "[audio reconnected]", isFinal: true, isGap: true))
                return
            }
        }
        status.degradations.remove(.reconnecting)
        status.blockers.insert(.sourceUnavailable)
        fail(.sourceLost(source.name))
    }

    private func startTranscriptConsumer(_ events: AsyncStream<TranscriptEvent>) {
        transcriptTask?.cancel()
        transcriptTask = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                await self.handle(event)
            }
        }
    }

    private func handle(_ event: TranscriptEvent) async {
        switch event.kind {
        case .partial:
            partial = event.text
        case .gap:
            gapCount += 1
            finals.append(TranscriptSegment(sessionID: session.id, stream: .remote, start: event.start, end: event.end, text: event.text, isFinal: true, isGap: true))
        case .final:
            partial = ""
            guard !event.text.isEmpty else { return }
            let segment = TranscriptSegment(sessionID: session.id, stream: .remote, start: event.start, end: event.end, text: event.text, revision: 1, isFinal: true)
            finals.append(segment)
            if finals.count > 400 { finals.removeFirst(finals.count - 400) }
            recentTurns.append("Interviewer: " + event.text)
            if recentTurns.count > 8 { recentTurns.removeFirst() }
            record(.transcriptFinal, .transcript(segment))
            await detectQuestion(in: segment)
        }
    }

    private func detectQuestion(in segment: TranscriptSegment) async {
        let detected = await detector.detect(segment.text, previousQuestionExists: activeQuestion != nil, screenLooksLikeCode: lastOCR?.looksLikeCode ?? false)
        detectionNote = "\(detected.utterance.rawValue) (\(Int(detected.confidence * 100))%)\(detected.usedOnDevice ? ", on-device" : "")"
        guard status.isCapturing else { return }
        switch detected.utterance {
        case .statement:
            return
        case .question, .followup:
            // Fold the preceding constraint sentence into the question when it arrived just before.
            var text = segment.text
            var refs = [segment.id]
            if let prev = finals.dropLast().last, !prev.isGap, segment.start - prev.end < 4, Tokenizer.words(prev.text).count >= 4,
               QuestionRuleClassifier.classify(prev.text, previousQuestionExists: false).kind == .statement {
                text = prev.text + " " + text; refs.insert(prev.id, at: 0)
            }
            let q = Question(sessionID: session.id, text: text, kind: detected.kind, revision: clock.nextRevision(for: "question"), source: .audio, transcriptRefs: refs, screenEvidenceID: screen?.id, screenRevision: screen?.revision, parentQuestionID: detected.utterance == .followup ? activeQuestion?.id : nil)
            activate(q)
            if setup.autoAnswer && setup.scope.allowsAnswerGeneration && detected.confidence >= detector.minimumConfidenceForAutoAnswer { generate(control: .standard, correction: nil) }
        case .correction:
            guard let parent = activeQuestion else { return }
            let q = Question(sessionID: session.id, text: parent.text + " Correction from the interviewer: " + segment.text, kind: .correction, revision: clock.nextRevision(for: "question"), source: .audio, transcriptRefs: parent.transcriptRefs + [segment.id], screenEvidenceID: screen?.id, screenRevision: screen?.revision, parentQuestionID: parent.id)
            activate(q)
            if setup.autoAnswer && setup.scope.allowsAnswerGeneration { generate(control: .standard, correction: nil) }
        }
    }

    private func startEndpointLoop() {
        endpointTask?.cancel()
        endpointTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard let self else { return }
                if self.activity.endpointIfSilent(pauseMs: self.setup.endpointPauseMs) != nil { try? await self.transcription.finalizeNow() }
            }
        }
    }

    // MARK: screen

    private func startScreenWatcher() {
        guard let id = setup.windowID else { return }
        screenTask?.cancel()
        screenTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.captureScreen(windowID: id, force: false)
                try? await Task.sleep(nanoseconds: UInt64(self.setup.screenIntervalSeconds * 1_000_000_000))
            }
        }
    }

    private func captureScreen(windowID: UInt32, force: Bool) async {
        let state = await capture.windowState(id: windowID)
        guard state.exists else {
            if !screenSourceLost { screenSourceLost = true; screenStale = true; record(.sourceChanged, .source(id: "window", reason: "closed")); if var s = screen { s.freshness = .sourceClosed; screen = s } }
            return
        }
        screenSourceLost = false
        do {
            let shot = try await capture.captureWindow(id: windowID, cropTopPoints: setup.windowCropTopPoints)
            let imageHash = Self.hash(of: shot.image)
            if !force, imageHash == lastImageHash { screenStale = false; return }
            lastImageHash = imageHash
            let result = try await ocr.recognize(image: shot.image, codeHint: lastOCR?.looksLikeCode ?? true)
            guard force || ScreenUnderstanding.changed(previous: lastOCR, current: result) else { screenStale = false; return }
            let numbersChanged = lastOCR.map { Set(Tokenizer.words($0.text).filter { $0.first?.isNumber == true }) != Set(Tokenizer.words(result.text).filter { $0.first?.isNumber == true }) } ?? false
            lastOCR = result
            let revision = clock.nextRevision(for: "screen")
            let evidence = ScreenEvidence(sessionID: session.id, sourceID: "window:\(windowID)", sourceTitleHash: TextHash.sha256(state.title), revision: revision, text: result.text, regions: result.regions, contentHash: result.contentHash, freshness: result.text.isEmpty ? .blank : (state.onScreen ? .fresh : .sourceMinimized), looksLikeCode: result.looksLikeCode)
            screen = evidence
            screenStale = false
            allEvidence.append(evidence)
            if allEvidence.count > 50 { allEvidence.removeFirst() }
            syncContext()
            record(.screenUpdated, .screen(evidence))
            if status.phase == .generating, numbersChanged {
                cancelGeneration(reason: "screen constraints changed (revision \(revision))")
                routeNote = "The shared screen changed (revision \(revision)). Previous answer kept for reference; press Ask to refresh."
            }
        } catch {
            screenStale = true
        }
    }

    static func hash(of image: CGImage) -> String {
        guard let data = image.dataProvider?.data as Data? else { return UUID().uuidString }
        // Sample every 97th byte: cheap and sensitive to any pixel-level change in practice.
        var sample = Data(capacity: data.count / 97 + 1)
        var i = 0
        while i < data.count { sample.append(data[i]); i += 97 }
        return TextHash.sha256(sample)
    }

    // MARK: generation

    private func activate(_ q: Question) {
        cancelGeneration(reason: "new question")
        if var old = activeQuestion, old.id != q.id {
            old.status = (suggestion?.completed == true && suggestion?.questionID == old.id) ? .answered : .superseded
            replaceActive(old)
        }
        activeQuestion = q
        questions.append(q)
        if questions.count > 200 { questions.removeFirst() }
        clock.bumpEpoch()
        syncContext()
        if let current = suggestion, current.questionID != q.id { previousSuggestion = current; suggestion = nil }
        record(.questionCreated, .question(q))
        setPhase(.questionDetected)
    }

    private func replaceActive(_ q: Question) {
        if let i = questions.firstIndex(where: { $0.id == q.id }) { questions[i] = q }
        if activeQuestion?.id == q.id { activeQuestion = q }
        syncContext()
    }

    private func syncContext() {
        context.current = ActiveContext(epoch: clock.epoch, questionID: activeQuestion?.id, questionRevision: activeQuestion?.revision ?? 0, screenRevision: screen?.revision)
    }

    private func generate(control: AnswerControl, correction: String?) {
        guard let q = activeQuestion else { return }
        cancelGeneration(reason: "regenerate")
        let stamp = GenerationStamp(epoch: clock.epoch, questionID: q.id, questionRevision: q.revision, screenRevision: screen?.revision)
        let holder = context
        let request = AnswerRequest(question: q, screen: setup.scope.screenAnalysis ? screen : nil, target: setup.target, recentTurns: recentTurns, summary: nil, control: control, correctionNote: correction, stamp: stamp)
        let sessionID = session.id
        let processingMode = setup.processingMode
        setPhase(.generating)
        lastError = nil
        generationTask = Task { [weak self] in
            guard let self else { return }
            let isCurrent: @Sendable () -> Bool = { CurrencyGate.isCurrent(stamp, against: holder.current) }
            let publish: @Sendable (Suggestion) -> Void = { s in Task { @MainActor [weak self] in if isCurrent() { self?.suggestion = s } } }
            do {
                let outcome = try await self.answers.generate(request, sessionID: sessionID, processingMode: processingMode, offline: self.offline, isCurrent: isCurrent, publish: publish)
                await self.finishGeneration(outcome, stamp: stamp)
            } catch let e as AssistantError {
                await self.handleGenerationError(e, request: request, stamp: stamp, holder: holder, sessionID: sessionID)
            } catch {
                await self.handleGenerationError(.internalFailure("\(error)"), request: request, stamp: stamp, holder: holder, sessionID: sessionID)
            }
        }
    }

    private func finishGeneration(_ outcome: AnswerOutcome, stamp: GenerationStamp) async {
        if let run = outcome.run { try? store.saveRun(run) }
        usage = await answers.executor.ledger.snapshot()
        guard CurrencyGate.isCurrent(stamp, against: context.current) else { return }
        allSuggestions.append(outcome.suggestion)
        suggestion = outcome.suggestion
        routeNote = outcome.routing.degraded ? outcome.routing.reason : ""
        if outcome.routing.degraded && outcome.routing.route == .onDevice { status.degradations.insert(.localFallback) } else { status.degradations.remove(.localFallback) }
        if await answers.executor.ledger.isExhausted { status.degradations.insert(.budgetExhausted) }
        else if await answers.executor.ledger.isLow { status.degradations.insert(.budgetLow) }
        record(.answerCompleted, .suggestion(outcome.suggestion))
        setPhase(.answerReady)
    }

    private func handleGenerationError(_ error: AssistantError, request: AnswerRequest, stamp: GenerationStamp, holder: ContextHolder, sessionID: EntityID) async {
        guard CurrencyGate.isCurrent(stamp, against: holder.current) else { return }
        if case .cancelled = error { return }
        switch error {
        case .insufficientQuota: status.degradations.insert(.budgetExhausted)
        case .transientNetwork: offline = true; status.degradations.insert(.offline)
        case .providerUnavailable, .providerTimeout, .providerRateLimited: status.degradations.insert(.providerDown)
        default: break
        }
        // One controlled fallback (§9.5, §14.3): cloud failed and the on-device route exists.
        if request.control != .depth, setup.processingMode == .hybrid, answers.onDevice != nil, OnDeviceProvider.availability().available, request.stamp == stamp {
            routeNote = "Cloud route failed (\(error.code)); using the on-device model."
            status.degradations.insert(.localFallback)
            do {
                let isCurrent: @Sendable () -> Bool = { CurrencyGate.isCurrent(stamp, against: holder.current) }
                let publish: @Sendable (Suggestion) -> Void = { s in Task { @MainActor [weak self] in if isCurrent() { self?.suggestion = s } } }
                let outcome = try await answers.generate(request, sessionID: sessionID, processingMode: .localOnly, offline: offline, isCurrent: isCurrent, publish: publish)
                await finishGeneration(outcome, stamp: stamp)
                return
            } catch let e as AssistantError { fail(e) } catch { fail(.internalFailure("\(error)")) }
        } else {
            fail(error)
        }
        setPhase(.questionDetected)
    }

    private func cancelGeneration(reason: String) {
        guard let task = generationTask else { return }
        task.cancel()
        generationTask = nil
        if let s = suggestion, !s.completed {
            var stale = s; stale.superseded = true
            previousSuggestion = stale
            suggestion = nil
            Task { await self.answers.cancel(suggestionID: s.id) }
            record(.answerInvalidated, .invalidated(suggestionID: s.id, reason: reason))
        } else {
            record(.answerInvalidated, .invalidated(suggestionID: EntityID(), reason: reason + " (no block had been published)"))
        }
    }

    // MARK: helpers

    private func setPhase(_ phase: SessionPhase) {
        guard PhaseTransition.canTransition(from: status.phase, to: phase) else { return }
        status.phase = phase
        if phase == .listening { status.blockers.remove(.sourceUnavailable) }
    }

    private func fail(_ error: AssistantError) {
        lastError = error
        record(.error, .failure(code: error.code, message: error.description, recovery: error.recovery))
        telemetry.record(TelemetryEvent(name: "session.error", category: "session", attributes: ["code": error.code]))
    }

    private func record(_ type: SessionEventType, _ payload: SessionEventPayload) {
        seq += 1
        let event = SessionEvent(sessionID: session.id, seq: seq, type: type, epoch: clock.epoch, questionRevision: activeQuestion?.revision, payload: payload)
        events.append(event)
        if events.count > 200 { events.removeFirst(events.count - 200) }
    }
}
