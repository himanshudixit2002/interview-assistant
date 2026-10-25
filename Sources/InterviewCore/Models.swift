import Foundation

// MARK: - Candidate, evidence and targets (plan §10.2)

public enum DocumentKind: String, Codable, Sendable { case pdf, plainText, markdown, docx, unsupported }
public enum ImportStatus: String, Codable, Sendable { case imported, needsOCR, failed, deleted }

public struct ProfileDocument: Codable, Identifiable, Sendable, Equatable {
    public var id: EntityID
    public var filename: String
    public var kind: DocumentKind
    public var contentHash: String
    public var version: Int
    public var importedAt: Date
    public var pageCount: Int
    public var characterCount: Int
    public var status: ImportStatus
    public var diagnostics: [String]
    public init(id: EntityID = EntityID(), filename: String, kind: DocumentKind, contentHash: String, version: Int = 1, importedAt: Date = Date(), pageCount: Int, characterCount: Int, status: ImportStatus, diagnostics: [String] = []) {
        self.id = id; self.filename = filename; self.kind = kind; self.contentHash = contentHash; self.version = version
        self.importedAt = importedAt; self.pageCount = pageCount; self.characterCount = characterCount; self.status = status; self.diagnostics = diagnostics
    }
}

public enum ClaimCategory: String, Codable, Sendable, CaseIterable {
    case employment, responsibility, achievement, skill, education, project, contact, other
    public var label: String { rawValue.capitalized }
}

public enum ApprovalState: String, Codable, Sendable { case proposed, approved, rejected, superseded }

/// A statement about the candidate. Only `approved` claims may ground personal answers (F02, §9.3).
public struct VerifiedClaim: Codable, Identifiable, Sendable, Equatable {
    public var id: EntityID
    public var documentID: EntityID?
    public var text: String
    public var category: ClaimCategory
    public var sourceRange: String?
    public var state: ApprovalState
    public var createdAt: Date
    public var updatedAt: Date
    public var supersededBy: EntityID?
    public var userEdited: Bool
    public init(id: EntityID = EntityID(), documentID: EntityID? = nil, text: String, category: ClaimCategory, sourceRange: String? = nil, state: ApprovalState = .proposed, createdAt: Date = Date(), updatedAt: Date = Date(), supersededBy: EntityID? = nil, userEdited: Bool = false) {
        self.id = id; self.documentID = documentID; self.text = text; self.category = category; self.sourceRange = sourceRange
        self.state = state; self.createdAt = createdAt; self.updatedAt = updatedAt; self.supersededBy = supersededBy; self.userEdited = userEdited
    }
}

/// Situation, task, action, result, lesson (F04). No quantified result is ever invented; `result` may be empty.
public struct Story: Codable, Identifiable, Sendable, Equatable {
    public var id: EntityID
    public var title: String
    public var skillTags: [String]
    public var situation: String
    public var task: String
    public var action: String
    public var result: String
    public var lesson: String
    public var ownership: String
    public var claimRefs: [EntityID]
    public var preferredLengthSeconds: Int
    public var createdAt: Date
    public var updatedAt: Date
    public init(id: EntityID = EntityID(), title: String, skillTags: [String] = [], situation: String = "", task: String = "", action: String = "", result: String = "", lesson: String = "", ownership: String = "", claimRefs: [EntityID] = [], preferredLengthSeconds: Int = 60, createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id; self.title = title; self.skillTags = skillTags; self.situation = situation; self.task = task; self.action = action
        self.result = result; self.lesson = lesson; self.ownership = ownership; self.claimRefs = claimRefs
        self.preferredLengthSeconds = preferredLengthSeconds; self.createdAt = createdAt; self.updatedAt = updatedAt
    }
    public var narrative: String {
        [("Situation", situation), ("Task", task), ("Action", action), ("Result", result), ("Lesson", lesson)]
            .filter { !$0.1.isEmpty }.map { "\($0.0): \($0.1)" }.joined(separator: " ")
    }
}

public enum InterviewStage: String, Codable, Sendable, CaseIterable { case screening, technical, systemDesign, behavioral, onsite, final, other }
public enum Seniority: String, Codable, Sendable, CaseIterable { case intern, junior, mid, senior, staff, lead }

