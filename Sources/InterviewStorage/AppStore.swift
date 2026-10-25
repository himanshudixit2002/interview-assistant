import Foundation
import InterviewCore

enum Migrations {
    static let tables: [(name: String, extra: String)] = [
        ("documents", "status TEXT"),
        ("claims", "document_id TEXT, state TEXT, category TEXT"),
        ("stories", ""),
        ("targets", ""),
        ("sessions", "target_id TEXT, mode TEXT, started_at REAL, ended_at REAL"),
        ("transcript_segments", "session_id TEXT, start REAL"),
        ("screen_evidence", "session_id TEXT, revision INTEGER"),
        ("questions", "session_id TEXT"),
        ("suggestions", "session_id TEXT, question_id TEXT"),
        ("model_runs", "session_id TEXT"),
        ("usage_entries", "session_id TEXT"),
        ("deletion_jobs", ""),
    ]

    static func apply(_ db: SQLiteDatabase) throws {
        try db.transaction {
            if db.userVersion < 1 {
                for t in tables {
                    let extra = t.extra.isEmpty ? "" : ", " + t.extra
                    try db.exec("CREATE TABLE IF NOT EXISTS \(t.name) (id TEXT PRIMARY KEY, payload BLOB NOT NULL, created_at REAL NOT NULL, updated_at REAL NOT NULL\(extra))")
                }
                try db.exec("CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, payload BLOB NOT NULL, updated_at REAL NOT NULL)")
                try db.exec("CREATE INDEX IF NOT EXISTS idx_claims_doc ON claims(document_id)")
                try db.exec("CREATE INDEX IF NOT EXISTS idx_segments_session ON transcript_segments(session_id, start)")
                try db.exec("CREATE INDEX IF NOT EXISTS idx_evidence_session ON screen_evidence(session_id, revision)")
                try db.exec("CREATE INDEX IF NOT EXISTS idx_questions_session ON questions(session_id)")
                try db.exec("CREATE INDEX IF NOT EXISTS idx_suggestions_session ON suggestions(session_id)")
                try db.exec("CREATE INDEX IF NOT EXISTS idx_sessions_started ON sessions(started_at)")
                db.userVersion = 1
            }
        }
    }
}

/// Encrypted record store. Every payload is sealed with the vault key; only identifiers, timestamps and
/// coarse state live in plaintext columns for indexing. Search happens in memory, so there is no plaintext
/// shadow copy on disk (plan §9.4, §13.2).
public final class AppStore: @unchecked Sendable {
    public let db: SQLiteDatabase
    public let vault: DataVault

    public init(db: SQLiteDatabase, vault: DataVault) throws {
        self.db = db; self.vault = vault
        try Migrations.apply(db)
    }

    public static func onDisk(directory: URL, keychain: KeychainStore) throws -> AppStore {
        let db = try SQLiteDatabase(path: directory.appendingPathComponent("assistant.sqlite").path)
        return try AppStore(db: db, vault: DataVault(key: try keychain.vaultKey()))
    }

    public static func inMemory() throws -> AppStore { try AppStore(db: try SQLiteDatabase(path: ":memory:"), vault: .ephemeral()) }

    /// True when rows exist that the current key cannot open (wrong vault key after a Keychain denial).
    public var cannotDecryptExistingData: Bool {
        for table in ["settings", "claims", "targets", "stories"] {
            let column = table == "settings" ? "payload" : "payload"
            guard let data = try? db.query("SELECT \(column) FROM \(table) LIMIT 1").first?["payload"]?.data else { continue }
            return (try? vault.open(data)) == nil
        }
        return false
    }

    // MARK: generic

    func upsert<T: Encodable>(_ table: String, id: EntityID, record: T, index: [String: SQLValue] = [:]) throws {
        let payload = try vault.seal(record)
        let now = Date().timeIntervalSince1970
        let keys = index.keys.sorted()
        let columns = ["id", "payload", "created_at", "updated_at"] + keys
        let placeholders = Array(repeating: "?", count: columns.count).joined(separator: ",")
        let values: [SQLValue] = [.text(id.raw), .blob(payload), .real(now), .real(now)] + keys.map { index[$0]! }
        let updates = (["payload", "updated_at"] + keys).map { "\($0)=excluded.\($0)" }.joined(separator: ",")
        try db.run("INSERT INTO \(table) (\(columns.joined(separator: ","))) VALUES (\(placeholders)) ON CONFLICT(id) DO UPDATE SET \(updates)", values)
    }

    func fetch<T: Decodable>(_ type: T.Type, table: String, id: EntityID) throws -> T? {
        guard let row = try db.query("SELECT payload FROM \(table) WHERE id=?", [.text(id.raw)]).first, let data = row["payload"]?.data else { return nil }
        return try vault.open(T.self, from: data)
    }

