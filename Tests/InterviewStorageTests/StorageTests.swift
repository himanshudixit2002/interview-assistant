import Testing
import Foundation
@testable import InterviewStorage
import InterviewCore

@Suite("Encrypted record store")
struct StorageTests {
    @Test func roundTripsRecordsThroughTheVault() throws {
        let store = try AppStore.inMemory()
        let doc = ProfileDocument(filename: "resume.pdf", kind: .pdf, contentHash: "abc", pageCount: 1, characterCount: 500, status: .imported)
        try store.saveDocument(doc)
        let claim = VerifiedClaim(documentID: doc.id, text: "Built the ingestion pipeline", category: .achievement, state: .approved)
        try store.saveClaim(claim)
        #expect(try store.documents().map(\.id) == [doc.id])
        #expect(try store.approvedClaims().map(\.id) == [claim.id])
        let raw = try store.db.query("SELECT payload FROM claims").first?["payload"]?.data ?? Data()
        #expect(!(String(decoding: raw, as: UTF8.self)).contains("ingestion"))
    }

    @Test func deletingADocumentCascadesToItsClaims() throws {
        let store = try AppStore.inMemory()
        let doc = ProfileDocument(filename: "a.txt", kind: .plainText, contentHash: "h", pageCount: 1, characterCount: 10, status: .imported)
        try store.saveDocument(doc)
        try store.saveClaim(VerifiedClaim(documentID: doc.id, text: "x", category: .skill))
        try store.deleteDocument(doc.id)
        #expect(try store.claims().isEmpty)
    }

    @Test func sessionRetentionPurgeRemovesDependents() throws {
        let store = try AppStore.inMemory()
        let old = Session(targetID: nil, mode: .live, startedAt: Date().addingTimeInterval(-40 * 86_400), scope: AssistanceScope(), processingMode: .hybrid, pricePolicyVersion: "v", deviceClass: "m4")
        let recent = Session(targetID: nil, mode: .live, scope: AssistanceScope(), processingMode: .hybrid, pricePolicyVersion: "v", deviceClass: "m4")
        try store.saveSession(old); try store.saveSession(recent)
        try store.saveSegments([TranscriptSegment(sessionID: old.id, stream: .remote, start: 0, end: 1, text: "old", isFinal: true)])
        try store.saveQuestion(Question(sessionID: old.id, text: "q", kind: .other, source: .audio))
        let purged = try store.purgeSessions(olderThan: Date().addingTimeInterval(-30 * 86_400))
        #expect(purged == 1)
        #expect(try store.sessions().map(\.id) == [recent.id])
        #expect(try store.segments(sessionID: old.id).isEmpty)
        #expect(try store.questions(sessionID: old.id).isEmpty)
    }

    @Test func settingsAndFullDeletion() throws {
        let store = try AppStore.inMemory()
        try store.setSetting("retention", RetentionPolicy(savedSessionDays: 7))
        #expect(try store.setting(RetentionPolicy.self, "retention")?.savedSessionDays == 7)
        try store.saveStory(Story(title: "s"))
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("ia-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let job = store.deleteEverything(extraPaths: [tmp])
        #expect(job.failures.isEmpty)
        #expect(try store.stories().isEmpty)
        #expect(try store.setting(RetentionPolicy.self, "retention") == nil)
        #expect(!FileManager.default.fileExists(atPath: tmp.path))
        #expect(try store.deletionJobs().count == 1)
    }

    @Test func vaultRejectsTamperedCiphertext() throws {
        let vault = DataVault.ephemeral()
        var sealed = try vault.seal(Data("secret".utf8))
        sealed[sealed.count - 1] ^= 0xFF
        #expect(throws: (any Error).self) { try vault.open(sealed) }
    }
}