/// One application. Retrieval is scoped to the active target (F05).
public struct InterviewTarget: Codable, Identifiable, Sendable, Equatable {
    public var id: EntityID
    public var role: String
    public var company: String
    public var seniority: Seniority
    public var stage: InterviewStage
    public var language: String
    public var jobDescription: String
    public var jobDescriptionVersion: Int
    public var requiredSkills: [String]
    public var targetSkills: [String]
    public var durationMinutes: Int
    public var createdAt: Date
    public init(id: EntityID = EntityID(), role: String, company: String, seniority: Seniority = .mid, stage: InterviewStage = .technical, language: String = "en-US", jobDescription: String = "", jobDescriptionVersion: Int = 1, requiredSkills: [String] = [], targetSkills: [String] = [], durationMinutes: Int = 60, createdAt: Date = Date()) {
        self.id = id; self.role = role; self.company = company; self.seniority = seniority; self.stage = stage; self.language = language
        self.jobDescription = jobDescription; self.jobDescriptionVersion = jobDescriptionVersion; self.requiredSkills = requiredSkills
        self.targetSkills = targetSkills; self.durationMinutes = durationMinutes; self.createdAt = createdAt
    }
}

// MARK: - Sessions and assistance contract (plan §3)

public enum SessionMode: String, Codable, Sendable, CaseIterable { case preparation, mock, live, captions, review }
public enum ProcessingMode: String, Codable, Sendable, CaseIterable {
    case localOnly, hybrid
    public var label: String { self == .localOnly ? "Local only" : "Hybrid (local capture, cloud reasoning)" }
}

/// Separate switches for transcription, screen analysis, drafting and retention (§3.3). `permittedByUser`
/// records the user's statement; it is not evidence of anyone else's consent.
public struct AssistanceScope: Codable, Sendable, Equatable {
    public var captions: Bool
    public var screenAnalysis: Bool
    public var answerDrafting: Bool
    public var retainTranscript: Bool
    public var permittedByUser: Bool
    public var prohibitedByInterview: Bool
    public init(captions: Bool = true, screenAnalysis: Bool = true, answerDrafting: Bool = true, retainTranscript: Bool = false, permittedByUser: Bool = false, prohibitedByInterview: Bool = false) {
        self.captions = captions; self.screenAnalysis = screenAnalysis; self.answerDrafting = answerDrafting
        self.retainTranscript = retainTranscript; self.permittedByUser = permittedByUser; self.prohibitedByInterview = prohibitedByInterview
    }
    /// Live answer generation is unavailable when the user says help is prohibited (§3.3).
    public var allowsAnswerGeneration: Bool { answerDrafting && !prohibitedByInterview }
    public var summary: String {
        var parts: [String] = []
        if captions { parts.append("captions") }
        if allowsAnswerGeneration { parts.append("answer suggestions") }
        if screenAnalysis { parts.append("selected window") }
        parts.append(retainTranscript ? "transcript saved on request" : "no saved recording")
        return parts.joined(separator: "; ")
    }
}

public struct RetentionPolicy: Codable, Sendable, Equatable {
    public var savedSessionDays: Int
    public var screenshotTTLSeconds: Int
    public var logDays: Int
    public var saveOrDiscardWindowSeconds: Int
    public init(savedSessionDays: Int = 30, screenshotTTLSeconds: Int = 60, logDays: Int = 14, saveOrDiscardWindowSeconds: Int = 300) {
        self.savedSessionDays = savedSessionDays; self.screenshotTTLSeconds = screenshotTTLSeconds; self.logDays = logDays; self.saveOrDiscardWindowSeconds = saveOrDiscardWindowSeconds
    }
}

public struct Session: Codable, Identifiable, Sendable, Equatable {
    public var id: EntityID
    public var targetID: EntityID?
    public var mode: SessionMode
    public var startedAt: Date
    public var endedAt: Date?
    public var scope: AssistanceScope
    public var processingMode: ProcessingMode
    public var retention: RetentionPolicy
    public var pricePolicyVersion: String
    public var deviceClass: String
    public init(id: EntityID = EntityID(), targetID: EntityID?, mode: SessionMode, startedAt: Date = Date(), endedAt: Date? = nil, scope: AssistanceScope, processingMode: ProcessingMode, retention: RetentionPolicy = RetentionPolicy(), pricePolicyVersion: String, deviceClass: String) {
        self.id = id; self.targetID = targetID; self.mode = mode; self.startedAt = startedAt; self.endedAt = endedAt; self.scope = scope
        self.processingMode = processingMode; self.retention = retention; self.pricePolicyVersion = pricePolicyVersion; self.deviceClass = deviceClass
    }
}

