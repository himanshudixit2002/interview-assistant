import Foundation
import FoundationModels
import InterviewCore

/// Apple Intelligence on-device model behind the common provider interface. Free, private, small context;
/// used for question classification, summaries and structure, and as the labeled fallback route.
public final class OnDeviceProvider: ReasoningProvider, @unchecked Sendable {
    public let id = "ondevice"
    public let displayName = "On-device (Apple Intelligence)"
    public let isLocal = true
    public static let model = "apple-foundation"
    private let lock = NSLock()
    private var inflight: [EntityID: Task<Void, Never>] = [:]

    public init() {}

    public struct Availability: Sendable, Equatable {
        public let available: Bool
        public let reason: String
    }

    public static func availability() -> Availability {
        switch SystemLanguageModel.default.availability {
        case .available: return Availability(available: true, reason: "available")
        case .unavailable(let reason):
            switch reason {
            case .appleIntelligenceNotEnabled: return Availability(available: false, reason: "Apple Intelligence is turned off in System Settings")
            case .deviceNotEligible: return Availability(available: false, reason: "this Mac is not eligible for Apple Intelligence")
            case .modelNotReady: return Availability(available: false, reason: "the on-device model is still downloading")
            @unknown default: return Availability(available: false, reason: "unavailable")
            }
        }
    }

    /// Loads the model so the first real call does not pay the ~2.5 s cold start measured in Phase 0.
    public func prewarm() {
        let session = LanguageModelSession(model: .default, instructions: "Reply with one word.")
        session.prewarm()
    }

    public func stream(_ request: ReasoningRequest) -> AsyncThrowingStream<ReasoningEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let instructions = request.messages.filter { $0.role == .system }.map(\.content).joined(separator: "\n\n")
                    let prompt = request.messages.filter { $0.role != .system }.map { "\($0.role == .user ? "" : "Assistant: ")\($0.content)" }.joined(separator: "\n\n")
                    let session = LanguageModelSession(model: .default, instructions: instructions.isEmpty ? nil : instructions)
                    let options = GenerationOptions(temperature: request.temperature, maximumResponseTokens: request.maxOutputTokens)
                    var emitted = ""
                    for try await snapshot in session.streamResponse(to: prompt, options: options) {
                        try Task.checkCancellation()
                        let content = snapshot.content
                        if content.hasPrefix(emitted) {
                            let delta = String(content.dropFirst(emitted.count))
                            if !delta.isEmpty { continuation.yield(.delta(delta)) }
                        } else {
                            continuation.yield(.delta(content))
                        }
                        emitted = content
                    }
                    continuation.yield(.usage(input: request.estimatedInputTokens, cachedInput: 0, output: TokenEstimator.estimate(emitted)))
                    continuation.yield(.finished(reason: "stop"))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: AssistantError.cancelled)
                } catch {
                    let text = "\(error)"
                    if text.contains("exceededContextWindowSize") || text.contains("context") {
                        continuation.finish(throwing: AssistantError.badInput("prompt exceeds the on-device context window"))
                    } else if text.contains("guardrail") || text.contains("unsafe") {
                        continuation.finish(throwing: AssistantError.unsupportedCapability("on-device model declined this content"))
                    } else {
                        continuation.finish(throwing: AssistantError.providerUnavailable("on-device model: \(text.prefix(120))"))
                    }
                }
                self.lock.lock(); self.inflight[request.id] = nil; self.lock.unlock()
            }
            lock.lock(); inflight[request.id] = task; lock.unlock()
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func cancel(requestID: EntityID) async {
        lock.lock(); let task = inflight[requestID]; lock.unlock()
        task?.cancel()
    }
}
