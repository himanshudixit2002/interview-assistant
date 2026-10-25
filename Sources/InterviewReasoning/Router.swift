import Foundation
import InterviewCore

/// Per-provider failure tracking: after repeated failures the route is skipped for a cool-down (plan §11.3).
public actor CircuitBreaker {
    private var failures: [String: Int] = [:]
    private var openUntil: [String: Date] = [:]
    public let threshold: Int
    public let coolDown: TimeInterval
    public init(threshold: Int = 3, coolDown: TimeInterval = 30) { self.threshold = threshold; self.coolDown = coolDown }

    public func isOpen(_ providerID: String) -> Bool {
        if let until = openUntil[providerID], until > Date() { return true }
        openUntil[providerID] = nil
        return false
    }
    public func recordSuccess(_ providerID: String) { failures[providerID] = 0; openUntil[providerID] = nil }
    public func recordFailure(_ providerID: String) {
        failures[providerID, default: 0] += 1
        if failures[providerID]! >= threshold { openUntil[providerID] = Date().addingTimeInterval(coolDown); failures[providerID] = 0 }
    }
}

public struct RoutingInput: Sendable {
    public var questionKind: QuestionKind
    public var processingMode: ProcessingMode
    public var depthRequested: Bool
    public var cloudConfigured: Bool
    public var cloudCircuitOpen: Bool
    public var onDeviceAvailable: Bool
    public var budgetExhausted: Bool
    public var strongTurnsRemaining: Int
    public var offline: Bool
    public init(questionKind: QuestionKind, processingMode: ProcessingMode, depthRequested: Bool, cloudConfigured: Bool, cloudCircuitOpen: Bool, onDeviceAvailable: Bool, budgetExhausted: Bool, strongTurnsRemaining: Int, offline: Bool) {
        self.questionKind = questionKind; self.processingMode = processingMode; self.depthRequested = depthRequested; self.cloudConfigured = cloudConfigured
        self.cloudCircuitOpen = cloudCircuitOpen; self.onDeviceAvailable = onDeviceAvailable; self.budgetExhausted = budgetExhausted
        self.strongTurnsRemaining = strongTurnsRemaining; self.offline = offline
    }
}

public struct RoutingDecision: Equatable, Sendable {
    public var route: RouteKind
    public var reason: String
    public var degraded: Bool
    public init(route: RouteKind, reason: String, degraded: Bool) { self.route = route; self.reason = reason; self.degraded = degraded }
}

/// Deterministic routing (§9.5): cheapest evaluated route that fits the task; one controlled escalation only
/// when the user asks for depth; on-device fallback that is always labeled.
public enum ProviderRouter {
    public static func decide(_ input: RoutingInput) -> RoutingDecision {
        if input.processingMode == .localOnly {
            return input.onDeviceAvailable
                ? RoutingDecision(route: .onDevice, reason: "local-only mode", degraded: false)
                : RoutingDecision(route: .none, reason: "local-only mode and no on-device model", degraded: true)
        }
        let cloudUsable = input.cloudConfigured && !input.cloudCircuitOpen && !input.budgetExhausted && !input.offline
        if !cloudUsable {
            let why = !input.cloudConfigured ? "no cloud provider configured" : input.offline ? "offline" : input.budgetExhausted ? "cloud allowance exhausted" : "provider circuit open"
            return input.onDeviceAvailable
                ? RoutingDecision(route: .onDevice, reason: why + "; using on-device model", degraded: true)
                : RoutingDecision(route: .none, reason: why + "; no fallback available", degraded: true)
        }
        if input.depthRequested && input.strongTurnsRemaining > 0 {
            return RoutingDecision(route: .strongCloud, reason: "depth requested; strong turn available", degraded: false)
        }
        if input.depthRequested {
            return RoutingDecision(route: .routineCloud, reason: "strong allowance used up; routine route labeled as standard", degraded: true)
        }
        return RoutingDecision(route: .routineCloud, reason: "routine route", degraded: false)
    }
}
