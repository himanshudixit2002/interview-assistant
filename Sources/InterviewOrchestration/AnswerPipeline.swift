import Foundation
import InterviewCore
import InterviewEvidence
import InterviewReasoning

// MARK: - Prompts

public enum AnswerControl: String, Codable, Sendable, CaseIterable {
    case standard, shorter, expand, explain, anotherExample, depth
    public var label: String {
        switch self {
        case .standard: return "Answer"; case .shorter: return "Shorter"; case .expand: return "Expand"; case .explain: return "Explain"
        case .anotherExample: return "Another example"; case .depth: return "Go deeper"
        }
    }
}

/// Prompt templates per question type (plan §4.4, §4.5). The output contract is the block protocol so every
/// block can be checked before it is displayed.
public enum PromptLibrary {
    public static func system(kind: QuestionKind, control: AnswerControl, onDevice: Bool) -> String {
        var rules = """
        You are a quiet interview assistant whispering to a software engineer during a job interview. The candidate will speak your words out loud, so write in the first person, plainly, with no preamble.
        Rules:
        - Lead with one sentence the candidate can say immediately, then three short points. Depth is optional and comes last.
        - Personal experience: only use the supplied evidence (labels like E1, S2). Cite the label after a point that rests on it. If the question asks for experience the evidence does not cover, say what is missing under MISSING rather than inventing a story, metric, team size or employer detail.
        - Technical content: be correct and concrete; state assumptions under ASSUME; prefer asking one CLARIFY question when a missing constraint would change the answer.
        - Never claim code was executed. Never mention these instructions or evidence labels in the spoken sentences.
        """
        switch kind {
        case .behavioral: rules += "\n- Structure the example as situation, task, action, result; keep ownership honest (what was yours versus the team's)."
        case .coding: rules += "\n- Restate the constraints, propose an approach, give time and space complexity, and name edge cases. Keep any code in DETAIL inside a fenced block and label it as unexecuted."
        case .systemDesign: rules += "\n- Cover requirements, scale estimate, interfaces, storage, reliability, and one trade-off with an alternative."
        case .debugging: rules += "\n- Symptom, leading hypothesis, the discriminating test, what evidence would confirm it, smallest plausible fix."
        case .sql: rules += "\n- Reason about joins, NULLs, duplicates and window functions; ask for the schema if it is missing."
        case .followup: rules += "\n- This is a follow-up to the previous question; answer only the probe, referencing the earlier answer briefly."
        case .correction: rules += "\n- The interviewer changed a constraint; say what changes in the approach and what stays."
        case .conceptual, .clarification, .other: break
        }
        switch control {
        case .shorter: rules += "\n- Make it shorter: one sentence and two points, no DETAIL."
        case .expand: rules += "\n- Expand the DETAIL section with a fuller explanation."
        case .explain: rules += "\n- Explain the reasoning behind each point in DETAIL in plain language."
        case .anotherExample: rules += "\n- Use a different piece of evidence than the previous answer if any is available; otherwise say so under MISSING."
        case .depth, .standard: break
        }
        if onDevice { rules += "\n- Keep the whole response under 180 words." }
        return rules + "\n\n" + AnswerBlockParser.protocolDescription
    }

    public static func userMessage(package: ContextPackage) -> String {
        var parts: [String] = []
        if let q = package.section(.question) { parts.append("Question: " + q.items.map(\.text).joined(separator: " ")) }
        if let s = package.section(.screenConstraints), !s.items.isEmpty { parts.append("Visible on the shared screen (revision \(s.items.first?.sourceRevision ?? 0)):\n" + s.items.map(\.text).joined(separator: "\n")) }
        if let e = package.section(.evidence), !e.items.isEmpty { parts.append("Candidate's confirmed evidence:\n" + e.items.map { "[\($0.label ?? "?")] \($0.text)" }.joined(separator: "\n")) }
        if let f = package.section(.personalFacts), !f.items.isEmpty { parts.append("Target role: " + f.items.map(\.text).joined(separator: "; ")) }
        if let r = package.section(.recentTurns), !r.items.isEmpty { parts.append("Recent conversation:\n" + r.items.map(\.text).joined(separator: "\n")) }
        if let s = package.section(.summary), !s.items.isEmpty { parts.append("Earlier in the interview: " + s.items.map(\.text).joined(separator: " ")) }
        return parts.joined(separator: "\n\n")
    }

