import Foundation
import CryptoKit

public enum TextHash {
    public static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Fixes systematic OCR substitutions seen in the Phase 0 spike without "correcting" code semantics.
public enum OCRNormalizer {
    static let replacements: [(String, String)] = [
        ("\u{2039}", "<"), ("\u{203A}", ">"),          // single angle quotes read for < >
        ("\u{00AB}", "<<"), ("\u{00BB}", ">>"),
        ("\u{201C}", "\""), ("\u{201D}", "\""), ("\u{2018}", "'"), ("\u{2019}", "'"),
        ("\u{2013}", "-"), ("\u{2014}", "-"), ("\u{2212}", "-"),
        ("\u{00A0}", " "), ("\u{2007}", " "), ("\u{202F}", " "),
        ("\u{FF08}", "("), ("\u{FF09}", ")"),
    ]

    public static func normalize(_ text: String) -> String {
        var s = text
        for (from, to) in replacements { s = s.replacingOccurrences(of: from, with: to) }
        return s.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                var l = Substring(line)
                while let last = l.last, last == " " || last == "\t" { l.removeLast() }
                return String(l)
            }
            .joined(separator: "\n")
    }

    /// Heuristic used to pick code-aware OCR settings and the coding question type.
    public static func looksLikeCode(_ text: String) -> Bool {
        let lines = text.split(separator: "\n")
        guard lines.count >= 2 else { return false }
        let indicators = ["def ", "class ", "return ", "func ", "import ", "{", "}", "();", "=>", "for (", "while ", "elif ", "SELECT ", "FROM ", "public ", "#include", "fn ", "let ", "const ", "var "]
        let hits = lines.filter { line in indicators.contains { line.contains($0) } || line.hasPrefix("    ") }.count
        return Double(hits) / Double(lines.count) >= 0.3
    }
}

public enum Tokenizer {
    public static func words(_ text: String) -> [String] {
        text.lowercased().unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
            .reduce(into: "") { $0.append($1) }
            .split(separator: " ").map(String.init)
    }

    public static let stopwords: Set<String> = [
        "a", "an", "the", "of", "to", "in", "on", "for", "and", "or", "with", "at", "by", "me", "you", "your", "about", "tell", "time",
        "when", "where", "what", "how", "have", "has", "had", "do", "did", "does", "is", "are", "was", "were", "be", "that", "this",
        "it", "as", "from", "any", "describe", "give", "example", "would", "could", "can", "we", "i", "my", "our", "us", "so", "if",
    ]

    public static func contentWords(_ text: String) -> Set<String> { Set(words(text).filter { !stopwords.contains($0) && $0.count > 2 }) }
}

public enum EditDistance {
    public static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        var cur = Array(repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            cur[0] = i
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }

    public static func similarity(_ a: String, _ b: String) -> Double {
        let x = Array(a), y = Array(b)
        let longest = max(x.count, y.count)
        guard longest > 0 else { return 1 }
        return 1 - Double(levenshtein(x, y)) / Double(longest)
    }

    public static func wordErrorRate(reference: String, hypothesis: String) -> Double {
        let r = Tokenizer.words(reference).map { Character(String($0.hashValue)) }
        let h = Tokenizer.words(hypothesis).map { Character(String($0.hashValue)) }
        guard !r.isEmpty else { return h.isEmpty ? 0 : 1 }
        return Double(levenshtein(r, h)) / Double(r.count)
    }
}

/// Post-recognition correction toward a known vocabulary (F19). Apple's contextual strings had no effect in
/// the spike, so names are repaired here: company, product, library and project terms from the target,
/// the résumé and a curated technical list.
public struct VocabularyCorrector: Sendable {
    public struct Correction: Equatable, Sendable { public let from: String; public let to: String }

    public let terms: [String]
    public let singleTokenThreshold: Double
    public let multiTokenThreshold: Double
    private let normalizedTerms: [(term: String, key: String, wordCount: Int)]

    public init(terms: [String], singleTokenThreshold: Double = 0.65, multiTokenThreshold: Double = 0.65) {
        let unique = Array(Set(terms.map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.count >= 5 })).sorted()
        self.terms = unique
        self.singleTokenThreshold = singleTokenThreshold
        self.multiTokenThreshold = multiTokenThreshold
        self.normalizedTerms = unique.map { ($0, Self.key($0), max(1, $0.split(separator: " ").count)) }
    }

    static func key(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    /// Consonant skeleton: sound-class folding, vowels dropped after the first letter, doubles collapsed.
    /// Lets "keytrip" meet "cleartrip" and "posters" meet "postgres" without loosening plain-word matching.
    static func skeleton(_ key: String) -> String {
        var out: [Character] = []
        var previous: Character? = nil
        for (i, ch) in key.enumerated() {
            var c = ch
            switch c {
            case "c", "q": c = "k"
            case "z": c = "s"
            case "v": c = "f"
            case "y": c = "i"
            default: break
            }
            if i > 0, "aeiou".contains(c) { continue }
            if c == previous { continue }
            out.append(c); previous = c
        }
        return String(out)
    }

    static func score(_ a: String, _ b: String) -> Double {
        max(EditDistance.similarity(a, b), EditDistance.similarity(skeleton(a), skeleton(b)))
    }

    public func correct(_ text: String) -> (text: String, corrections: [Correction]) {
        guard !normalizedTerms.isEmpty else { return (text, []) }
        // Split keeping punctuation attached so it can be re-attached after replacement.
        let rawTokens = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        var output: [String] = []
        var corrections: [Correction] = []
        var i = 0
        while i < rawTokens.count {
            var best: (term: String, span: Int, score: Double)? = nil
            for span in 1...min(3, rawTokens.count - i) {
                let window = rawTokens[i..<(i + span)]
                let joinedKey = Self.key(window.joined(separator: " "))
                guard joinedKey.count >= 4 else { continue }
                for entry in normalizedTerms where abs(entry.wordCount - span) <= 1 {
                    if joinedKey == entry.key {
                        if window.joined(separator: " ") != entry.term, best == nil || best!.score < 1.0 { best = (entry.term, span, 1.0) }
                        continue
                    }
                    let score = Self.score(joinedKey, entry.key)
                    let threshold = entry.wordCount > 1 || span > 1 ? multiTokenThreshold : singleTokenThreshold
                    // Require the first letters to agree in sound class so "input" never becomes "idempotent".
                    guard score >= threshold, Self.sameInitialSound(joinedKey, entry.key) else { continue }
                    if best == nil || score > best!.score { best = (entry.term, span, score) }
                }
            }
            if let best, best.score < 1.0 || rawTokens[i..<(i + best.span)].joined(separator: " ") != best.term {
                let original = rawTokens[i..<(i + best.span)].joined(separator: " ")
                let trailing = String(original.reversed().prefix { ".,?!;:".contains($0) }.reversed())
                let leading = String(original.prefix { "\"'(".contains($0) })
                output.append(leading + best.term + trailing)
                corrections.append(Correction(from: original, to: leading + best.term + trailing))
                i += best.span
            } else {
                output.append(rawTokens[i])
                i += 1
            }
        }
        return (output.joined(separator: " "), corrections)
    }

    static func sameInitialSound(_ a: String, _ b: String) -> Bool {
        guard let x = a.first, let y = b.first else { return false }
        let classes: [Set<Character>] = [["c", "k", "q"], ["s", "z"], ["f", "p"], ["i", "e", "y"], ["g", "j"]]
        if x == y { return true }
        return classes.contains { $0.contains(x) && $0.contains(y) }
    }
}
