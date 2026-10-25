import Testing
import Foundation
@testable import InterviewEvidence
import InterviewCore

@Suite("Claim extraction")
struct ClaimExtractionTests {
    let sample = """
    JANE DOE Bengaluru, India | +91 9999999999 | jane@example.com | github.com/jane

    EXPERIENCE
    Acme Payments Bengaluru, India Software Engineer Aug 2024 – Aug 2026
    • Collapsed request fan-out on the fare comparison screen into a single bulk endpoint, cutting p95 latency by 40%.
    • Owned on-call for the booking service and wrote the runbooks.

    PROJECTS
    • Built an offline evaluation harness in Python that scripts only the model's tool choices.

    SKILLS
    Python, Go, PostgreSQL, Kafka, Kubernetes, system design and distributed systems.
    """

    @Test func separatesContactAndCategorizesSections() {
        let claims = ClaimExtractor.propose(from: sample, documentID: EntityID())
        #expect(claims.contains { $0.category == .contact && $0.text.contains("jane@example.com") })
        #expect(claims.contains { $0.category == .employment && $0.text.contains("Acme Payments") })
        #expect(claims.contains { $0.category == .achievement && $0.text.contains("40%") })
        #expect(claims.contains { $0.category == .responsibility && $0.text.contains("on-call") })
        #expect(claims.contains { $0.category == .project && $0.text.contains("evaluation harness") })
        #expect(claims.contains { $0.category == .skill && $0.text.contains("Kafka") })
        #expect(claims.allSatisfy { $0.state == .proposed })
    }

    @Test func handlesPDFTextWithoutBlankLines() {
        let pdfLike = """
        JANE DOE Bengaluru, India | +91 9999999999 | jane@example.com
        TECHNICAL SKILLS
        Backend Development: Python 3, FastAPI, Flask, REST API design, Pydantic,
        SQLAlchemy, Celery, Java, Spring Boot
        Database Management: PostgreSQL, advanced SQL, EXPLAIN ANALYZE query tuning, Redis
        PROFESSIONAL EXPERIENCE
        Acme Travel (via Staffing Co) Bengaluru, India Product Solution Engineer Aug 2025 – Aug 2026
        Cut production tickets 30% with Python (pytest) automated regression suites across booking flows,
        reconciling API responses against recorded historical results before release.
        Kept displayed prices consistent during traffic peaks by fronting the pricing service with a Redis cache.
        PROJECTS
        Inventory Platform Python, LangGraph, PostgreSQL Answered 76% of queries without a human.
        """
        let claims = ClaimExtractor.propose(from: pdfLike, documentID: EntityID())
        let skills = claims.filter { $0.category == .skill }
        #expect(skills.count == 2)
        #expect(skills.first?.text.hasPrefix("Backend Development:") == true && skills.first?.text.contains("Spring Boot") == true)
        #expect(claims.contains { $0.category == .employment && $0.text.contains("Product Solution Engineer") })
        #expect(claims.contains { $0.category == .achievement && $0.text.contains("30%") && !$0.text.contains("Redis cache") })
        #expect(claims.contains { $0.category == .responsibility && $0.text.contains("Redis cache") })
        #expect(claims.contains { ($0.category == .project || $0.category == .achievement) && $0.text.contains("Inventory Platform") })
        #expect(claims.allSatisfy { $0.text.count <= 520 })
    }

    @Test func textImportAndJobMapping() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("resume-\(UUID().uuidString).txt")
        try sample.write(to: url, atomically: true, encoding: .utf8)
        let imported = try DocumentIngestion.importFile(at: url)
        #expect(imported.document.kind == .plainText && imported.document.status == .imported)
        let jd = """
        Requirements
        - 3+ years of experience with Python or Go
        - Strong knowledge of PostgreSQL and Kafka
        - Experience operating services in Kubernetes
        - Familiarity with Rust is a plus
        """
        let approved = ClaimExtractor.propose(from: sample, documentID: imported.document.id).map { c -> VerifiedClaim in var c = c; c.state = .approved; return c }
        let matches = JobDescriptionMapper.map(jobDescription: jd, approvedClaims: approved, stories: [])
        #expect(matches.count == 4)
        #expect(matches.first { $0.requirement.contains("Kafka") }?.covered == true)
        #expect(matches.first { $0.requirement.contains("Rust") }?.covered == false)
        #expect(JobDescriptionMapper.skills(in: jd).contains("kubernetes"))
    }

    @Test func unsupportedTypesAreReported() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("x.docx")
        try? Data("x".utf8).write(to: url)
        #expect(throws: (any Error).self) { try DocumentIngestion.importFile(at: url) }
    }
}

@Suite("Retrieval")
struct RetrievalTests {
    @Test func lexicalOverlapRanksTheRightClaimFirst() {
        let index = EvidenceIndex(useEmbeddings: false)
        let claims = [
            VerifiedClaim(text: "Collapsed request fan-out on the fare comparison screen into a single bulk entitlements endpoint", category: .achievement, state: .approved),
            VerifiedClaim(text: "Tuned PostgreSQL hot paths with EXPLAIN ANALYZE and composite indexes to cut partner API latency", category: .achievement, state: .approved),
            VerifiedClaim(text: "jane@example.com +91 9999999999", category: .contact, state: .approved),
            VerifiedClaim(text: "Not approved yet claim about Kafka", category: .skill, state: .proposed),
        ]
        let story = Story(title: "Disagreement over a migration plan", skillTags: ["communication", "migration"], situation: "The team lead wanted a big-bang migration.", action: "I proposed a phased rollout with dual writes.", result: "We shipped without downtime.")
        index.rebuild(claims: claims, stories: [story])
        #expect(index.count == 3)
        let hits = index.retrieve(question: "Tell me about a time you improved API latency with PostgreSQL", kind: .behavioral)
        #expect(hits.first?.ref.text.contains("PostgreSQL") == true)
        let storyHits = index.retrieve(question: "Describe a situation where you disagreed with your team lead about a migration", kind: .behavioral)
        #expect(storyHits.first?.ref.kind == .story)
        #expect(index.retrieve(question: "What is the capital of France?", kind: .other).isEmpty)
    }

    @Test func contradictionsAreFlaggedForHumans() {
        let a = VerifiedClaim(text: "Acme Software Engineer 2024 – 2026", category: .employment)
        let b = VerifiedClaim(text: "Acme Senior Engineer 2024 – 2025", category: .employment)
        let c = VerifiedClaim(text: "We shipped the billing service and I led the design of it", category: .achievement)
        let findings = ContradictionChecker.check([a, b, c])
        #expect(findings.contains { $0.claimIDs.contains(a.id) && $0.claimIDs.contains(b.id) })
        #expect(findings.contains { $0.claimIDs == [c.id] })
    }
}
