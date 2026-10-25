import Foundation
import InterviewCore

/// Scripted provider for tests and the no-key demo mode. Streams a canned answer in the block protocol.
public final class MockProvider: ReasoningProvider, @unchecked Sendable {
    public enum Behaviour: Sendable { case succeed(String), failTransientThenSucceed(String), rateLimited, timeout, unauthorized }
    public let id: String
    public let displayName: String
    public let isLocal: Bool
    public var behaviour: Behaviour
    public let chunkDelayNanoseconds: UInt64
    private let lock = NSLock()
    private var attempts = 0
    public private(set) var requests: [ReasoningRequest] = []

    public init(id: String = "mock", displayName: String = "Mock", isLocal: Bool = false, behaviour: Behaviour, chunkDelayNanoseconds: UInt64 = 0) {
        self.id = id; self.displayName = displayName; self.isLocal = isLocal; self.behaviour = behaviour; self.chunkDelayNanoseconds = chunkDelayNanoseconds
    }

    public var attemptCount: Int { lock.lock(); defer { lock.unlock() }; return attempts }

    public static let sampleAnswer = """
    SHORT: I'd stream the input through a hash set and report each value the second time I see it.
    POINT: One pass with O(n) time; memory is the real constraint, so I'd confirm the limit first.
    POINT: If memory is tight, a Bloom filter trades exact answers for a fixed footprint.
    POINT: I did something similar when I collapsed request fan-out into a single bulk endpoint [E1]
    ASSUME: Values fit in 32-bit integers.
    MISSING: Whether the input may be modified in place.
    CLARIFY: Can I sort the input in place, or must it stay unchanged?
    DETAIL: Sketch:
    ```python
    seen = set()
    for n in nums:
        if n in seen: yield n
        seen.add(n)
    ```
    """

    public func stream(_ request: ReasoningRequest) -> AsyncThrowingStream<ReasoningEvent, Error> {
        lock.lock(); requests.append(request); attempts += 1; let attempt = attempts; lock.unlock()
        let behaviour = self.behaviour
        let delay = chunkDelayNanoseconds
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    let text: String
                    switch behaviour {
                    case .succeed(let t): text = t
                    case .failTransientThenSucceed(let t):
                        if attempt == 1 { throw AssistantError.transientNetwork }
                        text = t
                    case .rateLimited: throw AssistantError.providerRateLimited(retryAfter: 1)
                    case .timeout: throw AssistantError.providerTimeout
                    case .unauthorized: throw AssistantError.badInput("API key rejected")
                    }
                    for piece in text.split(separator: " ", omittingEmptySubsequences: false) {
                        try Task.checkCancellation()
                        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
                        continuation.yield(.delta(String(piece) + " "))
                    }
                    continuation.yield(.usage(input: request.estimatedInputTokens, cachedInput: 0, output: TokenEstimator.estimate(text)))
                    continuation.yield(.finished(reason: "stop"))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    public func cancel(requestID: EntityID) async {}
}
