import Testing
import Foundation
@testable import InterviewOrchestration
import InterviewCore
import InterviewStorage
import InterviewEvidence
import InterviewReasoning

@Suite("Answer orchestration")
struct AnswerOrchestrationTests {
    func makeOrchestrator(provider: MockProvider, cap: Double = 1.0) -> AnswerOrchestrator {
        let index = EvidenceIndex(useEmbeddings: false)
        index.rebuild(claims: [VerifiedClaim(text: "Collapsed request fan-out on the fare comparison screen into a single bulk entitlements endpoint", category: .achievement, state: .approved)], stories: [])
        let prices = PriceRegistry(version: "t", entries: [ModelPrice(provider: "mock", model: "routine", inputPerMillion: 0.1, outputPerMillion: 0.5, verifiedOn: "t"), ModelPrice(provider: "mock", model: "strong", inputPerMillion: 2, outputPerMillion: 10, verifiedOn: "t")])
        let executor = ReasoningExecutor(ledger: BudgetLedger(capUSD: cap), prices: prices, telemetry: InMemoryTelemetry())
        var config = ReasoningConfiguration(providerID: "mock", baseURL: "x", routineModel: "routine", strongModel: "strong")
        config.onDeviceEnabled = false
        return AnswerOrchestrator(index: index, executor: executor, cloud: provider, onDevice: nil, configuration: config, telemetry: InMemoryTelemetry())
    }

    @Test func streamsVerifiedBlocksIntoASuggestion() async throws {
        let provider = MockProvider(behaviour: .succeed(MockProvider.sampleAnswer))
        let orchestrator = makeOrchestrator(provider: provider)
        let q = Question(sessionID: EntityID(), text: "How did you reduce request fan-out on the fare comparison screen with a bulk endpoint?", kind: .coding, source: .manual)
        let request = AnswerRequest(question: q, screen: nil, target: nil, recentTurns: [], summary: nil, control: .standard, correctionNote: nil, stamp: GenerationStamp(epoch: 0, questionID: q.id, questionRevision: 1, screenRevision: nil))
        let published = Published()
        let outcome = try await orchestrator.generate(request, sessionID: EntityID(), processingMode: .hybrid, offline: false, isCurrent: { true }, publish: { published.append($0) })
        let s = outcome.suggestion
        #expect(s.completed && s.route == .routineCloud)
        #expect(s.shortAnswer.hasPrefix("I'd stream the input"))
        #expect(s.keyPoints.count == 3)
        #expect(s.keyPoints[2].status == .supported && !s.keyPoints[2].evidenceIDs.isEmpty)   // [E1] resolved against the index
        #expect(s.assumptions.count == 1 && s.missingInformation.count == 2)                  // MISSING + CLARIFY
        #expect(s.optionalDetail?.contains("```python") == true)
        #expect(s.verificationStatus == .supported)
        #expect(published.count >= 2)
        #expect(outcome.run?.outcome == .succeeded)
        #expect(provider.requests.first?.messages.first?.content.contains("SHORT:") == true)
        #expect(provider.requests.first?.messages.last?.content.contains("[E1]") == true)
    }

    @Test func unsupportedPersonalClaimsAreNeverPublishedAsPoints() async throws {
        let answer = "SHORT: Sure.\nPOINT: I led a 12-person team at Acme and cut costs by 30%\nPOINT: Hash sets give O(1) lookups\n"
        let orchestrator = makeOrchestrator(provider: MockProvider(behaviour: .succeed(answer)))
        let q = Question(sessionID: EntityID(), text: "Tell me about leadership", kind: .behavioral, source: .manual)
        let request = AnswerRequest(question: q, screen: nil, target: nil, recentTurns: [], summary: nil, control: .standard, correctionNote: nil, stamp: GenerationStamp(epoch: 0, questionID: q.id, questionRevision: 1, screenRevision: nil))
        let outcome = try await orchestrator.generate(request, sessionID: EntityID(), processingMode: .hybrid, offline: false, isCurrent: { true }, publish: { _ in })
        #expect(outcome.suggestion.keyPoints.count == 1)
        #expect(outcome.suggestion.missingInformation.first?.contains("Confirm before saying this") == true)
        #expect(outcome.suggestion.verificationStatus == .needsConfirmation)
    }

