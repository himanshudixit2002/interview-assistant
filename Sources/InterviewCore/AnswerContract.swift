import Foundation

public enum AnswerBlockKind: String, Codable, Sendable, CaseIterable {
    case short = "SHORT", point = "POINT", assume = "ASSUME", missing = "MISSING", detail = "DETAIL", clarify = "CLARIFY"
}

/// One streamed block of the answer protocol. Evidence labels (E1, S2…) resolve through the context package.
public struct AnswerBlock: Codable, Sendable, Equatable {
    public var kind: AnswerBlockKind
    public var text: String
    public var evidenceLabels: [String]
    public init(kind: AnswerBlockKind, text: String, evidenceLabels: [String] = []) { self.kind = kind; self.text = text; self.evidenceLabels = evidenceLabels }
}

/// The line protocol the model is asked to produce. It streams naturally and lets each block be checked
/// before display (§9.1 step 8):
///
///     SHORT: one spoken opening sentence
///     POINT: a key point [E1, S2]
///     ASSUME: an assumption made
///     MISSING: information the candidate must supply
///     CLARIFY: one high-value clarifying question (optional)
///     DETAIL: free text until the end, may contain fenced code
public struct AnswerBlockParser: Sendable {
    private var buffer = ""
    private var detailLines: [String] = []
    private var inDetail = false
    public init() {}

    public static let protocolDescription = """
    Respond ONLY with lines in this exact format, one block per line, in this order:
    SHORT: <one sentence the candidate can say first>
    POINT: <key point> [<evidence labels such as E1, S2 if the point rests on the candidate's confirmed evidence>]
    POINT: <second key point>
    POINT: <third key point>
    ASSUME: <an assumption you made, if any>
    MISSING: <information you did not have and the candidate should supply, if any>
    CLARIFY: <one clarifying question to ask the interviewer, only if missing context would change the answer>
    DETAIL: <optional deeper explanation; everything after this line is detail and may contain fenced code>
    Never state a personal achievement, metric, team size, ownership or employer fact unless it is in the supplied evidence; if it is not, put what you would need under MISSING instead of inventing it.
    """

    private static let prefixes: [(String, AnswerBlockKind)] = AnswerBlockKind.allCases.map { ("\($0.rawValue):", $0) }

    /// Feed a streamed delta; returns completed blocks.
    public mutating func consume(_ delta: String) -> [AnswerBlock] {
        buffer += delta
        var out: [AnswerBlock] = []
        while let newline = buffer.firstIndex(of: "\n") {
            let line = String(buffer[buffer.startIndex..<newline])
            buffer.removeSubrange(buffer.startIndex...newline)
            out += handle(line: line)
        }
        return out
    }

    /// Flush the remainder at end of stream.
    public mutating func finish() -> [AnswerBlock] {
        var out: [AnswerBlock] = []
        if !buffer.isEmpty { out += handle(line: buffer); buffer = "" }
        if inDetail {
            let text = detailLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { out.append(AnswerBlock(kind: .detail, text: text)) }
            detailLines = []; inDetail = false
        }
        return out
    }

    private mutating func handle(line rawLine: String) -> [AnswerBlock] {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        if let (prefix, kind) = Self.prefixes.first(where: { line.uppercased().hasPrefix($0.0) }) {
            var out: [AnswerBlock] = []
            if inDetail {
                let text = detailLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { out.append(AnswerBlock(kind: .detail, text: text)) }
                detailLines = []; inDetail = false
            }
            let body = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            if kind == .detail { inDetail = true; if !body.isEmpty { detailLines.append(body) }; return out }
            let (text, labels) = Self.splitLabels(body)
            if !text.isEmpty { out.append(AnswerBlock(kind: kind, text: text, evidenceLabels: labels)) }
            return out
        }
        if inDetail { detailLines.append(rawLine); return [] }
        if line.isEmpty { return [] }
        // Unprefixed text outside DETAIL is treated as detail so nothing is silently lost.
        inDetail = true; detailLines.append(rawLine)
        return []
    }

    static func splitLabels(_ body: String) -> (String, [String]) {
        guard let open = body.lastIndex(of: "["), let close = body.lastIndex(of: "]"), open < close, body[close...].trimmingCharacters(in: .whitespaces) == "]" else {
            return (body.trimmingCharacters(in: .whitespaces), [])
        }
        let inside = body[body.index(after: open)..<close]
        let labels = inside.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).uppercased() }.filter { !$0.isEmpty }
        let text = String(body[..<open]).trimmingCharacters(in: .whitespaces)
        return (text, labels)
    }
}
