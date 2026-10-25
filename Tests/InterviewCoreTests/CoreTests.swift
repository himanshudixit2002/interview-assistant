import Testing
import Foundation
@testable import InterviewCore

@Suite("Revisions and currency")
struct RevisionTests {
    @Test func staleEpochIsRejected() {
        let q = EntityID()
        let stamp = GenerationStamp(epoch: 1, questionID: q, questionRevision: 1, screenRevision: nil)
        #expect(CurrencyGate.isCurrent(stamp, against: ActiveContext(epoch: 1, questionID: q, questionRevision: 1, screenRevision: nil)))
        #expect(!CurrencyGate.isCurrent(stamp, against: ActiveContext(epoch: 2, questionID: q, questionRevision: 1, screenRevision: nil)))
    }

    @Test func newQuestionRevisionInvalidatesOldGeneration() {
        let q = EntityID()
        let stamp = GenerationStamp(epoch: 1, questionID: q, questionRevision: 1, screenRevision: 12)
        #expect(!CurrencyGate.isCurrent(stamp, against: ActiveContext(epoch: 1, questionID: q, questionRevision: 2, screenRevision: 12)))
        #expect(!CurrencyGate.isCurrent(stamp, against: ActiveContext(epoch: 1, questionID: q, questionRevision: 1, screenRevision: 13)))
        #expect(CurrencyGate.isCurrent(stamp, against: ActiveContext(epoch: 1, questionID: q, questionRevision: 1, screenRevision: 12)))
        #expect(!CurrencyGate.isCurrent(stamp, against: ActiveContext(epoch: 1, questionID: EntityID(), questionRevision: 1, screenRevision: 12)))
    }

    @Test func clockIsMonotonic() {
        let clock = RevisionClock()
        #expect(clock.nextRevision(for: "q") == 1)
        #expect(clock.nextRevision(for: "q") == 2)
        #expect(clock.nextRevision(for: "screen") == 1)
        #expect(clock.bumpEpoch() == 1)
        #expect(clock.epoch == 1)
    }
}

@Suite("Session status")
struct SessionStatusTests {
    @Test func uiStateDerivation() {
        #expect(SessionStatus().uiState == "idle")
        #expect(SessionStatus(phase: .listening).uiState == "listening")
        #expect(SessionStatus(phase: .listening, blockers: [.permissionRequired]).uiState == "permission-required")
        #expect(SessionStatus(phase: .listening, degradations: [.budgetExhausted]).uiState == "budget-exhausted")
        #expect(SessionStatus(phase: .listening, degradations: [.localFallback]).uiState == "local-fallback")
        #expect(SessionStatus(phase: .generating, degradations: [.reconnecting]).uiState == "reconnecting")
    }

    @Test func transitions() {
        #expect(PhaseTransition.canTransition(from: .listening, to: .questionDetected))
        #expect(PhaseTransition.canTransition(from: .generating, to: .questionDetected))
        #expect(!PhaseTransition.canTransition(from: .stopped, to: .listening))
        #expect(!PhaseTransition.canTransition(from: .idle, to: .generating))
        #expect(PhaseTransition.canTransition(from: .paused, to: .stopped))
    }

    @Test func actionsFollowState() {
        #expect(SessionStatus(phase: .paused).allowedActions.contains(.resume))
        #expect(!SessionStatus(phase: .paused).allowedActions.contains(.ask))
        #expect(SessionStatus(phase: .stopped).allowedActions.contains(.saveOrDiscard))
        #expect(!SessionStatus(phase: .listening, blockers: [.permissionRequired]).allowedActions.contains(.ask))
        #expect(!SessionStatus(phase: .listening, degradations: [.budgetExhausted]).canGenerate)
    }
}

@Suite("Context budget")
struct ContextBudgetTests {
    func section(_ kind: ContextSectionKind, _ texts: [String], scores: [Double]? = nil) -> ContextSection {
        ContextSection(kind: kind, items: texts.enumerated().map { ContextItem(text: $0.element, score: scores?[$0.offset] ?? 0) })
    }

    @Test func neverDropsQuestionOrConstraints() throws {
        let filler = String(repeating: "history ", count: 400)   // ~800 tokens
        let sections = [
            section(.instructions, ["Answer briefly."]),
            section(.question, ["Detect duplicates in a stream."]),
            section(.screenConstraints, ["input is unsorted; memory limited to 100 MB"]),
            section(.recentTurns, [filler, filler, filler]),
            section(.evidence, ["claim a", "claim b"], scores: [0.9, 0.1]),
        ]
        let package = try ContextBudgeter(budgetTokens: 900).build(sections)
        #expect(package.section(.question) != nil)
        #expect(package.section(.screenConstraints)?.items.first?.text.contains("100 MB") == true)
        #expect(package.totalTokens <= 900)
        #expect((package.trimmed[.recentTurns] ?? 0) >= 2)
        #expect(package.section(.evidence)?.items.count == 2)   // evidence survives while history is trimmable
    }

