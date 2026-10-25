import Foundation

public enum SessionEventType: String, Codable, Sendable {
    case transcriptPartial, transcriptFinal, transcriptCorrection, transcriptGap
    case sourceChanged, screenUpdated
    case questionCreated, questionUpdated, questionSuperseded
    case answerBlock, answerCompleted, answerInvalidated
    case usageUpdated, degradationChanged, stateChanged, error
}

public enum SessionEventPayload: Codable, Sendable, Equatable {
    case transcript(TranscriptSegment)
    case correction(old: TranscriptSegment, new: TranscriptSegment)
    case source(id: String, reason: String)
    case screen(ScreenEvidence)
    case question(Question)
    case block(suggestionID: EntityID, block: AnswerBlock)
    case suggestion(Suggestion)
    case invalidated(suggestionID: EntityID, reason: String)
    case usage(UsageSnapshot)
    case degradation(Degradation, active: Bool)
    case status(SessionStatus)
    case failure(code: String, message: String, recovery: String)
}

/// Stream event envelope (plan §11.2). Delivery is at-least-once; consumers deduplicate by `seq`.
public struct SessionEvent: Codable, Sendable, Equatable {
    public var protocolVersion: Int
    public var sessionID: EntityID
    public var requestID: EntityID?
    public var seq: Int
    public var type: SessionEventType
    public var time: Date
    public var epoch: Int
    public var questionRevision: Int?
    public var payload: SessionEventPayload
    public init(sessionID: EntityID, requestID: EntityID? = nil, seq: Int, type: SessionEventType, time: Date = Date(), epoch: Int, questionRevision: Int? = nil, payload: SessionEventPayload) {
        self.protocolVersion = ProtocolVersion.current; self.sessionID = sessionID; self.requestID = requestID; self.seq = seq; self.type = type
        self.time = time; self.epoch = epoch; self.questionRevision = questionRevision; self.payload = payload
    }
}

/// Error taxonomy with a user recovery action (plan §11.3). Never carries credentials or raw traces.
public enum AssistantError: Error, CustomStringConvertible, Sendable {
    case permissionDenied(String)
    case sourceLost(String)
    case unsupportedCapability(String)
    case badInput(String)
    case insufficientQuota
    case providerRateLimited(retryAfter: TimeInterval?)
    case providerTimeout
    case providerUnavailable(String)
    case transientNetwork
    case cancelled
    case internalFailure(String)

    public var code: String {
        switch self {
        case .permissionDenied: return "permission_denied"
        case .sourceLost: return "source_lost"
        case .unsupportedCapability: return "unsupported"
        case .badInput: return "bad_input"
        case .insufficientQuota: return "insufficient_quota"
        case .providerRateLimited: return "rate_limited"
        case .providerTimeout: return "provider_timeout"
        case .providerUnavailable: return "provider_unavailable"
        case .transientNetwork: return "network"
        case .cancelled: return "cancelled"
        case .internalFailure: return "internal"
        }
    }

    public var recovery: String {
        switch self {
        case .permissionDenied(let what): return "Grant \(what) access in System Settings › Privacy & Security, then press Start again."
        case .sourceLost: return "Select the window or audio source again."
        case .unsupportedCapability(let what): return "\(what) is not available on this Mac. Local notes and captions continue."
        case .badInput: return "Check the input and try again."
        case .insufficientQuota: return "Cloud allowance is used up. Raise the session cap in Settings or continue with local notes."
        case .providerRateLimited: return "The provider is rate limiting. Retry in a moment or switch provider in Settings."
        case .providerTimeout: return "The provider did not answer in time. Try again or use the local route."
        case .providerUnavailable: return "The provider is unavailable. Local captions and notes continue."
        case .transientNetwork: return "Check the network connection. Saved notes stay available."
        case .cancelled: return ""
        case .internalFailure: return "Restart the session. If it repeats, export diagnostics from Settings."
        }
    }

    public var description: String {
        switch self {
        case .permissionDenied(let w): return "Permission denied: \(w)"
        case .sourceLost(let w): return "Source lost: \(w)"
        case .unsupportedCapability(let w): return "Unsupported: \(w)"
        case .badInput(let w): return "Bad input: \(w)"
        case .insufficientQuota: return "Insufficient quota"
        case .providerRateLimited(let r): return "Rate limited\(r.map { " (retry after \(Int($0)) s)" } ?? "")"
        case .providerTimeout: return "Provider timeout"
        case .providerUnavailable(let w): return "Provider unavailable: \(w)"
        case .transientNetwork: return "Network failure"
        case .cancelled: return "Cancelled"
        case .internalFailure(let w): return "Internal failure: \(w)"
        }
    }

    public var isRetryable: Bool {
        switch self {
        case .providerTimeout, .transientNetwork, .providerRateLimited: return true
        default: return false
        }
    }
}
