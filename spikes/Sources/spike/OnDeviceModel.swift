import Foundation
import FoundationModels

/// Checks the on-device Foundation Models LLM (macOS 26+) and, with --classify, times a question-detection
/// task (F16) on sample utterances. The plan's cost model assumes every classification is cloud work;
/// a free on-device classifier changes that. Plain-text output: the @Generable macro plugin is not shipped
/// with Command Line Tools, so guided generation is left for the Xcode build.
enum OnDeviceModel {
    static let samples: [(String, String)] = [
        ("Tell me about a time you had to debug a production incident under pressure.", "question"),
        ("Okay, that makes sense.", "statement"),
        ("Why that choice?", "followup"),
        ("So we're a payments company and we mostly use Go on the backend.", "statement"),
        ("How would you design a URL shortener that handles one billion requests per day?", "question"),
        ("Actually, make that one billion rows, not one million.", "correction"),
        ("Can you give me an example of that?", "followup"),
        ("Let me share my screen for a second.", "statement"),
        ("What's the time complexity, and can you do better?", "question"),
        ("Hmm.", "statement"),
    ]

    /// Short-first answer draft (F37) from the on-device model, grounded in two supplied facts, to size the
    /// fully-local reasoning tier (decision register item 6). Timing and rough tokens/s only; no quality claim.
    static func draft(model: SystemLanguageModel) async throws {
        let session = LanguageModelSession(model: model, instructions: """
        You help a software engineer answer an interview question out loud. Use only the supplied facts for any
        personal claim; if the facts do not cover something, say what is missing instead of inventing it.
        Format: one opening sentence, then exactly three short bullet points, then one line starting with
        "Missing:" naming any information you did not have.
        """)
        let prompt = """
        Question: "Tell me about a time you improved the performance of a system."
        Facts the candidate has confirmed:
        1. Collapsed request fan-out on a fare-comparison screen into a single bulk entitlements REST endpoint.
        2. Tuned PostgreSQL hot paths with EXPLAIN ANALYZE and composite indexes to cut partner API latency.
        """
        session.prewarm()
        let sw = Stopwatch()
        var firstTokenMs: Double = .nan
        var text = ""
        let stream = session.streamResponse(to: prompt, options: GenerationOptions(temperature: 0.3, maximumResponseTokens: 220))
        for try await snapshot in stream {
            if firstTokenMs.isNaN { firstTokenMs = sw.ms }
            text = snapshot.content
        }
        let total = sw.ms
        let approxTokens = Double(text.count) / 4.0
        out("== on-device short-first draft ==")
        out(text)
        out("first_token_ms=\(fmt(firstTokenMs)) total_ms=\(fmt(total)) approx_tokens=\(fmt(approxTokens)) approx_tokens_per_s=\(fmt(approxTokens / max(total - firstTokenMs, 1) * 1000, 1))")
        out("")
    }

    static func run(_ args: Args) async throws {
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            out("system_language_model=available")
        case .unavailable(let reason):
            out("system_language_model=unavailable reason=\(reason)")
            switch reason {
            case .appleIntelligenceNotEnabled: out("hint: Apple Intelligence is off in System Settings; the on-device route is unavailable until the user enables it (runtime check, plan §1.2)")
            case .deviceNotEligible: out("hint: device not eligible; on-device reasoning tier unavailable")
            case .modelNotReady: out("hint: model assets still downloading; retry later")
            @unknown default: break
            }
            return
        }
        if args.has("draft") { try await draft(model: model) }
        guard args.has("classify") else { return }

        var instructions = """
        You label a single utterance spoken by an interviewer during a job interview.
        Reply with exactly one lowercase word from this list and nothing else:
        question, followup, correction, statement.
        question = a new substantive question or task, including "tell me about" and "walk me through" requests.
        followup = a short probe about the candidate's previous answer, such as "why?" or "can you elaborate?".
        correction = the interviewer changes a constraint or fact they stated earlier. statement = anything else.
        """
        if args.has("fewshot") {
            instructions += """

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
        }
        let session = LanguageModelSession(model: model, instructions: instructions)
        let warm = Stopwatch()
        session.prewarm()
        _ = try await session.respond(to: "Okay.", options: GenerationOptions(temperature: 0, maximumResponseTokens: 2))
        out("prewarm_plus_first_call_ms=\(fmt(warm.ms))")
        var correct = 0
        var latencies: [Double] = []
        out("\n| utterance | expected | got | ms |\n|---|---|---|---|")
        for (text, expected) in samples {
            let sw = Stopwatch()
            let response = try await session.respond(to: text, options: GenerationOptions(temperature: 0, maximumResponseTokens: 4))
            let ms = sw.ms
            latencies.append(ms)
            let got = response.content.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            if got == expected { correct += 1 }
            out("| \(text) | \(expected) | \(got) | \(fmt(ms)) |")
        }
        out("\naccuracy=\(correct)/\(samples.count) latency_ms p50=\(fmt(percentile(latencies, 50))) p95=\(fmt(percentile(latencies, 95))) first=\(fmt(latencies.first ?? .nan))")
        out("process_footprint_mb=\(fmt(residentFootprintMB(), 1)) (model runs out of process)")
    }
}