// MARK: - Transcript, screen evidence, questions, suggestions (plan §7.4, §8.4, §9.2)

public enum StreamKind: String, Codable, Sendable { case remote, microphone, manual }

public struct TranscriptSegment: Codable, Identifiable, Sendable, Equatable {
    public var id: EntityID
    public var sessionID: EntityID
    public var stream: StreamKind
    public var start: TimeInterval
    public var end: TimeInterval
    public var text: String
    public var revision: Int
    public var isFinal: Bool
    public var isGap: Bool
    public var correctedFromRevision: Int?
    public var receivedAt: Date
    public init(id: EntityID = EntityID(), sessionID: EntityID, stream: StreamKind, start: TimeInterval, end: TimeInterval, text: String, revision: Int = 1, isFinal: Bool, isGap: Bool = false, correctedFromRevision: Int? = nil, receivedAt: Date = Date()) {
        self.id = id; self.sessionID = sessionID; self.stream = stream; self.start = start; self.end = end; self.text = text
        self.revision = revision; self.isFinal = isFinal; self.isGap = isGap; self.correctedFromRevision = correctedFromRevision; self.receivedAt = receivedAt
    }
}

public struct OCRRegion: Codable, Sendable, Equatable {
    public var text: String
    public var confidence: Double
    public var x: Double, y: Double, width: Double, height: Double   // normalized, top-left origin
    public init(text: String, confidence: Double, x: Double, y: Double, width: Double, height: Double) {
        self.text = text; self.confidence = confidence; self.x = x; self.y = y; self.width = width; self.height = height
    }
}

public enum ScreenFreshness: String, Codable, Sendable { case fresh, stale, sourceClosed, sourceMinimized, blank, unreadable, replaced }

public struct ScreenEvidence: Codable, Identifiable, Sendable, Equatable {
    public var id: EntityID
    public var sessionID: EntityID
    public var sourceID: String
    public var sourceTitleHash: String
    public var capturedAt: Date
    public var revision: Int
    public var text: String
    public var regions: [OCRRegion]
    public var contentHash: String
    public var freshness: ScreenFreshness
    public var looksLikeCode: Bool
    public init(id: EntityID = EntityID(), sessionID: EntityID, sourceID: String, sourceTitleHash: String, capturedAt: Date = Date(), revision: Int, text: String, regions: [OCRRegion], contentHash: String, freshness: ScreenFreshness = .fresh, looksLikeCode: Bool) {
        self.id = id; self.sessionID = sessionID; self.sourceID = sourceID; self.sourceTitleHash = sourceTitleHash; self.capturedAt = capturedAt
        self.revision = revision; self.text = text; self.regions = regions; self.contentHash = contentHash; self.freshness = freshness; self.looksLikeCode = looksLikeCode
    }
}

public enum QuestionKind: String, Codable, Sendable, CaseIterable {
    case behavioral, coding, systemDesign, debugging, sql, conceptual, followup, correction, clarification, other
    public var label: String {
        switch self {
        case .behavioral: return "Behavioral"; case .coding: return "Coding"; case .systemDesign: return "System design"
        case .debugging: return "Debugging"; case .sql: return "SQL"; case .conceptual: return "Conceptual"; case .followup: return "Follow-up"
        case .correction: return "Correction"; case .clarification: return "Clarification"; case .other: return "Question"
        }
    }
}

public enum QuestionSource: String, Codable, Sendable { case audio, screen, manual, merged }
public enum QuestionStatus: String, Codable, Sendable { case active, superseded, answered, dismissed }

