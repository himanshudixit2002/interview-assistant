import Foundation
import InterviewCore

/// Runs one reasoning request under budget control (§9.5, §11.3, §16.6): reserve, call with one bounded retry,
/// settle against reported usage, record a content-free `ModelRun`, and feed the circuit breaker.
public final class ReasoningExecutor: @unchecked Sendable {
    public let ledger: BudgetLedger
    public let prices: PriceRegistry
    public let breaker: CircuitBreaker
    public let telemetry: TelemetrySink
    public var maxAttempts = 2

    public init(ledger: BudgetLedger, prices: PriceRegistry = .builtIn, breaker: CircuitBreaker = CircuitBreaker(), telemetry: TelemetrySink) {
        self.ledger = ledger; self.prices = prices; self.breaker = breaker; self.telemetry = telemetry
    }

    public func estimateUSD(request: ReasoningRequest, provider: ReasoningProvider) -> Double {
        guard !provider.isLocal, let price = prices.price(provider: provider.id, model: request.model) else { return 0 }
        return CostMath.cost(inputTokens: request.estimatedInputTokens, outputTokens: request.maxOutputTokens, price: price)
    }

    /// Streams deltas to `onEvent` and returns the completed run record. Throws `AssistantError`.
    public func execute(_ request: ReasoningRequest, provider: ReasoningProvider, route: RouteKind, sessionID: EntityID?, onEvent: @escaping @Sendable (ReasoningEvent) -> Void) async throws -> ModelRun {
        let price = prices.price(provider: provider.id, model: request.model)
        let estimate = estimateUSD(request: request, provider: provider)
        var run = ModelRun(sessionID: sessionID, provider: provider.id, model: request.model, route: route, requestHash: request.requestHash, priceVersion: prices.version)
        let token: ReservationToken? = provider.isLocal ? nil : try await ledger.reserve(estimateUSD: estimate, sessionID: sessionID, runID: run.id, reason: route.rawValue, idempotencyKey: request.id.raw)

        let started = DispatchTime.now()
        func elapsedMs() -> Double { Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000 }
        var usage: (input: Int, cached: Int, output: Int)? = nil
        var lastError: Error? = nil
        var attempt = 0

        while attempt < maxAttempts {
            attempt += 1
            do {
                var sawFirstToken = false
                for try await event in provider.stream(request) {
                    switch event {
                    case .delta:
                        if !sawFirstToken { sawFirstToken = true; run.firstTokenMs = elapsedMs() }
                    case .usage(let i, let c, let o): usage = (i, c, o)
                    case .finished: break
                    }
                    onEvent(event)
                }
                lastError = nil
                break
            } catch {
                lastError = error
                let assistantError = error as? AssistantError
                let remaining = request.deadline * 1000 - elapsedMs()
                let retryable = (assistantError?.isRetryable ?? false) && usage == nil && remaining > 2_000 && attempt < maxAttempts
                telemetry.record(TelemetryEvent(name: "reasoning.attempt_failed", category: "reasoning", durationMs: elapsedMs(), attributes: ["provider": provider.id, "route": route.rawValue, "code": assistantError?.code ?? "unknown", "retry": retryable ? "yes" : "no"]))
                if !retryable { break }
                if case .providerRateLimited(let after)? = assistantError, let after, after < remaining / 1000 { try? await Task.sleep(nanoseconds: UInt64(after * 1_000_000_000)) }
                else { try? await Task.sleep(nanoseconds: UInt64(0.4 * Double.random(in: 0.8...1.2) * 1_000_000_000)) }
            }
        }

        run.totalMs = elapsedMs()
        if let usage {
            run.inputTokens = usage.input; run.cachedInputTokens = usage.cached; run.outputTokens = usage.output
            if let price { run.estimatedCostUSD = CostMath.cost(inputTokens: usage.input, cachedInputTokens: usage.cached, outputTokens: usage.output, price: price) }
        }
        if let error = lastError {
            run.outcome = classify(error)
            if let token { if usage != nil { await ledger.settle(token, actualUSD: run.estimatedCostUSD, route: route) } else { await ledger.release(token) } }
            if run.outcome != .cancelled { await breaker.recordFailure(provider.id) }
            telemetry.record(TelemetryEvent(name: "reasoning.failed", category: "reasoning", durationMs: run.totalMs, attributes: ["provider": provider.id, "route": route.rawValue, "outcome": run.outcome.rawValue]))
            throw error
        }
        run.outcome = .succeeded
        if let token { await ledger.settle(token, actualUSD: run.estimatedCostUSD, route: route) }
        await breaker.recordSuccess(provider.id)
        telemetry.record(TelemetryEvent(name: "reasoning.succeeded", category: "reasoning", durationMs: run.totalMs, attributes: ["provider": provider.id, "route": route.rawValue, "first_token_ms": run.firstTokenMs.map { String(Int($0)) } ?? "-", "input_tokens": String(run.inputTokens), "output_tokens": String(run.outputTokens), "attempts": String(attempt)]))
        return run
    }

    private func classify(_ error: Error) -> RunOutcome {
        switch error as? AssistantError {
        case .cancelled?: return .cancelled
        case .providerTimeout?: return .timedOut
        case .providerRateLimited?: return .rateLimited
        case .insufficientQuota?: return .budgetRefused
        default: return .failed
        }
    }
}