    @Test func evidenceTrimsLowestScoreFirst() throws {
        let big = String(repeating: "x ", count: 300)
        let sections = [
            section(.question, ["q"]),
            section(.evidence, [big + "low", big + "high"], scores: [0.1, 0.9]),
        ]
        let package = try ContextBudgeter(budgetTokens: 200).build(sections)
        #expect(package.section(.evidence)?.items.count == 1)
        #expect(package.section(.evidence)?.items.first?.text.hasSuffix("high") == true)
    }

    @Test func oversizedQuestionIsAnError() {
        let huge = String(repeating: "constraint ", count: 2000)
        #expect(throws: (any Error).self) { try ContextBudgeter(budgetTokens: 100).build([section(.question, [huge])]) }
    }
}

@Suite("Answer protocol parser")
struct AnswerParserTests {
    @Test func parsesStreamedBlocksAcrossDeltas() {
        var parser = AnswerBlockParser()
        var blocks = parser.consume("SHORT: Use a hash set and stream the")
        #expect(blocks.isEmpty)
        blocks += parser.consume(" input.\nPOINT: One pass, O(n) time [E1, S2]\nPOI")
        #expect(blocks.count == 2)
        #expect(blocks[0] == AnswerBlock(kind: .short, text: "Use a hash set and stream the input."))
        #expect(blocks[1].kind == .point && blocks[1].evidenceLabels == ["E1", "S2"])
        blocks = parser.consume("NT: Memory is the risk\nMISSING: the exact memory limit\nDETAIL: Sketch:\n```python\nseen = set()\n```\n")
        #expect(blocks.map(\.kind) == [.point, .missing])
        let tail = parser.finish()
        #expect(tail.count == 1 && tail[0].kind == .detail && tail[0].text.contains("```python"))
    }

    @Test func lowercasePrefixesAndMissingLabelsAreTolerated() {
        var parser = AnswerBlockParser()
        let blocks = parser.consume("short: Hello there\npoint: no labels here\n")
        #expect(blocks.count == 2 && blocks[1].evidenceLabels.isEmpty)
    }
}

@Suite("Grounding verifier")
struct GroundingTests {
    let evidence = [
        EvidenceRef(label: "E1", id: EntityID(), kind: .claim, text: "Collapsed request fan-out on the fare comparison screen into a single bulk entitlements REST endpoint"),
        EvidenceRef(label: "S1", id: EntityID(), kind: .story, text: "Situation: partner API latency. Action: tuned PostgreSQL with EXPLAIN ANALYZE and composite indexes."),
    ]

    @Test func unknownCitationIsDroppedNotRendered() {
        let v = GroundingVerifier(evidence: evidence)
        if case .publish(let block, let ids, _) = v.verify(AnswerBlock(kind: .point, text: "Hash sets give O(1) lookups", evidenceLabels: ["E9"])) {
            #expect(block.evidenceLabels.isEmpty && ids.isEmpty)
        } else { Issue.record("expected publish") }
    }

    @Test func unsupportedPersonalClaimBecomesMissingInformation() {
        let v = GroundingVerifier(evidence: evidence)
        let verdict = v.verify(AnswerBlock(kind: .point, text: "I led the payments migration and cut latency by 40%", evidenceLabels: []))
        guard case .rewritten(let block, _) = verdict else { Issue.record("expected rewrite"); return }
        #expect(block.kind == .missing)
        #expect(block.text.contains("Confirm before saying this"))
    }

    @Test func supportedPersonalClaimPublishesWithEvidence() {
        let v = GroundingVerifier(evidence: evidence)
        let verdict = v.verify(AnswerBlock(kind: .point, text: "I collapsed the request fan-out into one bulk entitlements endpoint", evidenceLabels: ["E1"]))
        guard case .publish(_, let ids, let status) = verdict else { Issue.record("expected publish"); return }
        #expect(ids == [evidence[0].id] && status == .supported)
    }

    @Test func citedEvidenceMustActuallySupportTheClaim() {
        let v = GroundingVerifier(evidence: evidence)
        let verdict = v.verify(AnswerBlock(kind: .point, text: "I managed a team of 12 engineers at Cleartrip", evidenceLabels: ["S1"]))
        guard case .rewritten(_, let reason) = verdict else { Issue.record("expected rewrite"); return }
        #expect(reason.contains("does not support"))
    }

    @Test func generalExplanationIsNotAPersonalClaim() {
        #expect(!GroundingVerifier.isPersonalClaim("A hash set gives O(1) average lookups and uses O(n) memory"))
        #expect(GroundingVerifier.isPersonalClaim("I built the ingestion pipeline"))
        #expect(GroundingVerifier.isPersonalClaim("We reduced p99 latency by 35%"))
        #expect(GroundingVerifier.isPersonalClaim("I did something similar when I collapsed request fan-out into a single bulk endpoint"))
        #expect(GroundingVerifier.isPersonalClaim("I used Kafka at my last job for the event pipeline"))
        #expect(!GroundingVerifier.isPersonalClaim("I'd stream the input through a hash set and report each duplicate"))
        #expect(!GroundingVerifier.isPersonalClaim("I would confirm the memory limit before choosing the structure"))
        #expect(!GroundingVerifier.isPersonalClaim("We need to check whether the input can be sorted in place"))
    }
}