public struct Question: Codable, Identifiable, Sendable, Equatable {
    public var id: EntityID
    public var sessionID: EntityID
    public var text: String
    public var kind: QuestionKind
    public var revision: Int
    public var source: QuestionSource
    public var transcriptRefs: [EntityID]
    public var screenEvidenceID: EntityID?
    public var screenRevision: Int?
    public var parentQuestionID: EntityID?
    public var status: QuestionStatus
    public var createdAt: Date
    public var updatedAt: Date
    public init(id: EntityID = EntityID(), sessionID: EntityID, text: String, kind: QuestionKind, revision: Int = 1, source: QuestionSource, transcriptRefs: [EntityID] = [], screenEvidenceID: EntityID? = nil, screenRevision: Int? = nil, parentQuestionID: EntityID? = nil, status: QuestionStatus = .active, createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id; self.sessionID = sessionID; self.text = text; self.kind = kind; self.revision = revision; self.source = source
        self.transcriptRefs = transcriptRefs; self.screenEvidenceID = screenEvidenceID; self.screenRevision = screenRevision
        self.parentQuestionID = parentQuestionID; self.status = status; self.createdAt = createdAt; self.updatedAt = updatedAt
    }
}

public enum VerificationStatus: String, Codable, Sendable {
    case supported, generalExplanation, needsConfirmation, unexecuted, failed
    public var label: String {
        switch self {
        case .supported: return "Supported by your confirmed evidence"
        case .generalExplanation: return "General technical explanation"
        case .needsConfirmation: return "Needs your confirmation"
        case .unexecuted: return "Code not executed"
        case .failed: return "Could not verify"
        }
    }
}

public enum RouteKind: String, Codable, Sendable { case onDevice, routineCloud, strongCloud, none }

public struct KeyPoint: Codable, Sendable, Equatable {
    public var text: String
    public var evidenceIDs: [EntityID]
    public var status: VerificationStatus
    public init(text: String, evidenceIDs: [EntityID] = [], status: VerificationStatus) { self.text = text; self.evidenceIDs = evidenceIDs; self.status = status }
}

/// The response contract (§9.2). Technical artifacts stay in `optionalDetail`; the spoken outline is the rest.
public struct Suggestion: Codable, Identifiable, Sendable, Equatable {
    public var id: EntityID
    public var questionID: EntityID
    public var questionRevision: Int
    public var shortAnswer: String
    public var keyPoints: [KeyPoint]
    public var assumptions: [String]
    public var missingInformation: [String]
    public var optionalDetail: String?
    public var verificationStatus: VerificationStatus
    public var route: RouteKind
    public var modelRunID: EntityID?
    public var superseded: Bool
    public var completed: Bool
    public var createdAt: Date
    public init(id: EntityID = EntityID(), questionID: EntityID, questionRevision: Int, shortAnswer: String = "", keyPoints: [KeyPoint] = [], assumptions: [String] = [], missingInformation: [String] = [], optionalDetail: String? = nil, verificationStatus: VerificationStatus = .generalExplanation, route: RouteKind, modelRunID: EntityID? = nil, superseded: Bool = false, completed: Bool = false, createdAt: Date = Date()) {
        self.id = id; self.questionID = questionID; self.questionRevision = questionRevision; self.shortAnswer = shortAnswer; self.keyPoints = keyPoints
        self.assumptions = assumptions; self.missingInformation = missingInformation; self.optionalDetail = optionalDetail
        self.verificationStatus = verificationStatus; self.route = route; self.modelRunID = modelRunID; self.superseded = superseded; self.completed = completed; self.createdAt = createdAt
    }
}

// MARK: - Model runs and usage (plan §10.2, §16.6)

public enum RunOutcome: String, Codable, Sendable { case succeeded, cancelled, failed, timedOut, rateLimited, budgetRefused }

