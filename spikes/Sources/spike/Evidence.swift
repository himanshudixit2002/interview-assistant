import Foundation
import PDFKit
import NaturalLanguage

/// Day-6 spike (plan §18.9, §9.4, §10.1): extract text from a résumé PDF, split into candidate claims, and
/// compare a lexical baseline with on-device sentence embeddings for question-to-evidence retrieval.
/// Everything stays on the machine; nothing is persisted.
enum Evidence {
    struct Claim { let index: Int; let text: String; let tokens: Set<String> }

    static let defaultQuestions = [
        "Tell me about a time you improved the performance of a system.",
        "Describe a project where you worked with payments or booking flows.",
        "Have you built anything with Go or Java at scale?",
        "Tell me about a time you had to debug a production incident.",
        "What experience do you have with machine learning or AI tooling?",
        "Have you led a migration or a large refactor?",
    ]

    static func run(_ args: Args) async throws {
        guard let path = args.positional.first else { throw Transcription.usage("evidence <resume.pdf>") }
        let sw = Stopwatch()
        guard let doc = PDFDocument(url: URL(fileURLWithPath: path)) else {
            throw NSError(domain: "spike", code: 8, userInfo: [NSLocalizedDescriptionKey: "cannot open PDF (encrypted or not a PDF)"])
        }
        let text = doc.string ?? ""
        out("pages=\(doc.pageCount) chars=\(text.count) extracted_in_ms=\(fmt(sw.ms)) encrypted=\(doc.isEncrypted)")
        if text.trimmingCharacters(in: .whitespacesAndNewlines).count < 200 {
            out("very little text: likely a scanned PDF; OCR would be the opt-in path (F01)")
        }

        let claims = segment(text)
        out("candidate_claims=\(claims.count) (lines ≥ 40 chars or bullet-like; these would go to fact confirmation, F02)")
        let lengths = claims.map { Double($0.text.count) }
        out("claim_length_chars p50=\(fmt(percentile(lengths, 50))) max=\(fmt(lengths.max() ?? 0))")

        let embedding = NLEmbedding.sentenceEmbedding(for: .english)
        out("sentence_embedding=\(embedding != nil ? "available (dim \(embedding!.dimension))" : "unavailable")")
        var vectors: [[Double]] = []
        if let embedding {
            let sw2 = Stopwatch()
            vectors = claims.map { embedding.vector(for: $0.text) ?? [] }
            out("embedded \(claims.count) claims in \(fmt(sw2.ms)) ms")
        }

        let questions = args.flags["ask"].map { [$0] } ?? defaultQuestions
        for q in questions {
            out("\nQ: \(q)")
            let qTokens = Set(normalizeTokens(q).filter { !stopwords.contains($0) })
            let lexical = claims.map { c in (c, Double(c.tokens.intersection(qTokens).count) / sqrt(Double(max(c.tokens.count, 1)))) }
                .filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }.prefix(3)
            out("  lexical:")
            if lexical.isEmpty { out("    (no overlapping terms — this is the 'missing information' case, F38)") }
            for (c, s) in lexical { out("    \(fmt(s, 2))  #\(c.index) \(clip(c.text))") }
            if let embedding, let qv = embedding.vector(for: q) {
                let sem = zip(claims, vectors).compactMap { c, v -> (Claim, Double)? in
                    guard !v.isEmpty else { return nil }
                    return (c, cosine(qv, v))
                }.sorted { $0.1 > $1.1 }.prefix(3)
                out("  semantic (cosine):")
                for (c, s) in sem { out("    \(fmt(s, 2))  #\(c.index) \(clip(c.text))") }
            }
        }
        out("\nprocess_footprint_mb=\(fmt(residentFootprintMB(), 1))")
    }

    static func segment(_ text: String) -> [Claim] {
        var claims: [Claim] = []
        var buffer = ""
        func flush() {
            let t = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            buffer = ""
            guard t.count >= 40 else { return }
            claims.append(Claim(index: claims.count + 1, text: t, tokens: Set(normalizeTokens(t).filter { !stopwords.contains($0) })))
        }
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flush(); continue }
            let bulletStart = line.hasPrefix("•") || line.hasPrefix("-") || line.hasPrefix("–") || line.hasPrefix("◦")
            if bulletStart { flush() }
            buffer += (buffer.isEmpty ? "" : " ") + line.trimmingCharacters(in: CharacterSet(charactersIn: "•-–◦ "))
            // A line ending a sentence closes the claim; wrapped bullets continue.
            if line.hasSuffix(".") || line.hasSuffix(";") { flush() }
        }
        flush()
        return claims
    }

    static func cosine(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot = 0.0, na = 0.0, nb = 0.0
        for i in 0..<a.count { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        return na > 0 && nb > 0 ? dot / (sqrt(na) * sqrt(nb)) : 0
    }

    static func clip(_ s: String, _ n: Int = 110) -> String { s.count <= n ? s : String(s.prefix(n - 1)) + "…" }

    static let stopwords: Set<String> = ["a", "an", "the", "of", "to", "in", "on", "for", "and", "or", "with", "at", "by", "me", "you", "your", "about", "tell", "time", "when", "where", "what", "how", "have", "has", "had", "do", "did", "does", "is", "are", "was", "were", "be", "that", "this", "it", "as", "from", "any", "anything", "describe", "give", "example"]
}
