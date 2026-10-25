import Foundation
import PDFKit
import InterviewCore

public struct ImportedText: Sendable, Equatable {
    public var document: ProfileDocument
    public var text: String
}

/// Document ingestion (F01, §10.1): validate type and size, extract text in-process with limits, and report
/// diagnostics instead of guessing. No macro execution, no embedded URL fetching, no OCR unless opted in.
public enum DocumentIngestion {
    public static let maxBytes = 20 * 1_024 * 1_024
    public static let maxPages = 100

    public static func importFile(at url: URL) throws -> ImportedText {
        let data = try Data(contentsOf: url)
        guard data.count <= maxBytes else { throw AssistantError.badInput("file is larger than 20 MB") }
        let hash = TextHash.sha256(data)
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "pdf":
            guard let pdf = PDFDocument(data: data) else { throw AssistantError.badInput("not a readable PDF") }
            guard !pdf.isLocked else { throw AssistantError.badInput("the PDF is encrypted; unlock it first") }
            guard pdf.pageCount <= maxPages else { throw AssistantError.badInput("PDF has more than \(maxPages) pages") }
            let text = (0..<pdf.pageCount).compactMap { pdf.page(at: $0)?.string }.joined(separator: "\n")
            var diagnostics: [String] = []
            var status: ImportStatus = .imported
            if text.trimmingCharacters(in: .whitespacesAndNewlines).count < 200 {
                diagnostics.append("very little text found; this looks like a scanned PDF. OCR is an opt-in step.")
                status = .needsOCR
            }
            let doc = ProfileDocument(filename: url.lastPathComponent, kind: .pdf, contentHash: hash, pageCount: pdf.pageCount, characterCount: text.count, status: status, diagnostics: diagnostics)
            return ImportedText(document: doc, text: text)
        case "txt", "md", "markdown", "text":
            guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { throw AssistantError.badInput("text file is not UTF-8") }
            let doc = ProfileDocument(filename: url.lastPathComponent, kind: ext == "txt" ? .plainText : .markdown, contentHash: hash, pageCount: 1, characterCount: text.count, status: .imported)
            return ImportedText(document: doc, text: text)
        case "docx":
            throw AssistantError.unsupportedCapability("DOCX import (export the résumé as PDF or text for now)")
        default:
            throw AssistantError.unsupportedCapability("\(ext.isEmpty ? "this file type" : "." + ext) import")
        }
    }
}

/// Section-aware claim proposal (F02). Produces candidates for the user to approve; nothing is "verified"
/// until the user says so. Contact lines are separated so they never become evidence.
public enum ClaimExtractor {
    static let sectionHeadings: [(String, ClaimCategory)] = [
        ("experience", .employment), ("employment", .employment), ("work history", .employment),
        ("projects", .project), ("project", .project),
        ("skills", .skill), ("technical skills", .skill), ("technologies", .skill),
        ("education", .education), ("academic", .education),
        ("achievements", .achievement), ("awards", .achievement), ("certifications", .education),
    ]

    static let dateRange = try! NSRegularExpression(pattern: #"\b((Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Sept|Oct|Nov|Dec)[a-z]*\.?\s+)?(19|20)\d\d\s*[–—-]\s*((Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Sept|Oct|Nov|Dec)[a-z]*\.?\s+)?((19|20)\d\d|Present|present|Current|current|Now|now)\b"#)
    static let maxClaimLength = 420

    static func heading(for line: String) -> ClaimCategory? {
        let trimmed = line.trimmingCharacters(in: CharacterSet(charactersIn: ": "))
        guard trimmed.count <= 40, !trimmed.contains(".") else { return nil }
        let lower = trimmed.lowercased()
        let allCaps = trimmed == trimmed.uppercased() && trimmed.rangeOfCharacter(from: .letters) != nil
        for (keyword, category) in sectionHeadings {
            let wordHit = lower == keyword || lower.hasSuffix(" " + keyword) || lower.hasPrefix(keyword + " ") || lower.contains(" " + keyword + " ")
            if wordHit && (allCaps || trimmed.split(separator: " ").count <= 3) { return category }
        }
        return nil
    }

    static func isRoleHeader(_ line: String) -> Bool {
        dateRange.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil && line.count < 170 && !line.hasSuffix(".")
    }

    public static func propose(from text: String, documentID: EntityID) -> [VerifiedClaim] {
        var claims: [VerifiedClaim] = []
        var current: ClaimCategory = .other
        var buffer = ""
        var lineIndex = 0
        var bufferStart = 0
        var bufferIsRoleHeader = false
        func flush() {
            let t = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            buffer = ""
            let wasHeader = bufferIsRoleHeader
            bufferIsRoleHeader = false
            guard t.count >= 25 else { return }
            var category = current
            if looksLikeContact(t) { category = .contact }
            else if wasHeader { category = .employment }
            else if current == .employment { category = looksLikeAchievement(t) ? .achievement : .responsibility }
            else if current == .project && looksLikeAchievement(t) { category = .achievement }
            claims.append(VerifiedClaim(documentID: documentID, text: t, category: category, sourceRange: "lines \(bufferStart + 1)-\(lineIndex)"))
        }
        for raw in text.components(separatedBy: .newlines) {
            lineIndex += 1
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flush(); continue }
            if let category = heading(for: line) { flush(); current = category; continue }
            let bullet = line.hasPrefix("•") || line.hasPrefix("-") || line.hasPrefix("–") || line.hasPrefix("◦") || line.hasPrefix("*")
            let roleHeader = isRoleHeader(line)
            let skillCategoryLine = current == .skill && line.contains(":")
            if bullet || roleHeader || skillCategoryLine || buffer.count > maxClaimLength { flush() }
            if buffer.isEmpty { bufferStart = lineIndex - 1 }
            buffer += (buffer.isEmpty ? "" : " ") + line.trimmingCharacters(in: CharacterSet(charactersIn: "•-–◦* "))
            if roleHeader { bufferIsRoleHeader = true; flush(); continue }
            if line.hasSuffix(".") || line.hasSuffix(";") { flush() }
        }
        flush()
        return claims
    }

