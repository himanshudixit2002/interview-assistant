// swift-tools-version: 6.0
import PackageDescription

// Phase 0 feasibility spikes for the macOS interview assistant (see ../docs/master-plan.md §18.2, §18.9).
// Disposable by design: no app bundle, no UI, no persistence. Builds with Command Line Tools only.
let package = Package(
    name: "Phase0Spikes",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "spike",
            path: "Sources/spike",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Speech"),
                .linkedFramework("Vision"),
                .linkedFramework("FoundationModels"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("PDFKit"),
                .linkedFramework("NaturalLanguage"),
                .linkedFramework("ImageIO"),
            ]
        )
    ]
)
