import Foundation
import NaturalLanguage
import InterviewCore

/// Hybrid lexical plus on-device semantic retrieval over approved claims and stories (§9.4). The index is
/// rebuilt in memory from the encrypted store; nothing is written to disk. Scoped to one target at a time (F05).
public final class EvidenceIndex: @unchecked Sendable {
    public struct Entry: Sendable { public let ref: EvidenceRef; let tokens: Set<String>; let vector: [Double]? }
    private var entries: [Entry] = []
    private let embedding: NLEmbedding?
    private let lock = NSLock()

    public init(useEmbeddings: Bool = true) { embedding = useEmbeddings ? NLEmbedding.sentenceEmbedding(for: .english) : nil }

    public func rebuild(claims: [VerifiedClaim], stories: [Story]) {
        var built: [Entry] = []
        var claimIndex = 0, storyIndex = 0
        for c in claims where c.state == .approved && c.category != .contact {
            claimIndex += 1
            built.append(Entry(ref: EvidenceRef(label: "E\(claimIndex)", id: c.id, kind: .claim, text: c.text), tokens: Tokenizer.contentWords(c.text), vector: embedding?.vector(for: c.text)))
        }
        for s in stories {
            storyIndex += 1
            let text = s.title + ". " + s.narrative + " Skills: " + s.skillTags.joined(separator: ", ")
            built.append(Entry(ref: EvidenceRef(label: "S\(storyIndex)", id: s.id, kind: .story, text: text), tokens: Tokenizer.contentWords(text), vector: embedding?.vector(for: text)))
        }
        lock.lock(); entries = built; lock.unlock()
    }

    public var count: Int { lock.lock(); defer { lock.unlock() }; return entries.count }

    /// Returns the best-supported evidence for a question. Lexical overlap dominates; embeddings break ties,
    /// because the Phase 0 spike showed on-device sentence embeddings alone rank poorly.
    public func retrieve(question: String, kind: QuestionKind, limit: Int = 4) -> [EvidenceHit] {
        lock.lock(); let snapshot = entries; lock.unlock()
        let qTokens = Tokenizer.contentWords(question)
        let qVector = embedding?.vector(for: question)
        var hits: [EvidenceHit] = []
        for e in snapshot {
            let overlap = Double(e.tokens.intersection(qTokens).count)
            let lexical = qTokens.isEmpty ? 0 : overlap / Double(qTokens.count).squareRoot()
            var semantic = 0.0
            if let qv = qVector, let v = e.vector, !v.isEmpty { semantic = max(0, Self.cosine(qv, v)) }
            var score = lexical * 1.0 + semantic * 0.6
            if kind == .behavioral && e.ref.kind == .story { score += 0.15 }
            if score > 0.12 { hits.append(EvidenceHit(ref: e.ref, score: score)) }
        }
        return Array(hits.sorted { $0.score > $1.score }.prefix(limit))
    }

    static func cosine(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot = 0.0, na = 0.0, nb = 0.0
        for i in 0..<a.count { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        return na > 0 && nb > 0 ? dot / (na.squareRoot() * nb.squareRoot()) : 0
    }
}

/// Finds inconsistencies a human should resolve (F08): conflicting dates and ownership language drift.
public enum ContradictionChecker {
    public struct Finding: Sendable, Equatable { public let message: String; public let claimIDs: [EntityID] }

    public static func check(_ claims: [VerifiedClaim]) -> [Finding] {
        var findings: [Finding] = []
        let employment = claims.filter { $0.category == .employment }
        for (i, a) in employment.enumerated() {
            for b in employment.dropFirst(i + 1) {
                if let ra = yearRange(a.text), let rb = yearRange(b.text), ra.0 == rb.0, ra.1 != rb.1 {
                    findings.append(Finding(message: "Two employment entries start in \(ra.0) but end in different years (\(ra.1) vs \(rb.1)).", claimIDs: [a.id, b.id]))
                }
            }
        }
        let teamWords = ["we ", "our team", "the team"]
        let soloWords = ["i led", "i built", "i designed", "i owned"]
        for c in claims {
            let l = " " + c.text.lowercased()
            if teamWords.contains(where: { l.contains($0) }) && soloWords.contains(where: { l.contains($0) }) {
                findings.append(Finding(message: "This claim mixes team and personal ownership; say which parts were yours.", claimIDs: [c.id]))
            }
        }
        return findings
    }

    static func yearRange(_ text: String) -> (Int, Int)? {
        let years = text.matches(of: #/(19|20)\d\d/#).compactMap { Int($0.output.0) }
        guard years.count >= 2 else { return nil }
        return (years[0], years[1])
    }
}