    static func looksLikeContact(_ t: String) -> Bool {
        t.contains("@") || t.lowercased().contains("linkedin") || t.lowercased().contains("github.com") || t.range(of: #"\+?\d[\d\s-]{8,}\d"#, options: .regularExpression) != nil
    }
    static func looksLikeAchievement(_ t: String) -> Bool {
        let l = t.lowercased()
        return l.range(of: #"\d+(\.\d+)?\s*(%|x\b|ms|s\b|users|requests|qps|rps|million|billion|k\b)"#, options: .regularExpression) != nil
            || ["reduced", "cut", "improved", "increased", "saved", "grew", "shipped", "launched", "delivered"].contains { l.contains($0) }
    }
}

/// Job-description mapping (F03): quoted requirements versus inferred expectations, matched against approved evidence.
public struct RequirementMatch: Sendable, Equatable {
    public var requirement: String
    public var quoted: Bool
    public var evidence: [EntityID]
    public var covered: Bool { !evidence.isEmpty }
}

public enum JobDescriptionMapper {
    static let skillLexicon = ["python", "java", "go", "golang", "kotlin", "swift", "typescript", "javascript", "react", "node", "next.js", "flutter", "postgres", "postgresql", "mysql", "redis", "kafka", "rabbitmq", "kubernetes", "docker", "aws", "gcp", "azure", "terraform", "graphql", "rest", "grpc", "microservices", "distributed systems", "system design", "machine learning", "llm", "langgraph", "spring boot", "django", "fastapi", "ci/cd", "sql", "nosql", "mongodb", "elasticsearch", "spark", "airflow", "linux", "c++", "rust", "scala", "data structures", "algorithms", "testing", "observability", "security"]

    public static func requirements(from jobDescription: String) -> [String] {
        var out: [String] = []
        for raw in jobDescription.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: CharacterSet(charactersIn: "•-–◦* \t"))
            guard line.count >= 12, line.count <= 220 else { continue }
            let l = line.lowercased()
            if l.contains("experience") || l.contains("proficien") || l.contains("knowledge") || l.contains("familiar") || l.contains("ability") || l.contains("strong") || l.contains("must") || l.contains("required") || l.contains("you have") || l.contains("you will") || skillLexicon.contains(where: { l.contains($0) }) {
                out.append(line)
            }
        }
        return Array(NSOrderedSet(array: out)) as? [String] ?? out
    }

    public static func skills(in text: String) -> [String] {
        let l = text.lowercased()
        return skillLexicon.filter { l.contains($0) }.map { $0 }
    }

    public static func map(jobDescription: String, approvedClaims: [VerifiedClaim], stories: [Story]) -> [RequirementMatch] {
        requirements(from: jobDescription).map { requirement in
            let words = Tokenizer.contentWords(requirement)
            let hits = approvedClaims.filter { !Tokenizer.contentWords($0.text).intersection(words).isEmpty }.map(\.id)
                + stories.filter { !Tokenizer.contentWords($0.narrative + " " + $0.skillTags.joined(separator: " ")).intersection(words).isEmpty }.map(\.id)
            return RequirementMatch(requirement: requirement, quoted: true, evidence: Array(Set(hits)))
        }
    }
}