    public static let classifierInstructions = """
    You label a single utterance spoken by an interviewer during a job interview.
    Reply with exactly one lowercase word from this list and nothing else: question, followup, correction, statement.
    question = a new substantive question or task, including "tell me about" and "walk me through" requests.
    followup = a short probe about the candidate's previous answer, such as "why?" or "can you elaborate?".
    correction = the interviewer changes a constraint or fact they stated earlier. statement = anything else.
    Examples:
    "Tell me about a project you are proud of." -> question
    "Walk me through your approach to caching." -> question
    "Why not use a queue there?" -> followup
    "And how did that scale?" -> followup
    "Sorry, I meant the sorted version, not unsorted." -> correction
    "Let's change that to ten thousand users." -> correction
    "Great, thanks for that." -> statement
    "Give me a second, my audio dropped." -> statement
    """

    public static let reviewInstructions = """
    You review a candidate's interview session. Using only the supplied questions and the suggestions that were shown, write exactly three lines:
    STRONGEST: <the question where the answer was best supported by evidence and why, one sentence>
    GAP: <the most important missing information or weak spot, one sentence>
    NEXT: <one concrete practice exercise for the next session, one sentence>
    """
}

// MARK: - Context building

public struct ContextInput: Sendable {
    public var question: Question
    public var screen: ScreenEvidence?
    public var evidence: [EvidenceHit]
    public var target: InterviewTarget?
    public var recentTurns: [String]
    public var summary: String?
    public init(question: Question, screen: ScreenEvidence?, evidence: [EvidenceHit], target: InterviewTarget?, recentTurns: [String], summary: String?) {
        self.question = question; self.screen = screen; self.evidence = evidence; self.target = target; self.recentTurns = recentTurns; self.summary = summary
    }
}

/// Bounded context assembly with provenance (§6.4 ContextBuilder, §9.4).
public enum ContextBuilder {
    public static func build(_ input: ContextInput, budgetTokens: Int, instructions: String) throws -> ContextPackage {
        var sections: [ContextSection] = [
            ContextSection(kind: .instructions, items: [ContextItem(text: instructions)]),
            ContextSection(kind: .question, items: [ContextItem(text: "(\(input.question.kind.label)) " + input.question.text, sourceID: input.question.id, sourceRevision: input.question.revision)]),
        ]
        if let screen = input.screen, !screen.text.isEmpty {
            let clipped = String(screen.text.prefix(4_000))
            sections.append(ContextSection(kind: .screenConstraints, items: [ContextItem(text: clipped, sourceID: screen.id, sourceRevision: screen.revision)]))
        }
        if !input.evidence.isEmpty {
            sections.append(ContextSection(kind: .evidence, items: input.evidence.map { ContextItem(text: $0.ref.text, sourceID: $0.ref.id, label: $0.ref.label, score: $0.score) }))
        }
        if let t = input.target {
            sections.append(ContextSection(kind: .personalFacts, items: [ContextItem(text: "\(t.role) at \(t.company), \(t.seniority.rawValue) level, \(t.stage.rawValue) stage", score: 1)]))
        }
        if !input.recentTurns.isEmpty {
            sections.append(ContextSection(kind: .recentTurns, items: input.recentTurns.map { ContextItem(text: $0) }))
        }
        if let s = input.summary, !s.isEmpty { sections.append(ContextSection(kind: .summary, items: [ContextItem(text: s)])) }
        return try ContextBudgeter(budgetTokens: budgetTokens).build(sections)
    }
}

// MARK: - Question detection

public struct DetectedQuestion: Sendable, Equatable {
    public var utterance: UtteranceKind
    public var kind: QuestionKind
    public var confidence: Double
    public var usedOnDevice: Bool
}