public struct ModelRun: Codable, Identifiable, Sendable, Equatable {
    public var id: EntityID
    public var sessionID: EntityID?
    public var provider: String
    public var model: String
    public var route: RouteKind
    public var requestHash: String
    public var startedAt: Date
    public var firstTokenMs: Double?
    public var totalMs: Double?
    public var inputTokens: Int
    public var cachedInputTokens: Int
    public var outputTokens: Int
    public var outcome: RunOutcome
    public var retryOf: EntityID?
    public var priceVersion: String
    public var estimatedCostUSD: Double
    public init(id: EntityID = EntityID(), sessionID: EntityID?, provider: String, model: String, route: RouteKind, requestHash: String, startedAt: Date = Date(), firstTokenMs: Double? = nil, totalMs: Double? = nil, inputTokens: Int = 0, cachedInputTokens: Int = 0, outputTokens: Int = 0, outcome: RunOutcome = .succeeded, retryOf: EntityID? = nil, priceVersion: String, estimatedCostUSD: Double = 0) {
        self.id = id; self.sessionID = sessionID; self.provider = provider; self.model = model; self.route = route; self.requestHash = requestHash
        self.startedAt = startedAt; self.firstTokenMs = firstTokenMs; self.totalMs = totalMs; self.inputTokens = inputTokens; self.cachedInputTokens = cachedInputTokens
        self.outputTokens = outputTokens; self.outcome = outcome; self.retryOf = retryOf; self.priceVersion = priceVersion; self.estimatedCostUSD = estimatedCostUSD
    }
}

public enum UsageEntryStatus: String, Codable, Sendable { case reserved, settled, released }

public struct UsageEntry: Codable, Identifiable, Sendable, Equatable {
    public var id: EntityID
    public var sessionID: EntityID?
    public var runID: EntityID?
    public var reservedUSD: Double
    public var settledUSD: Double
    public var status: UsageEntryStatus
    public var reason: String
    public var idempotencyKey: String
    public var createdAt: Date
    public init(id: EntityID = EntityID(), sessionID: EntityID?, runID: EntityID?, reservedUSD: Double, settledUSD: Double = 0, status: UsageEntryStatus = .reserved, reason: String, idempotencyKey: String, createdAt: Date = Date()) {
        self.id = id; self.sessionID = sessionID; self.runID = runID; self.reservedUSD = reservedUSD; self.settledUSD = settledUSD; self.status = status
        self.reason = reason; self.idempotencyKey = idempotencyKey; self.createdAt = createdAt
    }
}

public struct UsageSnapshot: Codable, Sendable, Equatable {
    public var capUSD: Double
    public var reservedUSD: Double
    public var settledUSD: Double
    public var routineTurnsUsed: Int
    public var strongTurnsUsed: Int
    public var imageAnalysesUsed: Int
    public init(capUSD: Double, reservedUSD: Double, settledUSD: Double, routineTurnsUsed: Int, strongTurnsUsed: Int, imageAnalysesUsed: Int) {
        self.capUSD = capUSD; self.reservedUSD = reservedUSD; self.settledUSD = settledUSD; self.routineTurnsUsed = routineTurnsUsed
        self.strongTurnsUsed = strongTurnsUsed; self.imageAnalysesUsed = imageAnalysesUsed
    }
    public var remainingUSD: Double { max(0, capUSD - reservedUSD - settledUSD) }
}

/// Recorded choices (§10.2 ConsentPreference). Never presented as proof of third-party permission.
public struct ConsentPreference: Codable, Sendable, Equatable {
    public var cloudReasoningEnabled: Bool
    public var cloudProviderID: String
    public var diagnosticsOptIn: Bool
    public var syncEnabled: Bool
    public var changedAt: Date
    public init(cloudReasoningEnabled: Bool = false, cloudProviderID: String = "", diagnosticsOptIn: Bool = false, syncEnabled: Bool = false, changedAt: Date = Date()) {
        self.cloudReasoningEnabled = cloudReasoningEnabled; self.cloudProviderID = cloudProviderID; self.diagnosticsOptIn = diagnosticsOptIn; self.syncEnabled = syncEnabled; self.changedAt = changedAt
    }
}

public struct DeletionJob: Codable, Identifiable, Sendable, Equatable {
    public var id: EntityID
    public var scope: String
    public var targets: [String]
    public var completed: [String]
    public var failures: [String]
    public var requestedAt: Date
    public var finishedAt: Date?
    public init(id: EntityID = EntityID(), scope: String, targets: [String], completed: [String] = [], failures: [String] = [], requestedAt: Date = Date(), finishedAt: Date? = nil) {
        self.id = id; self.scope = scope; self.targets = targets; self.completed = completed; self.failures = failures; self.requestedAt = requestedAt; self.finishedAt = finishedAt
    }
}
