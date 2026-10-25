import Foundation

public enum EvidenceKind: String, Codable, Sendable { case claim, story, screen, jobDescription }

public struct EvidenceRef: Codable, Sendable, Equatable {
    public var label: String
    public var id: EntityID
    public var kind: EvidenceKind
    public var text: String
    public init(label: String, id: EntityID, kind: EvidenceKind, text: String) { self.label = label; self.id = id; self.kind = kind; self.text = text }
}

public enum GroundingVerdict: Equatable, Sendable {
    case publish(AnswerBlock, evidenceIDs: [EntityID], status: VerificationStatus)
    case rewritten(AnswerBlock, reason: String)
    case suppressed(reason: String)
}

/// Pre-display checks (§9.1 step 8, §9.3, §9.6): unknown citations are rejected, personal claims without
/// semantically supporting evidence are converted into "needs confirmation" items instead of being shown,
/// and evidence that is cited must actually overlap with the point it supports.
public struct GroundingVerifier: Sendable {
    public let allowed: [String: EvidenceRef]
    public init(evidence: [EvidenceRef]) { allowed = Dictionary(uniqueKeysWithValues: evidence.map { ($0.label.uppercased(), $0) }) }

    static let firstPerson = ["i ", "i've", "i have", "i had", "we ", "we've", "my team", "my ", "our "]
    static let achievementVerbs = ["led", "lead", "built", "designed", "shipped", "migrated", "reduced", "increased", "improved", "cut", "saved", "grew", "scaled", "owned", "managed", "delivered", "launched", "implemented", "optimized", "optimised", "architected", "mentored", "hired", "rewrote", "refactored", "automated", "handled", "drove"]
    static let quantityPattern = try! NSRegularExpression(pattern: #"\b\d+(\.\d+)?\s*(%|percent|x|times|ms|seconds|users|requests|qps|rps|million|billion|k\b|engineers|people|team members|services|customers)"#, options: [.caseInsensitive])
    static let employerPattern = try! NSRegularExpression(pattern: #"\b(at|for|with)\s+[A-Z][A-Za-z0-9]+"#)
    /// "I collapsed", "when we migrated": a past-tense verb within three words after a first-person pronoun.
    static let pastTenseAfterSelf = try! NSRegularExpression(pattern: #"\b(I|we)\b(\s+\w+){0,3}?\s+\w{2,}ed\b"#, options: [.caseInsensitive])
    static let experienceMarkers = ["when i ", "when we ", "at my ", "in my ", "my last ", "my previous ", "previous role", "last role", "last job", "my team", "our team", "a project", "the project", "years ago", "back then", "once ", "did something similar", "similar when"]
    static let workNouns = ["endpoint", "service", "pipeline", "system", "migration", "latency", "api", "database", "schema", "feature", "release", "deployment", "incident", "outage", "codebase", "cluster", "queue", "cache", "index", "throughput", "customers", "users", "revenue", "cost"]

    public static func isPersonalClaim(_ text: String) -> Bool {
        let lower = " " + text.lowercased() + " "
        let mentionsSelf = firstPerson.contains { lower.contains(" " + $0) }
        guard mentionsSelf else { return false }
        let range = NSRange(text.startIndex..., in: text)
        let hasQuantity = quantityPattern.firstMatch(in: text, range: range) != nil
        let hasVerb = achievementVerbs.contains { lower.contains(" \($0) ") }
        let namesEmployer = employerPattern.firstMatch(in: text, range: range) != nil
        let pastTense = pastTenseAfterSelf.firstMatch(in: text, range: range) != nil
        let experiential = experienceMarkers.contains { lower.contains($0) } || workNouns.contains { lower.contains(" \($0)") }
        return hasVerb || hasQuantity || namesEmployer || (pastTense && experiential)
    }

    /// Cheap semantic-support check: the cited evidence must share content words with the point.
    public static func supports(_ evidenceText: String, point: String) -> Bool {
        let e = Tokenizer.contentWords(evidenceText), p = Tokenizer.contentWords(point)
        guard !e.isEmpty, !p.isEmpty else { return false }
        let overlap = e.intersection(p).count
        return overlap >= 2 || Double(overlap) / Double(min(e.count, p.count)) >= 0.25
    }

    public func verify(_ block: AnswerBlock) -> GroundingVerdict {
        switch block.kind {
        case .assume, .missing, .clarify:
            return .publish(block, evidenceIDs: [], status: .generalExplanation)
        case .detail:
            // Detail may contain code or long analysis; label as unexecuted technical content.
            return .publish(block, evidenceIDs: [], status: block.text.contains("```") ? .unexecuted : .generalExplanation)
        case .short, .point:
            var validIDs: [EntityID] = []
            var supported = false
            for label in block.evidenceLabels {
                guard let ref = allowed[label.uppercased()] else { continue }   // unknown citation: dropped, never rendered
                validIDs.append(ref.id)
                if Self.supports(ref.text, point: block.text) { supported = true }
            }
            let personal = Self.isPersonalClaim(block.text)
            if personal && !supported {
                let rewritten = AnswerBlock(kind: .missing, text: "Confirm before saying this: \(block.text)")
                return .rewritten(rewritten, reason: validIDs.isEmpty ? "personal claim without evidence" : "cited evidence does not support the claim")
            }
            let status: VerificationStatus = supported ? .supported : (validIDs.isEmpty ? .generalExplanation : .needsConfirmation)
            var clean = block
            clean.evidenceLabels = block.evidenceLabels.filter { allowed[$0.uppercased()] != nil }
            return .publish(clean, evidenceIDs: validIDs, status: status)
        }
    }
}