@Suite("Pricing and budget")
struct BudgetTests {
    @Test func costMatchesPlanExample() {
        let routine = ModelPrice(provider: "x", model: "r", inputPerMillion: 0.10, outputPerMillion: 0.50, verifiedOn: "t")
        let perTurn = CostMath.cost(inputTokens: 6_000, outputTokens: 500, price: routine)
        #expect(abs(perTurn * 20 - 0.0170) < 1e-9)
        let planned = CostMath.plannedSessionCost(speechCost: 0.2880, reasoningCost: 0.1490)
        #expect(abs(planned - 0.6044) < 1e-9)
    }

    @Test func reservationFailsClosedAndSettles() async throws {
        let ledger = BudgetLedger(capUSD: 0.10, strongTurnAllowance: 1)
        let t1 = try await ledger.reserve(estimateUSD: 0.06, sessionID: nil, runID: nil, reason: "routine", idempotencyKey: "a")
        await #expect(throws: (any Error).self) { try await ledger.reserve(estimateUSD: 0.06, sessionID: nil, runID: nil, reason: "routine", idempotencyKey: "b") }
        await #expect(throws: (any Error).self) { try await ledger.reserve(estimateUSD: 0.01, sessionID: nil, runID: nil, reason: "dup", idempotencyKey: "a") }
        await ledger.settle(t1, actualUSD: 0.02, route: .strongCloud)
        let snap = await ledger.snapshot()
        #expect(abs(snap.settledUSD - 0.02) < 1e-9 && abs(snap.reservedUSD) < 1e-9)
        #expect(await ledger.canUseStrongRoute == false)
        let t2 = try await ledger.reserve(estimateUSD: 0.07, sessionID: nil, runID: nil, reason: "routine", idempotencyKey: "c")
        await ledger.release(t2)
        #expect(abs(await ledger.remainingUSD - 0.08) < 1e-9)
    }
}

@Suite("Question rules")
struct QuestionRuleTests {
    @Test func classifiesCommonUtterances() {
        func k(_ s: String, prev: Bool = true) -> UtteranceKind { QuestionRuleClassifier.classify(s, previousQuestionExists: prev).kind }
        #expect(k("Tell me about a time you had to debug a production incident under pressure.", prev: false) == .question)
        #expect(k("How would you design a URL shortener that handles one billion requests per day?") == .question)
        #expect(k("Why that choice?") == .followup)
        #expect(k("Can you give me an example of that?") == .followup)
        #expect(k("Actually, make that one billion rows, not one million.") == .correction)
        #expect(k("Okay, that makes sense.") == .statement)
        #expect(k("Let me share my screen for a second.") == .statement)
        #expect(k("So we're a payments company and we mostly use Go on the backend.") == .statement)
        #expect(k("Can you hear me?") == .statement)
    }

    @Test func questionTypes() {
        #expect(QuestionTypeClassifier.kind(for: "Tell me about a time you disagreed with your team lead", screenLooksLikeCode: false, utterance: .question) == .behavioral)
        #expect(QuestionTypeClassifier.kind(for: "Design a URL shortener for one billion requests per day", screenLooksLikeCode: false, utterance: .question) == .systemDesign)
        #expect(QuestionTypeClassifier.kind(for: "What is the time complexity of your approach?", screenLooksLikeCode: true, utterance: .question) == .coding)
        #expect(QuestionTypeClassifier.kind(for: "Explain the difference between optimistic and pessimistic locking", screenLooksLikeCode: false, utterance: .question) == .conceptual)
        #expect(QuestionTypeClassifier.kind(for: "Why?", screenLooksLikeCode: false, utterance: .followup) == .followup)
    }
}

@Suite("Text normalization")
struct NormalizationTests {
    @Test func ocrAngleQuotesBecomeOperators() {
        #expect(OCRNormalizer.normalize("elif n \u{2039}= 0 or n \u{203A}= 2**31:  ") == "elif n <= 0 or n >= 2**31:")
        #expect(OCRNormalizer.looksLikeCode("def f(x):\n    return x\nprint(f(1))"))
        #expect(!OCRNormalizer.looksLikeCode("Tell me about yourself.\nWhat are your strengths?"))
    }

    @Test func vocabularyCorrectorRepairsNamesWithoutTouchingPlainWords() {
        let c = VocabularyCorrector(terms: ["Cleartrip", "Kubernetes pod", "idempotent", "RabbitMQ", "team lead", "Postgres"])
        #expect(c.correct("At KeyTrip, how did you handle schema migrations?").text == "At Cleartrip, how did you handle schema migrations?")
        #expect(c.correct("What happens when a Kubernet spot exceeds its memory limit?").text == "What happens when a Kubernetes pod exceeds its memory limit?")
        #expect(c.correct("make this endpoint item potent.").text == "make this endpoint idempotent.")
        #expect(c.correct("Kafka over Rabbit MQ for the pipeline").text == "Kafka over RabbitMQ for the pipeline")
        #expect(c.correct("you disagreed with your team led, and").text == "you disagreed with your team lead, and")
        #expect(c.correct("The input is unsorted and memory is limited").corrections.isEmpty)
    }
}
