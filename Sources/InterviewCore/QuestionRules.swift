import Foundation

public enum UtteranceKind: String, Codable, Sendable, CaseIterable { case question, followup, correction, statement }

/// Deterministic first pass for question detection (F16, §9.1 step 2). An on-device classifier can refine it.
public struct QuestionRuleClassifier: Sendable {
    public struct Verdict: Equatable, Sendable { public let kind: UtteranceKind; public let confidence: Double }

    static let questionOpeners = ["tell me", "walk me", "explain", "describe", "how would", "how do", "how did", "how does", "what", "why", "when", "where", "which", "who", "can you", "could you", "would you", "design", "implement", "write", "suppose", "imagine", "let's say", "lets say", "given", "is there", "are there", "do you", "did you", "have you", "talk me through", "take me through", "show me", "compare", "estimate", "solve", "find", "detect", "optimi"]
    static let followupOpeners = ["why", "and ", "what about", "how about", "can you elaborate", "elaborate", "for example", "for instance", "like what", "such as", "really", "go on", "and then", "what else", "anything else", "could you expand", "say more", "can you give me an example", "give me an example", "any example", "could you give me an example", "how so", "what do you mean", "in what way"]
    static let correctionMarkers = ["actually", "i meant", "instead", "make that", "change that", "let's change", "correction", "sorry,", "not ", "rather than", "scratch that", "forget that"]
    static let statementMarkers = ["let me share", "give me a second", "one moment", "thanks", "thank you", "great", "okay", "ok", "got it", "makes sense", "sounds good", "my audio", "can you hear me", "let me know when"]

    public static func classify(_ rawText: String, previousQuestionExists: Bool) -> Verdict {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()
        let words = Tokenizer.words(text)
        guard !words.isEmpty else { return Verdict(kind: .statement, confidence: 1) }
        let endsWithQuestionMark = text.hasSuffix("?")

        // Logistics and acknowledgements first: "can you hear me?", "okay", "let me share my screen".
        if words.count <= 6, statementMarkers.contains(where: { lower.hasPrefix($0) }) { return Verdict(kind: .statement, confidence: 0.85) }

        if previousQuestionExists,
           lower.hasPrefix("actually") || lower.contains("i meant") || lower.contains("make that") || lower.contains("instead of") || lower.contains("change that") || lower.hasPrefix("scratch that") || lower.hasPrefix("correction") || (lower.hasPrefix("sorry") && lower.contains("not ")) {
            return Verdict(kind: .correction, confidence: 0.8)
        }

        let startsLikeFollowup = followupOpeners.contains { lower.hasPrefix($0) }
        if previousQuestionExists {
            if startsLikeFollowup && words.count <= 8 { return Verdict(kind: .followup, confidence: endsWithQuestionMark ? 0.85 : 0.6) }
            if endsWithQuestionMark && words.count <= 8 && (lower.contains(" that?") || lower.contains(" that one") || lower.hasSuffix(" this?") || lower.hasPrefix("and ")) {
                return Verdict(kind: .followup, confidence: 0.7)
            }
        }

        let startsLikeQuestion = questionOpeners.contains { lower.hasPrefix($0) }
        if endsWithQuestionMark || startsLikeQuestion {
            return Verdict(kind: .question, confidence: endsWithQuestionMark && startsLikeQuestion ? 0.95 : 0.75)
        }
        if words.count >= 8 && (lower.contains(" how ") || lower.contains(" what ") || lower.contains(" why ")) {
            return Verdict(kind: .question, confidence: 0.5)
        }
        return Verdict(kind: .statement, confidence: 0.6)
    }
}

/// Maps a question to the module that should answer it (plan §4.5).
public enum QuestionTypeClassifier {
    public static func kind(for text: String, screenLooksLikeCode: Bool, utterance: UtteranceKind) -> QuestionKind {
        switch utterance {
        case .followup: return .followup
        case .correction: return .correction
        default: break
        }
        let l = text.lowercased()
        if l.contains("tell me about a time") || l.contains("describe a situation") || l.contains("disagree") || l.contains("conflict") || l.contains("proud of") || l.contains("a time when") || l.contains("failure") || l.contains("mistake") || l.contains("feedback") {
            return .behavioral
        }
        if l.contains("sql") || l.contains(" join") || l.contains("query") || l.contains("window function") || l.contains("group by") { return .sql }
        if l.contains("design a") || l.contains("design the") || l.contains("architect") || l.contains("scale to") || l.contains("million users") || l.contains("billion") && l.contains("requests") || l.contains("system design") { return .systemDesign }
        if l.contains("debug") || l.contains("why is it slow") || l.contains("crash") || l.contains("incident") && !l.contains("tell me about") || l.contains("not working") || l.contains("fails") { return .debugging }
        if screenLooksLikeCode || l.contains("complexity") || l.contains("algorithm") || l.contains("implement") || l.contains("write a function") || l.contains("duplicates") || l.contains("array") || l.contains("string") || l.contains("linked list") || l.contains("tree") || l.contains("graph") { return .coding }
        if l.contains("difference between") || l.contains("explain") || l.contains("what is") || l.contains("what are") || l.contains("how does") || l.contains("why did you choose") { return .conceptual }
        return .other
    }
}
