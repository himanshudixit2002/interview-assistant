import Foundation

public enum SessionPhase: String, Codable, Sendable, CaseIterable {
    case idle, preparing, ready, listening, questionDetected, generating, answerReady, paused, stopped
}

public enum Blocker: String, Codable, Sendable, CaseIterable {
    case permissionRequired, sourceUnavailable, downloadingAssets
}

public enum Degradation: String, Codable, Sendable, CaseIterable {
    case offline, providerDown, localFallback, reconnecting, budgetLow, budgetExhausted, thermal, memoryPressure
}

public enum SessionAction: String, Codable, Sendable, CaseIterable {
    case start, pause, resume, stop, ask, correctQuestion, pinAnswer, recapture, selectSource, retryProvider, saveOrDiscard
}

/// Phase plus blockers and degradations. The plan's §5.5 UI states are derived, never stored separately,
/// so the panel, the screen-reader announcement and the allowed actions cannot disagree.
public struct SessionStatus: Codable, Sendable, Equatable {
    public var phase: SessionPhase
    public var blockers: Set<Blocker>
    public var degradations: Set<Degradation>

    public init(phase: SessionPhase = .idle, blockers: Set<Blocker> = [], degradations: Set<Degradation> = []) {
        self.phase = phase; self.blockers = blockers; self.degradations = degradations
    }

    public var isCapturing: Bool { [.listening, .questionDetected, .generating, .answerReady].contains(phase) }

    public var canGenerate: Bool {
        isCapturing && !blockers.contains(.sourceUnavailable) && !degradations.contains(.budgetExhausted)
    }

    /// One of: idle, downloading, permission-required, source-unavailable, ready, listening, question-detected,
    /// generating, answer-ready, paused, reconnecting, local-fallback, budget-low, budget-exhausted, stopped.
    public var uiState: String {
        if blockers.contains(.downloadingAssets) { return "downloading" }
        if blockers.contains(.permissionRequired) { return "permission-required" }
        if blockers.contains(.sourceUnavailable) && phase != .idle && phase != .stopped { return "source-unavailable" }
        if degradations.contains(.budgetExhausted) && isCapturing { return "budget-exhausted" }
        if degradations.contains(.reconnecting) && isCapturing { return "reconnecting" }
        switch phase {
        case .idle: return "idle"
        case .preparing: return "downloading"
        case .ready: return "ready"
        case .listening:
            if degradations.contains(.localFallback) { return "local-fallback" }
            if degradations.contains(.budgetLow) { return "budget-low" }
            return "listening"
        case .questionDetected: return "question-detected"
        case .generating: return "generating"
        case .answerReady: return "answer-ready"
        case .paused: return "paused"
        case .stopped: return "stopped"
        }
    }

    public var readableText: String {
        switch uiState {
        case "idle": return "Not capturing."
        case "downloading": return "Preparing speech and model assets."
        case "permission-required": return "A permission is required before capture can start."
        case "source-unavailable": return "The selected source is unavailable. Choose it again to continue."
        case "ready": return "Ready. Capture starts when you press Start."
        case "listening": return "Listening to the selected audio."
        case "question-detected": return "Question detected. Review it or ask for help."
        case "generating": return "Drafting a suggestion."
        case "answer-ready": return "Suggestion ready."
        case "paused": return "Paused. Nothing is being captured."
        case "reconnecting": return "Reconnecting to the audio device."
        case "local-fallback": return "Cloud unavailable. Local captions and notes continue."
        case "budget-low": return "Cloud allowance is running low."
        case "budget-exhausted": return "Cloud allowance is used up. Captions and notes continue."
        case "stopped": return "Stopped. Capture ended and pending work was discarded."
        default: return uiState
        }
    }

    /// Screen-reader announcement policy: announce state changes and completed suggestions, not every token.
    public var announcement: String { readableText }

    public var allowedActions: Set<SessionAction> {
        var actions: Set<SessionAction> = [.selectSource]
        switch phase {
        case .idle, .preparing: actions.insert(.start)
        case .ready: actions.formUnion([.start, .stop])
        case .listening: actions.formUnion([.pause, .stop, .ask, .recapture])
        case .questionDetected: actions.formUnion([.pause, .stop, .ask, .correctQuestion, .recapture])
        case .generating: actions.formUnion([.pause, .stop, .correctQuestion, .ask])
        case .answerReady: actions.formUnion([.pause, .stop, .ask, .correctQuestion, .pinAnswer, .recapture])
        case .paused: actions.formUnion([.resume, .stop])
        case .stopped: actions.formUnion([.saveOrDiscard, .start])
        }
        if degradations.contains(.providerDown) || degradations.contains(.offline) { actions.insert(.retryProvider) }
        if blockers.contains(.permissionRequired) { actions.subtract([.start, .resume, .ask]) }
        return actions
    }
}

public enum PhaseTransition {
    static let table: [SessionPhase: Set<SessionPhase>] = [
        .idle: [.preparing, .ready],
        .preparing: [.ready, .idle],
        .ready: [.listening, .idle, .stopped],
        .listening: [.questionDetected, .generating, .paused, .stopped],
        .questionDetected: [.generating, .listening, .paused, .stopped],
        .generating: [.answerReady, .listening, .questionDetected, .paused, .stopped],
        .answerReady: [.listening, .questionDetected, .generating, .paused, .stopped],
        .paused: [.listening, .ready, .stopped],
        .stopped: [.idle],
    ]

    public static func canTransition(from: SessionPhase, to: SessionPhase) -> Bool {
        from == to || (table[from]?.contains(to) ?? false)
    }
}

public struct InvalidTransition: Error, CustomStringConvertible {
    public let from: SessionPhase, to: SessionPhase
    public var description: String { "invalid session transition \(from) → \(to)" }
}
