import Foundation
import InterviewCore

/// Streaming client for any OpenAI-compatible `/chat/completions` endpoint (DeepSeek, Qwen, Kimi, GLM, MiniMax…).
/// The API key is read through a closure so it never sits in a long-lived property.
public final class OpenAICompatibleProvider: ReasoningProvider, @unchecked Sendable {
    public let id: String
    public let displayName: String
    public let isLocal = false
    private let baseURL: URL
    private let apiKey: @Sendable () -> String?
    private let supportsStreamUsage: Bool
    private let maxTemperature: Double
    private let session: URLSession
    private let lock = NSLock()
    private var inflight: [EntityID: Task<Void, Never>] = [:]

    public init(preset: ProviderPreset, baseURL: String? = nil, apiKey: @escaping @Sendable () -> String?, session: URLSession = .shared) {
        self.id = preset.id
        self.displayName = preset.displayName
        self.baseURL = URL(string: (baseURL ?? preset.baseURL).trimmingCharacters(in: CharacterSet(charactersIn: "/"))) ?? URL(string: "https://invalid.local")!
        self.apiKey = apiKey
        self.supportsStreamUsage = preset.supportsStreamUsage
        self.maxTemperature = preset.maxTemperature
        self.session = session
    }

    public func stream(_ request: ReasoningRequest) -> AsyncThrowingStream<ReasoningEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.run(request, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
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

    private func run(_ request: ReasoningRequest, continuation: AsyncThrowingStream<ReasoningEvent, Error>.Continuation) async throws {
        guard let key = apiKey(), !key.isEmpty else { throw AssistantError.badInput("no API key configured for \(displayName)") }
        var body: [String: Any] = [
            "model": request.model,
            "messages": request.messages.map { ["role": $0.role.rawValue, "content": $0.content] },
            "stream": true,
            "max_tokens": request.maxOutputTokens,
            "temperature": min(max(request.temperature, 0.01), maxTemperature),
        ]
        if supportsStreamUsage { body["stream_options"] = ["include_usage": true] }
        if request.jsonMode { body["response_format"] = ["type": "json_object"] }

        var urlRequest = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        urlRequest.timeoutInterval = request.deadline

        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            (bytes, response) = try await session.bytes(for: urlRequest)
        } catch let urlError as URLError {
            switch urlError.code {
            case .timedOut: throw AssistantError.providerTimeout
            case .cancelled: throw AssistantError.cancelled
            default: throw AssistantError.transientNetwork
            }
        }
        guard let http = response as? HTTPURLResponse else { throw AssistantError.providerUnavailable("no HTTP response") }
        switch http.statusCode {
        case 200: break
        case 401, 403: throw AssistantError.badInput("API key rejected by \(displayName)")
        case 429:
            let retry = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
            throw AssistantError.providerRateLimited(retryAfter: retry)
        case 400...499:
            var detail = ""
            for try await line in bytes.lines { detail += line; if detail.count > 400 { break } }
            throw AssistantError.badInput("provider rejected request (\(http.statusCode)): \(detail.prefix(200))")
        default: throw AssistantError.providerUnavailable("HTTP \(http.statusCode)")
        }

        var reportedUsage = false
        var outputChars = 0
        var inputEstimate = request.estimatedInputTokens
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard let chunk = SSEParser.parse(line: line) else { continue }
            if let delta = chunk.contentDelta { outputChars += delta.count; continuation.yield(.delta(delta)) }
            if let reasoning = chunk.reasoningDelta { outputChars += reasoning.count }   // billed as output, not shown
            if let prompt = chunk.promptTokens, let completion = chunk.completionTokens {
                reportedUsage = true
                inputEstimate = prompt
                continuation.yield(.usage(input: prompt, cachedInput: chunk.cachedPromptTokens ?? 0, output: completion))
            }
            if let reason = chunk.finishReason, reason.hasPrefix("error:") { throw AssistantError.providerUnavailable(reason) }
            if chunk.isDone { break }
        }
        if !reportedUsage {
            continuation.yield(.usage(input: inputEstimate, cachedInput: 0, output: max(1, outputChars / 4)))
        }
        continuation.yield(.finished(reason: "stop"))
    }
}