    @Test func staleGenerationIsNotPublished() async throws {
        let orchestrator = makeOrchestrator(provider: MockProvider(behaviour: .succeed(MockProvider.sampleAnswer)))
        let q = Question(sessionID: EntityID(), text: "q", kind: .coding, source: .manual)
        let request = AnswerRequest(question: q, screen: nil, target: nil, recentTurns: [], summary: nil, control: .standard, correctionNote: nil, stamp: GenerationStamp(epoch: 0, questionID: q.id, questionRevision: 1, screenRevision: nil))
        let published = Published()
        _ = try await orchestrator.generate(request, sessionID: EntityID(), processingMode: .hybrid, offline: false, isCurrent: { false }, publish: { published.append($0) })
        #expect(published.count == 0)
    }

    @Test func depthUsesTheStrongModelOnce() async throws {
        let provider = MockProvider(behaviour: .succeed("SHORT: deep\n"))
        let orchestrator = makeOrchestrator(provider: provider)
        let q = Question(sessionID: EntityID(), text: "Design a URL shortener", kind: .systemDesign, source: .manual)
        let request = AnswerRequest(question: q, screen: nil, target: nil, recentTurns: [], summary: nil, control: .depth, correctionNote: nil, stamp: GenerationStamp(epoch: 0, questionID: q.id, questionRevision: 1, screenRevision: nil))
        let outcome = try await orchestrator.generate(request, sessionID: EntityID(), processingMode: .hybrid, offline: false, isCurrent: { true }, publish: { _ in })
        #expect(outcome.routing.route == .strongCloud && provider.requests.last?.model == "strong")
    }

    @Test func budgetExhaustionWithoutFallbackFails() async {
        let orchestrator = makeOrchestrator(provider: MockProvider(behaviour: .succeed("SHORT: x\n")), cap: 0.000_000_1)
        let q = Question(sessionID: EntityID(), text: "q", kind: .coding, source: .manual)
        let request = AnswerRequest(question: q, screen: nil, target: nil, recentTurns: [], summary: nil, control: .standard, correctionNote: nil, stamp: GenerationStamp(epoch: 0, questionID: q.id, questionRevision: 1, screenRevision: nil))
        await #expect(throws: (any Error).self) {
            _ = try await orchestrator.generate(request, sessionID: EntityID(), processingMode: .hybrid, offline: false, isCurrent: { true }, publish: { _ in })
        }
    }
}

final class Published: @unchecked Sendable {
    private let lock = NSLock(); private var items: [Suggestion] = []
    func append(_ s: Suggestion) { lock.lock(); items.append(s); lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return items.count }
}

@Suite("Session coordinator")
@MainActor
struct CoordinatorTests {
    func makeCoordinator(provider: MockProvider, autoAnswer: Bool = true) throws -> SessionCoordinator {
        let store = try AppStore.inMemory()
        let index = EvidenceIndex(useEmbeddings: false)
        let prices = PriceRegistry(version: "t", entries: [ModelPrice(provider: "mock", model: "routine", inputPerMillion: 0.1, outputPerMillion: 0.5, verifiedOn: "t")])
        let executor = ReasoningExecutor(ledger: BudgetLedger(capUSD: 1), prices: prices, telemetry: InMemoryTelemetry())
        var config = ReasoningConfiguration(providerID: "mock", baseURL: "x", routineModel: "routine", strongModel: "routine"); config.onDeviceEnabled = false
        let answers = AnswerOrchestrator(index: index, executor: executor, cloud: provider, onDevice: nil, configuration: config, telemetry: InMemoryTelemetry())
        let setup = SessionSetup(target: nil, mode: .live, scope: AssistanceScope(captions: false, screenAnalysis: false, answerDrafting: true, permittedByUser: true), processingMode: .hybrid, audioSource: nil, windowID: nil, autoAnswer: autoAnswer)
        return SessionCoordinator(setup: setup, store: store, telemetry: InMemoryTelemetry(), answers: answers, detector: QuestionDetector(onDevice: nil, telemetry: InMemoryTelemetry()), pricePolicyVersion: "t", deviceClass: "test")
    }

