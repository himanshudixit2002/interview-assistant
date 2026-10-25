import Foundation

public enum TokenEstimator {
    /// Conservative estimate (about four UTF-8 bytes per token) used for budgeting before a provider reports usage.
    public static func estimate(_ text: String) -> Int { max(1, (text.utf8.count + 3) / 4) }
}

public enum ContextSectionKind: String, Codable, Sendable, CaseIterable {
    case instructions, question, screenConstraints, personalFacts, evidence, recentTurns, summary
    /// Lower trims first. Instructions, the current question and current constraints are never trimmed (§9.4).
    var trimPriority: Int {
        switch self {
        case .summary: return 0
        case .recentTurns: return 1
        case .evidence: return 2
        case .personalFacts: return 3
        case .instructions, .question, .screenConstraints: return Int.max
        }
    }
}

public struct ContextItem: Codable, Sendable, Equatable {
    public var text: String
    public var sourceID: EntityID?
    public var sourceRevision: Int?
    public var label: String?
    public var score: Double
    public var tokens: Int
    public init(text: String, sourceID: EntityID? = nil, sourceRevision: Int? = nil, label: String? = nil, score: Double = 0) {
        self.text = text; self.sourceID = sourceID; self.sourceRevision = sourceRevision; self.label = label; self.score = score
        self.tokens = TokenEstimator.estimate(text)
    }
}

public struct ContextSection: Codable, Sendable, Equatable {
    public var kind: ContextSectionKind
    public var items: [ContextItem]
    public init(kind: ContextSectionKind, items: [ContextItem]) { self.kind = kind; self.items = items }
    public var tokens: Int { items.reduce(0) { $0 + $1.tokens } }
}

public struct ContextPackage: Codable, Sendable, Equatable {
    public var sections: [ContextSection]
    public var totalTokens: Int
    public var trimmed: [ContextSectionKind: Int]
    public var provenance: [EntityID: Int?]
    public var evidenceLabels: [String: EntityID]
    public init(sections: [ContextSection], totalTokens: Int, trimmed: [ContextSectionKind: Int], provenance: [EntityID: Int?], evidenceLabels: [String: EntityID]) {
        self.sections = sections; self.totalTokens = totalTokens; self.trimmed = trimmed; self.provenance = provenance; self.evidenceLabels = evidenceLabels
    }
    public func section(_ kind: ContextSectionKind) -> ContextSection? { sections.first { $0.kind == kind } }
}

/// Bounded context assembly (§9.4): fills a token budget, trimming low-value history first and never dropping
/// the current question or its numeric constraints.
public struct ContextBudgeter: Sendable {
    public let budgetTokens: Int
    public init(budgetTokens: Int = 6_000) { self.budgetTokens = budgetTokens }

    public func build(_ input: [ContextSection]) throws -> ContextPackage {
        var sections = input
        var trimmed: [ContextSectionKind: Int] = [:]
        let fixed = sections.filter { $0.kind.trimPriority == Int.max }.reduce(0) { $0 + $1.tokens }
        guard fixed <= budgetTokens else {
            throw AssistantError.badInput("current question and constraints exceed the context budget (\(fixed) > \(budgetTokens) tokens)")
        }
        func total() -> Int { sections.reduce(0) { $0 + $1.tokens } }
        let order = sections.indices.sorted { sections[$0].kind.trimPriority < sections[$1].kind.trimPriority }
        for index in order where sections[index].kind.trimPriority != Int.max {
            while total() > budgetTokens, !sections[index].items.isEmpty {
                // Recent turns and summaries drop oldest first; evidence and facts drop the lowest score first.
                let dropIndex: Int
                switch sections[index].kind {
                case .recentTurns, .summary: dropIndex = 0
                default: dropIndex = sections[index].items.indices.min { sections[index].items[$0].score < sections[index].items[$1].score } ?? 0
                }
                sections[index].items.remove(at: dropIndex)
                trimmed[sections[index].kind, default: 0] += 1
            }
            if total() <= budgetTokens { break }
        }
        var provenance: [EntityID: Int?] = [:]
        var labels: [String: EntityID] = [:]
        for s in sections { for item in s.items {
            if let id = item.sourceID { provenance[id] = item.sourceRevision }
            if let label = item.label, let id = item.sourceID { labels[label] = id }
        } }
        return ContextPackage(sections: sections.filter { !$0.items.isEmpty }, totalTokens: total(), trimmed: trimmed, provenance: provenance, evidenceLabels: labels)
    }
}
