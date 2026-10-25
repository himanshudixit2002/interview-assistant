import Testing
import Foundation
@testable import InterviewReasoning
import InterviewCore

@Suite("SSE parsing")
struct SSETests {
    @Test func parsesDeltaUsageAndDone() {
        let delta = SSEParser.parse(line: #"data: {"choices":[{"delta":{"content":"Hel"},"finish_reason":null}]}"#)
        #expect(delta?.contentDelta == "Hel")
        let usage = SSEParser.parse(line: #"data: {"choices":[],"usage":{"prompt_tokens":120,"completion_tokens":40,"prompt_cache_hit_tokens":100}}"#)
        #expect(usage?.promptTokens == 120 && usage?.completionTokens == 40 && usage?.cachedPromptTokens == 100)
        let openAIStyle = SSEParser.parse(line: #"data: {"choices":[],"usage":{"prompt_tokens":10,"completion_tokens":2,"prompt_tokens_details":{"cached_tokens":4}}}"#)
        #expect(openAIStyle?.cachedPromptTokens == 4)
        #expect(SSEParser.parse(line: "data: [DONE]")?.isDone == true)
        #expect(SSEParser.parse(line: ": keep-alive") == nil)
        #expect(SSEParser.parse(line: "") == nil)
        let reasoning = SSEParser.parse(line: #"data: {"choices":[{"delta":{"reasoning_content":"thinking"}}]}"#)
        #expect(reasoning?.reasoningDelta == "thinking" && reasoning?.contentDelta == nil)
    }
}

@Suite("Executor and budget")
struct ExecutorTests {
    func makeExecutor(cap: Double = 1.0) -> ReasoningExecutor {
        let prices = PriceRegistry(version: "t", entries: [ModelPrice(provider: "mock", model: "m", inputPerMillion: 1.0, outputPerMillion: 10.0, verifiedOn: "t")])
        return ReasoningExecutor(ledger: BudgetLedger(capUSD: cap), prices: prices, telemetry: InMemoryTelemetry())
    }

    @Test func streamsReservesAndSettles() async throws {
        let executor = makeExecutor()
        let provider = MockProvider(behaviour: .succeed(MockProvider.sampleAnswer))
        var text = ""
        let request = ReasoningRequest(model: "m", messages: [ChatMessage(role: .user, content: "q")], maxOutputTokens: 300)
        let collector = Collector()
        let run = try await executor.execute(request, provider: provider, route: .routineCloud, sessionID: nil) { event in
            if case .delta(let d) = event { collector.append(d) }
        }
        text = collector.text
        #expect(text.contains("SHORT:") && text.contains("DETAIL:"))
        #expect(run.outcome == .succeeded && run.firstTokenMs != nil && run.outputTokens > 0)
        let snap = await executor.ledger.snapshot()
        #expect(snap.reservedUSD == 0 && snap.settledUSD > 0 && snap.routineTurnsUsed == 1)
    }

    @Test func retriesOnceOnTransientFailure() async throws {
        let executor = makeExecutor()
        let provider = MockProvider(behaviour: .failTransientThenSucceed("SHORT: ok\n"))
        let run = try await executor.execute(ReasoningRequest(model: "m", messages: [ChatMessage(role: .user, content: "q")]), provider: provider, route: .routineCloud, sessionID: nil) { _ in }
        #expect(provider.attemptCount == 2 && run.outcome == .succeeded)
    }

    @Test func refusesWhenBudgetCannotCoverTheEstimate() async {
        let executor = makeExecutor(cap: 0.000_001)
        let provider = MockProvider(behaviour: .succeed("SHORT: ok\n"))
        await #expect(throws: (any Error).self) {
            try await executor.execute(ReasoningRequest(model: "m", messages: [ChatMessage(role: .user, content: "q")], maxOutputTokens: 500), provider: provider, route: .routineCloud, sessionID: nil) { _ in }
        }
        #expect(provider.attemptCount == 0)
    }

    @Test func rateLimitWithoutUsageReleasesReservationAndFailsRun() async {
        let executor = makeExecutor()
        executor.maxAttempts = 1
        let provider = MockProvider(behaviour: .rateLimited)
        await #expect(throws: (any Error).self) {
            try await executor.execute(ReasoningRequest(model: "m", messages: [ChatMessage(role: .user, content: "q")]), provider: provider, route: .routineCloud, sessionID: nil) { _ in }
        }
        let snap = await executor.ledger.snapshot()
        #expect(snap.reservedUSD == 0 && snap.settledUSD == 0)
    }

    @Test func circuitOpensAfterRepeatedFailures() async {
        let breaker = CircuitBreaker(threshold: 2, coolDown: 60)
        await breaker.recordFailure("p"); #expect(await !breaker.isOpen("p"))
        await breaker.recordFailure("p"); #expect(await breaker.isOpen("p"))
        await breaker.recordSuccess("p"); #expect(await !breaker.isOpen("p"))
    }
}

final class Collector: @unchecked Sendable {
    private let lock = NSLock(); private var parts: [String] = []
    func append(_ s: String) { lock.lock(); parts.append(s); lock.unlock() }
    var text: String { lock.lock(); defer { lock.unlock() }; return parts.joined() }
}

@Suite("Router")
struct RouterTests {
    func input(mode: ProcessingMode = .hybrid, depth: Bool = false, cloud: Bool = true, open: Bool = false, onDevice: Bool = true, exhausted: Bool = false, strong: Int = 4, offline: Bool = false) -> RoutingInput {
        RoutingInput(questionKind: .coding, processingMode: mode, depthRequested: depth, cloudConfigured: cloud, cloudCircuitOpen: open, onDeviceAvailable: onDevice, budgetExhausted: exhausted, strongTurnsRemaining: strong, offline: offline)
    }

    @Test func decisions() {
        #expect(ProviderRouter.decide(input()).route == .routineCloud)
        #expect(ProviderRouter.decide(input(depth: true)).route == .strongCloud)
        #expect(ProviderRouter.decide(input(depth: true, strong: 0)) == RoutingDecision(route: .routineCloud, reason: "strong allowance used up; routine route labeled as standard", degraded: true))
        #expect(ProviderRouter.decide(input(mode: .localOnly)).route == .onDevice)
        #expect(ProviderRouter.decide(input(mode: .localOnly, onDevice: false)).route == .none)
        #expect(ProviderRouter.decide(input(exhausted: true)).route == .onDevice)
        #expect(ProviderRouter.decide(input(exhausted: true)).degraded)
        #expect(ProviderRouter.decide(input(cloud: false, onDevice: false)).route == .none)
        #expect(ProviderRouter.decide(input(offline: true)).route == .onDevice)
        #expect(ProviderRouter.decide(input(open: true)).route == .onDevice)
    }

    @Test func presetsHaveDistinctIDsAndPrices() {
        let ids = ProviderPresets.all.map(\.id)
        #expect(Set(ids).count == ids.count)
        for preset in ProviderPresets.all where preset.id != "custom" {
            #expect(PriceRegistry.builtIn.price(provider: preset.id, model: preset.routineModel) != nil, "missing price for \(preset.id)/\(preset.routineModel)")
        }
    }
}
