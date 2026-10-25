import Foundation

/// Identity of the context a generation was started against (plan §8.4, F42).
public struct GenerationStamp: Hashable, Codable, Sendable {
    public let epoch: Int
    public let questionID: EntityID
    public let questionRevision: Int
    public let screenRevision: Int?
    public init(epoch: Int, questionID: EntityID, questionRevision: Int, screenRevision: Int?) {
        self.epoch = epoch; self.questionID = questionID; self.questionRevision = questionRevision; self.screenRevision = screenRevision
    }
}

public struct ActiveContext: Hashable, Sendable {
    public var epoch: Int
    public var questionID: EntityID?
    public var questionRevision: Int
    public var screenRevision: Int?
    public init(epoch: Int, questionID: EntityID?, questionRevision: Int, screenRevision: Int?) {
        self.epoch = epoch; self.questionID = questionID; self.questionRevision = questionRevision; self.screenRevision = screenRevision
    }
}

/// Decides whether output produced for `stamp` may still be published. Late output never overwrites current output.
public enum CurrencyGate {
    public static func isCurrent(_ stamp: GenerationStamp, against active: ActiveContext) -> Bool {
        guard stamp.epoch == active.epoch else { return false }
        guard let activeQuestion = active.questionID, activeQuestion == stamp.questionID,
              stamp.questionRevision == active.questionRevision else { return false }
        if let stampScreen = stamp.screenRevision, let activeScreen = active.screenRevision, activeScreen > stampScreen { return false }
        return true
    }
}

/// Monotonic counters: one session epoch (bumped on stop/pause/source change/new question) and per-entity revisions.
public final class RevisionClock: @unchecked Sendable {
    private let lock = NSLock()
    private var epochValue = 0
    private var revisions: [String: Int] = [:]
    public init() {}

    public var epoch: Int { lock.lock(); defer { lock.unlock() }; return epochValue }

    @discardableResult
    public func bumpEpoch() -> Int { lock.lock(); defer { lock.unlock() }; epochValue += 1; return epochValue }

    public func nextRevision(for key: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        let next = (revisions[key] ?? 0) + 1
        revisions[key] = next
        return next
    }

    public func currentRevision(for key: String) -> Int { lock.lock(); defer { lock.unlock() }; return revisions[key] ?? 0 }
}