    func fetchAll<T: Decodable>(_ type: T.Type, table: String, where clause: String? = nil, params: [SQLValue] = [], orderBy: String = "created_at ASC") throws -> [T] {
        let sql = "SELECT payload FROM \(table)" + (clause.map { " WHERE \($0)" } ?? "") + " ORDER BY \(orderBy)"
        return try db.query(sql, params).compactMap { row in row["payload"]?.data.flatMap { try? vault.open(T.self, from: $0) } }
    }

    func delete(table: String, id: EntityID) throws { try db.run("DELETE FROM \(table) WHERE id=?", [.text(id.raw)]) }

    // MARK: documents and claims

    public func saveDocument(_ d: ProfileDocument) throws { try upsert("documents", id: d.id, record: d, index: ["status": .text(d.status.rawValue)]) }
    public func documents() throws -> [ProfileDocument] { try fetchAll(ProfileDocument.self, table: "documents") }
    public func deleteDocument(_ id: EntityID) throws {
        try db.transaction {
            try db.run("DELETE FROM claims WHERE document_id=?", [.text(id.raw)])
            try delete(table: "documents", id: id)
        }
    }

    public func saveClaim(_ c: VerifiedClaim) throws {
        try upsert("claims", id: c.id, record: c, index: ["document_id": c.documentID.map { .text($0.raw) } ?? .null, "state": .text(c.state.rawValue), "category": .text(c.category.rawValue)])
    }
    public func saveClaims(_ claims: [VerifiedClaim]) throws { try db.transaction { for c in claims { try saveClaim(c) } } }
    public func claims(state: ApprovalState? = nil, documentID: EntityID? = nil) throws -> [VerifiedClaim] {
        var clauses: [String] = []; var params: [SQLValue] = []
        if let state { clauses.append("state=?"); params.append(.text(state.rawValue)) }
        if let documentID { clauses.append("document_id=?"); params.append(.text(documentID.raw)) }
        return try fetchAll(VerifiedClaim.self, table: "claims", where: clauses.isEmpty ? nil : clauses.joined(separator: " AND "), params: params)
    }
    public func approvedClaims() throws -> [VerifiedClaim] { try claims(state: .approved) }
    public func deleteClaim(_ id: EntityID) throws { try delete(table: "claims", id: id) }

    // MARK: stories and targets

    public func saveStory(_ s: Story) throws { try upsert("stories", id: s.id, record: s) }
    public func stories() throws -> [Story] { try fetchAll(Story.self, table: "stories") }
    public func deleteStory(_ id: EntityID) throws { try delete(table: "stories", id: id) }

    public func saveTarget(_ t: InterviewTarget) throws { try upsert("targets", id: t.id, record: t) }
    public func targets() throws -> [InterviewTarget] { try fetchAll(InterviewTarget.self, table: "targets") }
    public func target(_ id: EntityID) throws -> InterviewTarget? { try fetch(InterviewTarget.self, table: "targets", id: id) }
    public func deleteTarget(_ id: EntityID) throws { try delete(table: "targets", id: id) }

    // MARK: sessions and dependents

    public func saveSession(_ s: Session) throws {
        try upsert("sessions", id: s.id, record: s, index: ["target_id": s.targetID.map { .text($0.raw) } ?? .null, "mode": .text(s.mode.rawValue), "started_at": .real(s.startedAt.timeIntervalSince1970), "ended_at": s.endedAt.map { .real($0.timeIntervalSince1970) } ?? .null])
    }
    public func sessions() throws -> [Session] { try fetchAll(Session.self, table: "sessions", orderBy: "started_at DESC") }
    public func session(_ id: EntityID) throws -> Session? { try fetch(Session.self, table: "sessions", id: id) }

    public func deleteSession(_ id: EntityID) throws {
        try db.transaction {
            for table in ["transcript_segments", "screen_evidence", "questions", "suggestions", "model_runs", "usage_entries"] {
                try db.run("DELETE FROM \(table) WHERE session_id=?", [.text(id.raw)])
            }
            try delete(table: "sessions", id: id)
        }
    }

    public func saveSegments(_ segments: [TranscriptSegment]) throws {
        try db.transaction { for s in segments { try upsert("transcript_segments", id: s.id, record: s, index: ["session_id": .text(s.sessionID.raw), "start": .real(s.start)]) } }
    }
    public func segments(sessionID: EntityID) throws -> [TranscriptSegment] { try fetchAll(TranscriptSegment.self, table: "transcript_segments", where: "session_id=?", params: [.text(sessionID.raw)], orderBy: "start ASC") }

