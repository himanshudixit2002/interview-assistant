// swift-tools-version: 6.0
import PackageDescription

// macOS interview assistant. Baseline: macOS 26, Apple Silicon. Builds with Command Line Tools (see build.sh).
let v5: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "InterviewAssistant",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "InterviewAssistant", targets: ["InterviewApp"]),
        .executable(name: "ia-selftest", targets: ["InterviewSelfTest"]),
    ],
    targets: [
        // Pure logic: records, revisions, budgets, grounding, parsing. No Apple media frameworks.
        .target(name: "InterviewCore", swiftSettings: v5),
        // SQLite persistence, encryption at rest, Keychain.
        .target(name: "InterviewStorage", dependencies: ["InterviewCore"], swiftSettings: v5,
                linkerSettings: [.linkedLibrary("sqlite3")]),
        // Document ingestion, claim proposals, retrieval.
        .target(name: "InterviewEvidence", dependencies: ["InterviewCore", "InterviewStorage"], swiftSettings: v5,
                linkerSettings: [.linkedFramework("PDFKit"), .linkedFramework("NaturalLanguage")]),
        // Screen capture, OCR, system audio, local speech.
        .target(name: "InterviewMedia", dependencies: ["InterviewCore"], swiftSettings: v5,
                linkerSettings: [.linkedFramework("ScreenCaptureKit"), .linkedFramework("Vision"), .linkedFramework("Speech"),
                                 .linkedFramework("AVFoundation"), .linkedFramework("CoreAudio"), .linkedFramework("AudioToolbox"),
                                 .linkedFramework("ImageIO")]),
        // Cloud and on-device reasoning providers, routing, usage.
        .target(name: "InterviewReasoning", dependencies: ["InterviewCore"], swiftSettings: v5,
                linkerSettings: [.linkedFramework("FoundationModels")]),
        // Session coordination: question detection, context building, answer orchestration, review.
        .target(name: "InterviewOrchestration",
                dependencies: ["InterviewCore", "InterviewStorage", "InterviewEvidence", "InterviewMedia", "InterviewReasoning"],
                swiftSettings: v5),
        .executableTarget(name: "InterviewApp",
                          dependencies: ["InterviewCore", "InterviewStorage", "InterviewEvidence", "InterviewMedia", "InterviewReasoning", "InterviewOrchestration"],
                          swiftSettings: v5,
                          linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("SwiftUI")]),
        // Headless end-to-end check of the real capture → transcript → question → answer chain.
        .executableTarget(name: "InterviewSelfTest",
                          dependencies: ["InterviewCore", "InterviewStorage", "InterviewEvidence", "InterviewMedia", "InterviewReasoning", "InterviewOrchestration"],
                          swiftSettings: v5),
        .testTarget(name: "InterviewCoreTests", dependencies: ["InterviewCore"], swiftSettings: v5),
        .testTarget(name: "InterviewReasoningTests", dependencies: ["InterviewReasoning"], swiftSettings: v5),
        .testTarget(name: "InterviewEvidenceTests", dependencies: ["InterviewEvidence"], swiftSettings: v5),
        .testTarget(name: "InterviewStorageTests", dependencies: ["InterviewStorage"], swiftSettings: v5),
        .testTarget(name: "InterviewOrchestrationTests", dependencies: ["InterviewOrchestration"], swiftSettings: v5),
    ]
)