    @Test func manualAskProducesASuggestionAndStopOpensSaveWindow() async throws {
        let c = try makeCoordinator(provider: MockProvider(behaviour: .succeed(MockProvider.sampleAnswer)))
        await c.start()
        #expect(c.status.phase == .listening)
        c.ask(manualText: "How would you detect duplicates in a stream?")
        #expect(c.activeQuestion?.kind == .coding)
        for _ in 0..<100 where c.status.phase != .answerReady { try await Task.sleep(nanoseconds: 50_000_000) }
        #expect(c.status.phase == .answerReady)
        // The sample answer's third point is a personal experience claim; with no approved evidence it must
        // become a "confirm before saying this" item instead of a displayed point.
        #expect(c.suggestion?.completed == true && c.suggestion?.keyPoints.count == 2)
        #expect(c.suggestion?.missingInformation.contains { $0.hasPrefix("Confirm before saying this") } == true)
        #expect(c.usage.settledUSD > 0)
        c.stop()
        #expect(c.status.phase == .stopped && c.pendingSave != nil)
        c.save()
        #expect(c.pendingSave == nil)
        #expect(try c.store.sessions().count == 1)
        #expect(try c.store.suggestions(sessionID: c.session.id).count == 1)
    }

    @Test func newQuestionSupersedesRunningGeneration() async throws {
        let provider = MockProvider(behaviour: .succeed(MockProvider.sampleAnswer), chunkDelayNanoseconds: 40_000_000)
        let c = try makeCoordinator(provider: provider)
        await c.start()
        c.ask(manualText: "First question about hashing?")
        for _ in 0..<100 where c.suggestion == nil { try await Task.sleep(nanoseconds: 30_000_000) }
        #expect(c.status.phase == .generating)
        let first = c.activeQuestion?.id
        c.ask(manualText: "Second question about system design of a URL shortener?")
        #expect(c.activeQuestion?.id != first)
        #expect(c.questions.first { $0.id == first }?.status == .superseded)
        for _ in 0..<200 where c.status.phase != .answerReady { try await Task.sleep(nanoseconds: 50_000_000) }
        #expect(c.suggestion?.questionID == c.activeQuestion?.id)
        #expect(c.events.contains { $0.type == .answerInvalidated })
    }

    @Test func scopeWithoutDraftingNeverGenerates() async throws {
        let store = try AppStore.inMemory()
        let provider = MockProvider(behaviour: .succeed("SHORT: x\n"))
        let executor = ReasoningExecutor(ledger: BudgetLedger(capUSD: 1), prices: .builtIn, telemetry: InMemoryTelemetry())
        let answers = AnswerOrchestrator(index: EvidenceIndex(useEmbeddings: false), executor: executor, cloud: provider, onDevice: nil, configuration: ReasoningConfiguration(), telemetry: InMemoryTelemetry())
        let setup = SessionSetup(target: nil, mode: .live, scope: AssistanceScope(captions: false, screenAnalysis: false, answerDrafting: true, permittedByUser: false, prohibitedByInterview: true), processingMode: .hybrid, audioSource: nil, windowID: nil)
        let c = SessionCoordinator(setup: setup, store: store, telemetry: InMemoryTelemetry(), answers: answers, detector: QuestionDetector(onDevice: nil, telemetry: InMemoryTelemetry()), pricePolicyVersion: "t", deviceClass: "test")
        await c.start()
        c.ask(manualText: "Any question?")
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(provider.attemptCount == 0 && c.suggestion == nil)
    }
}