/// Rules first, on-device classifier when rules are unsure (F16). The on-device call is bounded to 700 ms.
public final class QuestionDetector: @unchecked Sendable {
    private let onDevice: OnDeviceProvider?
    private let telemetry: TelemetrySink
    public var minimumConfidenceForAutoAnswer = 0.7

    public init(onDevice: OnDeviceProvider?, telemetry: TelemetrySink) { self.onDevice = onDevice; self.telemetry = telemetry }

    public func detect(_ text: String, previousQuestionExists: Bool, screenLooksLikeCode: Bool) async -> DetectedQuestion {
        let verdict = QuestionRuleClassifier.classify(text, previousQuestionExists: previousQuestionExists)
        var utterance = verdict.kind
        var confidence = verdict.confidence
        var usedOnDevice = false
        if confidence < 0.8, let onDevice, Tokenizer.words(text).count >= 3 {
            let request = ReasoningRequest(model: OnDeviceProvider.model, messages: [ChatMessage(role: .system, content: PromptLibrary.classifierInstructions), ChatMessage(role: .user, content: text)], maxOutputTokens: 4, temperature: 0, deadline: 0.7)
            let start = Date()
            let result: String? = await withTaskGroup(of: String?.self) { group in
                group.addTask {
                    var out = ""
                    do { for try await e in onDevice.stream(request) { if case .delta(let d) = e { out += d } } } catch { return nil }
                    return out
                }
                group.addTask { try? await Task.sleep(nanoseconds: 700_000_000); return nil }
                let first = await group.next() ?? nil
                group.cancelAll()
                return first
            }
            if let word = result?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)), let k = UtteranceKind(rawValue: word) {
                usedOnDevice = true
                if k != utterance { utterance = k; confidence = 0.75 } else { confidence = max(confidence, 0.85) }
            }
            telemetry.record(TelemetryEvent(name: "question.classified", category: "detection", durationMs: Date().timeIntervalSince(start) * 1000, attributes: ["on_device": usedOnDevice ? "yes" : "no", "kind": utterance.rawValue]))
        }
        let kind = QuestionTypeClassifier.kind(for: text, screenLooksLikeCode: screenLooksLikeCode, utterance: utterance)
        return DetectedQuestion(utterance: utterance, kind: kind, confidence: confidence, usedOnDevice: usedOnDevice)
    }
}

// MARK: - Answer generation

public struct AnswerRequest: Sendable {
    public var question: Question
    public var screen: ScreenEvidence?
    public var target: InterviewTarget?
    public var recentTurns: [String]
    public var summary: String?
    public var control: AnswerControl
    public var correctionNote: String?
    public var stamp: GenerationStamp
    public init(question: Question, screen: ScreenEvidence?, target: InterviewTarget?, recentTurns: [String], summary: String?, control: AnswerControl, correctionNote: String?, stamp: GenerationStamp) {
        self.question = question; self.screen = screen; self.target = target; self.recentTurns = recentTurns; self.summary = summary; self.control = control; self.correctionNote = correctionNote; self.stamp = stamp
    }
}

public struct AnswerOutcome: Sendable {
    public var suggestion: Suggestion
    public var run: ModelRun?
    public var routing: RoutingDecision
    public var package: ContextPackage
}

/// Runs the §9.1 pipeline for one question: retrieve, build context, route, stream, verify blocks before
/// publishing, and only publish while the generation stamp is current.
public final class AnswerOrchestrator: @unchecked Sendable {
    public let index: EvidenceIndex
    public let executor: ReasoningExecutor
    public let cloud: ReasoningProvider?
    public let onDevice: OnDeviceProvider?
    public let configuration: ReasoningConfiguration
    public let telemetry: TelemetrySink
    private var activeRequestIDs: [EntityID: EntityID] = [:]   // suggestion → request
    private let lock = NSLock()

    public init(index: EvidenceIndex, executor: ReasoningExecutor, cloud: ReasoningProvider?, onDevice: OnDeviceProvider?, configuration: ReasoningConfiguration, telemetry: TelemetrySink) {
        self.index = index; self.executor = executor; self.cloud = cloud; self.onDevice = onDevice; self.configuration = configuration; self.telemetry = telemetry
    }

