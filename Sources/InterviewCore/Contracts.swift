import Foundation

public enum ChatRole: String, Codable, Sendable { case system, user, assistant }

public struct ChatMessage: Codable, Sendable, Equatable {
    public var role: ChatRole
    public var content: String
    public init(role: ChatRole, content: String) { self.role = role; self.content = content }
}

public struct ReasoningRequest: Sendable {
    public var id: EntityID
    public var model: String
    public var messages: [ChatMessage]
    public var maxOutputTokens: Int
    public var temperature: Double
    public var deadline: TimeInterval
    public var jsonMode: Bool
    public init(id: EntityID = EntityID(), model: String, messages: [ChatMessage], maxOutputTokens: Int = 700, temperature: Double = 0.3, deadline: TimeInterval = 20, jsonMode: Bool = false) {
        self.id = id; self.model = model; self.messages = messages; self.maxOutputTokens = maxOutputTokens; self.temperature = temperature; self.deadline = deadline; self.jsonMode = jsonMode
    }
    public var requestHash: String { TextHash.sha256(model + "\n" + messages.map { "\($0.role.rawValue):\($0.content)" }.joined(separator: "\n")) }
    public var estimatedInputTokens: Int { messages.reduce(0) { $0 + TokenEstimator.estimate($1.content) } + 8 * messages.count }
}

public enum ReasoningEvent: Sendable, Equatable {
    case delta(String)
    case usage(input: Int, cachedInput: Int, output: Int)
    case finished(reason: String)
}

/// Every reasoning route, cloud or on-device, speaks this interface so routing, budgets and cancellation are uniform.
public protocol ReasoningProvider: AnyObject, Sendable {
    var id: String { get }
    var displayName: String { get }
    var isLocal: Bool { get }
    func stream(_ request: ReasoningRequest) -> AsyncThrowingStream<ReasoningEvent, Error>
    func cancel(requestID: EntityID) async
}

public struct EvidenceHit: Sendable, Equatable {
    public var ref: EvidenceRef
    public var score: Double
    public init(ref: EvidenceRef, score: Double) { self.ref = ref; self.score = score }
}
