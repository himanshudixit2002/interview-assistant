import Foundation

/// A dated price entry. Prices change; every estimate records the registry version it used (§16.1, §16.2).
public struct ModelPrice: Codable, Sendable, Equatable {
    public var provider: String
    public var model: String
    public var inputPerMillion: Double
    public var outputPerMillion: Double
    public var cachedInputPerMillion: Double?
    public var verifiedOn: String
    public var note: String
    public init(provider: String, model: String, inputPerMillion: Double, outputPerMillion: Double, cachedInputPerMillion: Double? = nil, verifiedOn: String, note: String = "") {
        self.provider = provider; self.model = model; self.inputPerMillion = inputPerMillion; self.outputPerMillion = outputPerMillion
        self.cachedInputPerMillion = cachedInputPerMillion; self.verifiedOn = verifiedOn; self.note = note
    }
}

public struct PriceRegistry: Codable, Sendable, Equatable {
    public var version: String
    public var entries: [ModelPrice]
    public init(version: String, entries: [ModelPrice]) { self.version = version; self.entries = entries }

    public func price(provider: String, model: String) -> ModelPrice? {
        entries.first { $0.provider == provider && $0.model == model } ?? entries.first { $0.provider == provider && model.hasPrefix($0.model) }
    }

    /// Published list prices observed on 6 October 2026 from public pricing pages; re-verify before relying on them.
    public static let builtIn = PriceRegistry(version: "2026-10-06", entries: [
        ModelPrice(provider: "deepseek", model: "deepseek-chat", inputPerMillion: 0.27, outputPerMillion: 1.10, cachedInputPerMillion: 0.07, verifiedOn: "2026-10-06", note: "off-peak discounts not modeled"),
        ModelPrice(provider: "deepseek", model: "deepseek-reasoner", inputPerMillion: 0.55, outputPerMillion: 2.19, cachedInputPerMillion: 0.14, verifiedOn: "2026-10-06", note: "reasoning tokens billed as output"),
        ModelPrice(provider: "qwen", model: "qwen3.8-flash", inputPerMillion: 0.15, outputPerMillion: 0.47, verifiedOn: "2026-10-06", note: "Singapore region"),
        ModelPrice(provider: "qwen", model: "qwen3.7-plus", inputPerMillion: 0.40, outputPerMillion: 1.60, verifiedOn: "2026-10-06", note: "Singapore region"),
        ModelPrice(provider: "qwen", model: "qwen-flash", inputPerMillion: 0.15, outputPerMillion: 0.47, verifiedOn: "2026-10-06", note: "alias; verify"),
        ModelPrice(provider: "qwen", model: "qwen-plus", inputPerMillion: 0.40, outputPerMillion: 1.60, verifiedOn: "2026-10-06", note: "alias; verify"),
        ModelPrice(provider: "moonshot", model: "kimi-k2.5", inputPerMillion: 0.60, outputPerMillion: 3.00, verifiedOn: "2026-10-06"),
        ModelPrice(provider: "moonshot", model: "kimi-k2.6", inputPerMillion: 0.95, outputPerMillion: 4.00, verifiedOn: "2026-10-06"),
        ModelPrice(provider: "zai", model: "glm-4.5-air", inputPerMillion: 0.20, outputPerMillion: 1.10, verifiedOn: "2026-10-06"),
        ModelPrice(provider: "zai", model: "glm-4.6", inputPerMillion: 0.60, outputPerMillion: 2.20, verifiedOn: "2026-10-06"),
        ModelPrice(provider: "zai", model: "glm-5", inputPerMillion: 1.00, outputPerMillion: 3.20, verifiedOn: "2026-10-06"),
        ModelPrice(provider: "minimax", model: "MiniMax-M2", inputPerMillion: 0.30, outputPerMillion: 1.20, verifiedOn: "2026-10-06"),
        ModelPrice(provider: "ondevice", model: "apple-foundation", inputPerMillion: 0, outputPerMillion: 0, verifiedOn: "2026-10-06", note: "no cloud charge"),
    ])
}

public enum CostMath {
    public static func cost(inputTokens: Int, cachedInputTokens: Int = 0, outputTokens: Int, price: ModelPrice) -> Double {
        let uncached = max(0, inputTokens - cachedInputTokens)
        let cachedRate = price.cachedInputPerMillion ?? price.inputPerMillion
        return (Double(uncached) * price.inputPerMillion + Double(cachedInputTokens) * cachedRate + Double(outputTokens) * price.outputPerMillion) / 1_000_000
    }