    public func route(for request: AnswerRequest, processingMode: ProcessingMode, offline: Bool) async -> RoutingDecision {
        var cloudOpen = true
        if let cloud { cloudOpen = await executor.breaker.isOpen(cloud.id) }
        let input = RoutingInput(questionKind: request.question.kind, processingMode: processingMode, depthRequested: request.control == .depth,
                                 cloudConfigured: cloud != nil, cloudCircuitOpen: cloud == nil ? true : cloudOpen,
                                 onDeviceAvailable: onDevice != nil && OnDeviceProvider.availability().available,
                                 budgetExhausted: await executor.ledger.isExhausted,
                                 strongTurnsRemaining: await executor.ledger.canUseStrongRoute ? 1 : 0, offline: offline)
        return ProviderRouter.decide(input)
    }

    /// `isCurrent` is consulted before every published block; `publish` receives verified blocks and the evolving suggestion.
    public func generate(_ request: AnswerRequest, sessionID: EntityID, processingMode: ProcessingMode, offline: Bool,
                         isCurrent: @escaping @Sendable () -> Bool,
                         publish: @escaping @Sendable (Suggestion) -> Void) async throws -> AnswerOutcome {
        let routing = await route(for: request, processingMode: processingMode, offline: offline)
        guard routing.route != .none else { throw AssistantError.unsupportedCapability("no reasoning route available (\(routing.reason))") }
        let provider: ReasoningProvider
        let model: String
        switch routing.route {
        case .onDevice: guard let onDevice else { throw AssistantError.unsupportedCapability("on-device model") }; provider = onDevice; model = OnDeviceProvider.model
        case .routineCloud: guard let cloud else { throw AssistantError.unsupportedCapability("cloud provider") }; provider = cloud; model = configuration.routineModel
        case .strongCloud: guard let cloud else { throw AssistantError.unsupportedCapability("cloud provider") }; provider = cloud; model = configuration.strongModel
        case .none: throw AssistantError.unsupportedCapability("route")
        }
        let onDeviceRoute = routing.route == .onDevice
        let hits = index.retrieve(question: request.question.text, kind: request.question.kind, limit: onDeviceRoute ? 2 : 4)
        let instructions = PromptLibrary.system(kind: request.question.kind, control: request.control, onDevice: onDeviceRoute)
        let package = try ContextBuilder.build(ContextInput(question: request.question, screen: request.screen, evidence: hits, target: request.target, recentTurns: onDeviceRoute ? Array(request.recentTurns.suffix(2)) : request.recentTurns, summary: request.summary),
                                               budgetTokens: onDeviceRoute ? 2_200 : configuration.contextBudgetTokens, instructions: instructions)
        var user = PromptLibrary.userMessage(package: package)
        if let note = request.correctionNote, !note.isEmpty { user += "\n\nCorrection from the candidate: \(note)" }
        let reasoningRequest = ReasoningRequest(model: model, messages: [ChatMessage(role: .system, content: instructions), ChatMessage(role: .user, content: user)],
                                                maxOutputTokens: routing.route == .strongCloud ? 1_400 : (onDeviceRoute ? 260 : 700), temperature: 0.3, deadline: configuration.requestTimeoutSeconds)
        let verifier = GroundingVerifier(evidence: hits.map(\.ref))
        var suggestion = Suggestion(questionID: request.question.id, questionRevision: request.question.revision, route: routing.route)
        lock.lock(); activeRequestIDs[suggestion.id] = reasoningRequest.id; lock.unlock()
        defer { lock.lock(); activeRequestIDs[suggestion.id] = nil; lock.unlock() }

        let state = BlockState()
        let run = try await executor.execute(reasoningRequest, provider: provider, route: routing.route, sessionID: sessionID) { event in
            guard case .delta(let delta) = event else { return }
            let blocks = state.consume(delta)
            guard !blocks.isEmpty, isCurrent() else { return }
            var current = state.suggestion ?? suggestion
            Self.apply(blocks, verifier: verifier, package: package, to: &current)
            state.suggestion = current
            publish(current)
        }
        let tail = state.finish()
        var final = state.suggestion ?? suggestion
        if !tail.isEmpty { Self.apply(tail, verifier: verifier, package: package, to: &final) }
        final.modelRunID = run.id
        final.completed = true
        final.verificationStatus = Self.overallStatus(final)
        suggestion = final
        if isCurrent() { publish(final) }
        telemetry.record(TelemetryEvent(name: "answer.completed", category: "answer", durationMs: run.totalMs, attributes: ["route": routing.route.rawValue, "points": String(final.keyPoints.count), "missing": String(final.missingInformation.count), "tokens_in": String(run.inputTokens)]))
        return AnswerOutcome(suggestion: final, run: run, routing: routing, package: package)
    }