    public func saveEvidence(_ e: ScreenEvidence) throws { try upsert("screen_evidence", id: e.id, record: e, index: ["session_id": .text(e.sessionID.raw), "revision": .integer(Int64(e.revision))]) }
    public func evidence(sessionID: EntityID) throws -> [ScreenEvidence] { try fetchAll(ScreenEvidence.self, table: "screen_evidence", where: "session_id=?", params: [.text(sessionID.raw)], orderBy: "revision ASC") }

    public func saveQuestion(_ q: Question) throws { try upsert("questions", id: q.id, record: q, index: ["session_id": .text(q.sessionID.raw)]) }
    public func questions(sessionID: EntityID) throws -> [Question] { try fetchAll(Question.self, table: "questions", where: "session_id=?", params: [.text(sessionID.raw)]) }

    public func saveSuggestion(_ s: Suggestion, sessionID: EntityID) throws { try upsert("suggestions", id: s.id, record: s, index: ["session_id": .text(sessionID.raw), "question_id": .text(s.questionID.raw)]) }
    public func suggestions(sessionID: EntityID) throws -> [Suggestion] { try fetchAll(Suggestion.self, table: "suggestions", where: "session_id=?", params: [.text(sessionID.raw)]) }

    public func saveRun(_ r: ModelRun) throws { try upsert("model_runs", id: r.id, record: r, index: ["session_id": r.sessionID.map { .text($0.raw) } ?? .null]) }
    public func runs(sessionID: EntityID? = nil) throws -> [ModelRun] {
        if let sessionID { return try fetchAll(ModelRun.self, table: "model_runs", where: "session_id=?", params: [.text(sessionID.raw)]) }
        return try fetchAll(ModelRun.self, table: "model_runs")
    }
    public func saveUsage(_ u: UsageEntry) throws { try upsert("usage_entries", id: u.id, record: u, index: ["session_id": u.sessionID.map { .text($0.raw) } ?? .null]) }
    public func usage(sessionID: EntityID? = nil) throws -> [UsageEntry] {
        if let sessionID { return try fetchAll(UsageEntry.self, table: "usage_entries", where: "session_id=?", params: [.text(sessionID.raw)]) }
        return try fetchAll(UsageEntry.self, table: "usage_entries")
    }

    // MARK: settings

    public func setSetting<T: Encodable>(_ key: String, _ value: T) throws {
        try db.run("INSERT INTO settings (key, payload, updated_at) VALUES (?,?,?) ON CONFLICT(key) DO UPDATE SET payload=excluded.payload, updated_at=excluded.updated_at",
                   [.text(key), .blob(try vault.seal(value)), .real(Date().timeIntervalSince1970)])
    }
    public func setting<T: Decodable>(_ type: T.Type, _ key: String) throws -> T? {
        guard let data = try db.query("SELECT payload FROM settings WHERE key=?", [.text(key)]).first?["payload"]?.data else { return nil }
        return try vault.open(T.self, from: data)
    }

    // MARK: retention and deletion (plan §13.3, §13.4)

    /// Removes saved sessions older than the retention window, with their dependents. Returns the count.
    @discardableResult
    public func purgeSessions(olderThan cutoff: Date) throws -> Int {
        let rows = try db.query("SELECT id FROM sessions WHERE started_at < ?", [.real(cutoff.timeIntervalSince1970)])
        for row in rows { if let id = row["id"]?.string { try deleteSession(EntityID(raw: id)) } }
        return rows.count
    }

    /// Full wipe: every table, VACUUM, then any extra directories (logs, caches). Partial failures are reported.
    public func deleteEverything(extraPaths: [URL] = []) -> DeletionJob {
        var job = DeletionJob(scope: "all-user-data", targets: Migrations.tables.map(\.name) + ["settings", "vacuum"] + extraPaths.map(\.path))
        for table in Migrations.tables.map(\.name) + ["settings"] {
            do { try db.exec("DELETE FROM \(table)"); job.completed.append(table) } catch { job.failures.append("\(table): \(error)") }
        }
        do { try db.exec("VACUUM"); job.completed.append("vacuum") } catch { job.failures.append("vacuum: \(error)") }
        for url in extraPaths {
            do {
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
                job.completed.append(url.path)
            } catch { job.failures.append("\(url.lastPathComponent): \(error)") }
        }
        job.finishedAt = Date()
        try? saveDeletionJob(job)
        return job
    }

    public func saveDeletionJob(_ j: DeletionJob) throws { try upsert("deletion_jobs", id: j.id, record: j) }
    public func deletionJobs() throws -> [DeletionJob] { try fetchAll(DeletionJob.self, table: "deletion_jobs") }
}
