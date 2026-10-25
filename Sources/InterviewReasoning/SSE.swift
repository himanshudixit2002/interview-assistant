import Foundation

/// Server-sent event chunk from an OpenAI-compatible streaming chat completion.
public struct StreamChunk: Equatable, Sendable {
    public var contentDelta: String?
    public var reasoningDelta: String?
    public var finishReason: String?
    public var promptTokens: Int?
    public var cachedPromptTokens: Int?
    public var completionTokens: Int?
    public var isDone: Bool
    public init(contentDelta: String? = nil, reasoningDelta: String? = nil, finishReason: String? = nil, promptTokens: Int? = nil, cachedPromptTokens: Int? = nil, completionTokens: Int? = nil, isDone: Bool = false) {
        self.contentDelta = contentDelta; self.reasoningDelta = reasoningDelta; self.finishReason = finishReason; self.promptTokens = promptTokens
        self.cachedPromptTokens = cachedPromptTokens; self.completionTokens = completionTokens; self.isDone = isDone
    }
}

public enum SSEParser {
    /// Parses one `data:` line. Returns nil for keep-alives, comments and empty lines.
    public static func parse(line: String) -> StreamChunk? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("data:") else { return nil }
        let payload = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" { return StreamChunk(isDone: true) }
        guard let data = payload.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var chunk = StreamChunk()
        if let choices = object["choices"] as? [[String: Any]], let first = choices.first {
            if let delta = first["delta"] as? [String: Any] {
                if let c = delta["content"] as? String, !c.isEmpty { chunk.contentDelta = c }
                if let r = delta["reasoning_content"] as? String, !r.isEmpty { chunk.reasoningDelta = r }
            }
            if let reason = first["finish_reason"] as? String { chunk.finishReason = reason }
        }
        if let usage = object["usage"] as? [String: Any] {
            chunk.promptTokens = usage["prompt_tokens"] as? Int
            chunk.completionTokens = usage["completion_tokens"] as? Int
            if let hit = usage["prompt_cache_hit_tokens"] as? Int { chunk.cachedPromptTokens = hit }
            else if let details = usage["prompt_tokens_details"] as? [String: Any], let cached = details["cached_tokens"] as? Int { chunk.cachedPromptTokens = cached }
        }
        if let error = object["error"] as? [String: Any], let message = error["message"] as? String {
            chunk.finishReason = "error: \(message)"
        }
        return chunk
    }
}