    /// Plan §16.2 formula: contingency on model spend plus a fixed per-session allowance.
    public static func plannedSessionCost(speechCost: Double, reasoningCost: Double, pricedTools: Double = 0, contingency: Double = 0.20, infrastructurePerSession: Double = 0.08) -> Double {
        (1 + contingency) * (speechCost + reasoningCost + pricedTools) + infrastructurePerSession
    }
}

public struct ReservationToken: Hashable, Sendable { public let id: EntityID; public let amountUSD: Double }

/// Reserve-before-call, settle-after ledger (§16.6). User quota and provider dollars are kept distinct by
/// the caller; this ledger tracks a single session cap in USD plus turn allowances.
public actor BudgetLedger {
    public private(set) var capUSD: Double
    public private(set) var reservedUSD: Double = 0
    public private(set) var settledUSD: Double = 0
    public private(set) var entries: [UsageEntry] = []
    public private(set) var routineTurns = 0
    public private(set) var strongTurns = 0
    public private(set) var imageAnalyses = 0
    public let strongTurnAllowance: Int
    public let lowWaterMarkUSD: Double
    private var open: [EntityID: UsageEntry] = [:]
    private var idempotency: Set<String> = []

    public init(capUSD: Double, strongTurnAllowance: Int = 4, lowWaterMarkFraction: Double = 0.25) {
        self.capUSD = capUSD
        self.strongTurnAllowance = strongTurnAllowance
        self.lowWaterMarkUSD = capUSD * lowWaterMarkFraction
    }

    public var remainingUSD: Double { max(0, capUSD - reservedUSD - settledUSD) }
    public var isLow: Bool { remainingUSD <= lowWaterMarkUSD }
    public var isExhausted: Bool { remainingUSD <= 0.000_001 }
    public var canUseStrongRoute: Bool { strongTurns < strongTurnAllowance }

    public func snapshot() -> UsageSnapshot {
        UsageSnapshot(capUSD: capUSD, reservedUSD: reservedUSD, settledUSD: settledUSD, routineTurnsUsed: routineTurns, strongTurnsUsed: strongTurns, imageAnalysesUsed: imageAnalyses)
    }

    public func raiseCap(to newCap: Double) { capUSD = max(capUSD, newCap) }

    /// Fails closed: a request that does not fit the remaining cap is refused before any provider call.
    public func reserve(estimateUSD: Double, sessionID: EntityID?, runID: EntityID?, reason: String, idempotencyKey: String) throws -> ReservationToken {
        if idempotency.contains(idempotencyKey) { throw AssistantError.badInput("duplicate reservation \(idempotencyKey)") }
        guard estimateUSD <= remainingUSD else { throw AssistantError.insufficientQuota }
        let entry = UsageEntry(sessionID: sessionID, runID: runID, reservedUSD: estimateUSD, reason: reason, idempotencyKey: idempotencyKey)
        reservedUSD += estimateUSD
        open[entry.id] = entry
        entries.append(entry)
        idempotency.insert(idempotencyKey)
        return ReservationToken(id: entry.id, amountUSD: estimateUSD)
    }

    /// Settles against actual usage; overruns are absorbed (recorded) rather than hidden, as §11.3 requires.
    public func settle(_ token: ReservationToken, actualUSD: Double, route: RouteKind) {
        guard var entry = open.removeValue(forKey: token.id) else { return }
        reservedUSD -= token.amountUSD
        settledUSD += actualUSD
        entry.settledUSD = actualUSD
        entry.status = .settled
        if let i = entries.firstIndex(where: { $0.id == entry.id }) { entries[i] = entry }
        switch route {
        case .routineCloud: routineTurns += 1
        case .strongCloud: strongTurns += 1
        default: break
        }
    }

    public func release(_ token: ReservationToken) {
        guard var entry = open.removeValue(forKey: token.id) else { return }
        reservedUSD -= token.amountUSD
        entry.status = .released
        if let i = entries.firstIndex(where: { $0.id == entry.id }) { entries[i] = entry }
    }

    public func recordImageAnalysis() { imageAnalyses += 1 }
}
