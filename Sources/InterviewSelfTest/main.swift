import Foundation
import AVFoundation
import InterviewCore
import InterviewStorage
import InterviewEvidence
import InterviewMedia
import InterviewReasoning
import InterviewOrchestration

// End-to-end check of the real pipeline classes without the UI: tap an audio-playing process (muted at the
// speaker), transcribe locally, detect the question, and generate a suggestion through the mock provider.
// Usage: ia-selftest <audio file with a leading silence>   (run from a process that has audio-capture permission)

func stamp() -> String { let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f.string(from: Date()) }
func log(_ s: String) { print("[\(stamp())] \(s)") }

let args = CommandLine.arguments
guard args.count >= 2 else { print("usage: ia-selftest <audio-file>"); exit(2) }
let audioPath = args[1]
let seconds = Double(args.count > 2 ? args[2] : "14") ?? 14

@MainActor
func run() async -> Int32 {
    let telemetry = InMemoryTelemetry()
    let store = try! AppStore.inMemory()
    let index = EvidenceIndex(useEmbeddings: false)
    index.rebuild(claims: [VerifiedClaim(text: "Collapsed request fan-out on the fare comparison screen into a single bulk entitlements endpoint", category: .achievement, state: .approved)], stories: [])
    let executor = ReasoningExecutor(ledger: BudgetLedger(capUSD: 1), prices: PriceRegistry(version: "t", entries: [ModelPrice(provider: "mock", model: "m", inputPerMillion: 0.1, outputPerMillion: 0.5, verifiedOn: "t")]), telemetry: telemetry)
    var config = ReasoningConfiguration(providerID: "mock", baseURL: "x", routineModel: "m", strongModel: "m"); config.onDeviceEnabled = false
    let answers = AnswerOrchestrator(index: index, executor: executor, cloud: MockProvider(behaviour: .succeed(MockProvider.sampleAnswer), chunkDelayNanoseconds: 5_000_000), onDevice: nil, configuration: config, telemetry: telemetry)
    let detector = QuestionDetector(onDevice: OnDeviceProvider.availability().available ? OnDeviceProvider() : nil, telemetry: telemetry)

    // Play the fixture through afplay and tap that process (muted so nothing is audible).
    let player = Process()
    player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
    player.arguments = [audioPath]
    try! player.run()
    let pid = player.processIdentifier
    log("afplay pid \(pid) started")
    let setup = SessionSetup(target: nil, mode: .live, scope: AssistanceScope(permittedByUser: true), processingMode: .hybrid, audioSource: .processTap(pid: pid, bundleID: "", name: "afplay"), windowID: nil, vocabulary: ["Kubernetes", "Cleartrip"], autoAnswer: true, endpointPauseMs: 500)
    let coordinator = SessionCoordinator(setup: setup, store: store, telemetry: telemetry, answers: answers, detector: detector, pricePolicyVersion: "t", deviceClass: "selftest")
    coordinator.enableTestMute()
    try? await Task.sleep(nanoseconds: 300_000_000)
    await coordinator.start()
    log("status: \(coordinator.status.uiState) error: \(coordinator.lastError?.description ?? "none")")
    var lastFinals = 0, lastPartial = "", seenQuestion = false, seenSuggestion = false
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        try? await Task.sleep(nanoseconds: 200_000_000)
        if coordinator.finals.count != lastFinals { lastFinals = coordinator.finals.count; log("final: \(coordinator.finals.last?.text ?? "")") }
        if coordinator.partial != lastPartial, !coordinator.partial.isEmpty { lastPartial = coordinator.partial; log("partial: \(coordinator.partial.suffix(60))") }
        if let q = coordinator.activeQuestion, !seenQuestion { seenQuestion = true; log("QUESTION detected (\(q.kind.label)): \(q.text)  [\(coordinator.detectionNote)]") }
        if let s = coordinator.suggestion, s.completed, !seenSuggestion { seenSuggestion = true; log("SUGGESTION: \(s.shortAnswer) | points=\(s.keyPoints.count) missing=\(s.missingInformation.count) route=\(s.route.rawValue)") }
        if let e = coordinator.lastError { log("error: \(e.description)"); coordinator.clearErrorForTest() }
        if coordinator.status.phase == .answerReady && seenSuggestion && player.isRunning == false { break }
    }
    log("level peak dBFS: \(Int(coordinator.levelDbfs)) tapped processes: \(coordinator.audioProcessCount) finals: \(coordinator.finals.count) gaps: \(coordinator.gapCount)")
    coordinator.stop()
    log("stopped; pending save: \(coordinator.pendingSave != nil)")
    if player.isRunning { player.terminate() }
    let ok = seenQuestion && seenSuggestion && coordinator.finals.count >= 1
    print(ok ? "SELFTEST PASS" : "SELFTEST FAIL")
    return ok ? 0 : 1
}

let code = await run()
exit(code)