    public func cancel(suggestionID: EntityID) async {
        lock.lock(); let requestID = activeRequestIDs[suggestionID]; lock.unlock()
        guard let requestID else { return }
        await cloud?.cancel(requestID: requestID)
        await onDevice?.cancel(requestID: requestID)
    }

    static func apply(_ blocks: [AnswerBlock], verifier: GroundingVerifier, package: ContextPackage, to suggestion: inout Suggestion) {
        for block in blocks {
            switch verifier.verify(block) {
            case .publish(let b, let ids, let status):
                switch b.kind {
                case .short: suggestion.shortAnswer = b.text
                case .point: suggestion.keyPoints.append(KeyPoint(text: b.text, evidenceIDs: ids, status: status))
                case .assume: suggestion.assumptions.append(b.text)
                case .missing: suggestion.missingInformation.append(b.text)
                case .clarify: suggestion.missingInformation.append("Ask: " + b.text)
                case .detail: suggestion.optionalDetail = (suggestion.optionalDetail.map { $0 + "\n" } ?? "") + b.text
                }
            case .rewritten(let b, _):
                suggestion.missingInformation.append(b.text)
            case .suppressed:
                break
            }
        }
    }

    static func overallStatus(_ s: Suggestion) -> VerificationStatus {
        if s.keyPoints.contains(where: { $0.status == .supported }) { return .supported }
        if s.keyPoints.contains(where: { $0.status == .needsConfirmation }) || !s.missingInformation.isEmpty { return .needsConfirmation }
        if (s.optionalDetail ?? "").contains("```") { return .unexecuted }
        return .generalExplanation
    }
}

final class BlockState: @unchecked Sendable {
    private let lock = NSLock()
    private var parser = AnswerBlockParser()
    private var current: Suggestion?
    var suggestion: Suggestion? {
        get { lock.lock(); defer { lock.unlock() }; return current }
        set { lock.lock(); current = newValue; lock.unlock() }
    }
    func consume(_ delta: String) -> [AnswerBlock] { lock.lock(); defer { lock.unlock() }; return parser.consume(delta) }
    func finish() -> [AnswerBlock] { lock.lock(); defer { lock.unlock() }; return parser.finish() }
}

// MARK: - Review (§5.4) and mock interviews (F61)

public struct SessionReview: Codable, Sendable, Equatable {
    public var strongest: String
    public var gap: String
    public var next: String
    public var generatedBy: RouteKind
}

public enum ReviewBuilder {
    /// Deterministic review that never needs a model; a model can refine it.
    public static func heuristic(questions: [Question], suggestions: [Suggestion]) -> SessionReview {
        let byQuestion = Dictionary(grouping: suggestions, by: \.questionID)
        var strongest = "No suggestion was supported by confirmed evidence this session."
        var gap = "No gaps recorded."
        var next = "Run a short mock on one behavioral and one coding question."
        if let best = suggestions.filter({ $0.verificationStatus == .supported }).max(by: { $0.keyPoints.filter { $0.status == .supported }.count < $1.keyPoints.filter { $0.status == .supported }.count }),
           let q = questions.first(where: { $0.id == best.questionID }) {
            strongest = "Best supported: \"\(q.text.prefix(90))\" — \(best.keyPoints.filter { $0.status == .supported }.count) point(s) rested on your confirmed evidence."
        }
        let missing = suggestions.flatMap(\.missingInformation)
        if let first = missing.first {
            gap = "Most important gap: \(first.prefix(140)). \(missing.count) item(s) needed your confirmation."
            next = "Add a story or claim that covers that gap, then rehearse the same question unaided."
        }
        if questions.contains(where: { $0.kind == .coding }) && byQuestion.values.contains(where: { $0.contains { ($0.optionalDetail ?? "").contains("```") } }) {
            next += " Also run the unexecuted code sketch yourself before trusting it."
        }
        return SessionReview(strongest: strongest, gap: gap, next: next, generatedBy: .none)
    }
}

public struct MockQuestion: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var kind: QuestionKind
    public var text: String
    public var rubric: [String]
    public var tags: [String]
}

/// Original question bank (F72 start). No third-party question sets.
public enum MockQuestionBank {
    public static let questions: [MockQuestion] = [
        MockQuestion(id: "b1", kind: .behavioral, text: "Tell me about a time you had to debug a production incident under pressure.", rubric: ["situation stated", "your own actions", "outcome and what you changed afterwards"], tags: ["incident", "ownership"]),
        MockQuestion(id: "b2", kind: .behavioral, text: "Describe a situation where you disagreed with a technical decision. What did you do?", rubric: ["clear disagreement", "how you argued it", "how it was resolved"], tags: ["communication"]),
        MockQuestion(id: "b3", kind: .behavioral, text: "Tell me about a project where the requirements changed late. How did you handle it?", rubric: ["what changed", "prioritisation", "result"], tags: ["ambiguity"]),
        MockQuestion(id: "c1", kind: .coding, text: "Given an unsorted stream of integers and limited memory, how would you detect duplicates? Discuss trade-offs.", rubric: ["restates constraints", "hash set vs Bloom filter", "complexity", "edge cases"], tags: ["streams", "hashing"]),
        MockQuestion(id: "c2", kind: .coding, text: "How would you find the k most frequent words in a large log file that does not fit in memory?", rubric: ["chunking or hashing", "heap of size k", "complexity"], tags: ["external memory", "heaps"]),
        MockQuestion(id: "s1", kind: .systemDesign, text: "Design a URL shortener that handles one billion requests per day.", rubric: ["requirements and scale", "key generation", "storage and caching", "availability"], tags: ["caching", "storage"]),
        MockQuestion(id: "s2", kind: .systemDesign, text: "Design a notification system that must deliver each message at least once across email, SMS and push.", rubric: ["queueing", "idempotency", "retries and dead letters", "fan-out"], tags: ["queues", "idempotency"]),
        MockQuestion(id: "d1", kind: .debugging, text: "An API endpoint's p99 latency doubled after a deploy but p50 is unchanged. How do you investigate?", rubric: ["hypotheses", "discriminating measurements", "rollback decision"], tags: ["latency", "observability"]),
        MockQuestion(id: "q1", kind: .sql, text: "Given orders(id, customer_id, amount, created_at), write a query for each customer's most recent order and explain how you avoid duplicates.", rubric: ["window function or correlated subquery", "ties", "indexes"], tags: ["sql", "window functions"]),
        MockQuestion(id: "k1", kind: .conceptual, text: "Explain the difference between optimistic and pessimistic locking and when you would use each.", rubric: ["definitions", "contention trade-off", "example"], tags: ["databases"]),
    ]

    public static func pick(kinds: [QuestionKind], count: Int, seed: Int = Int(Date().timeIntervalSince1970)) -> [MockQuestion] {
        var pool = questions.filter { kinds.isEmpty || kinds.contains($0.kind) }
        var generator = SeededGenerator(seed: UInt64(seed))
        pool.shuffle(using: &generator)
        return Array(pool.prefix(count))
    }
}

struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }
    mutating func next() -> UInt64 { state &+= 0x9E3779B97F4A7C15; var z = state; z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9; z = (z ^ (z >> 27)) &* 0x94D049BB133111EB; return z ^ (z >> 31) }
}
