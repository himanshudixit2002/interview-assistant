import Foundation

@main
struct Spike {
    static func main() async {
        let argv = Array(CommandLine.arguments.dropFirst())
        guard let command = argv.first else { usage(); exit(2) }
        let args = Args(Array(argv.dropFirst()))
        do {
            switch command {
            case "capabilities":      try await Capabilities.run(args)
            case "transcribe-file":   try await Transcription.runFile(args)
            case "transcribe-set":    try await Transcription.runSet(args)
            case "ocr-window":        try await ScreenOCR.run(args)
            case "capture-audio":     try await AudioCapture.run(args)
            case "tap-audio":         try await ProcessTap.run(args)
            case "on-device-model":   try await OnDeviceModel.run(args)
            case "evidence":          try await Evidence.run(args)
            default: usage(); exit(2)
            }
        } catch {
            log("FAILED: \(error)")
            exit(1)
        }
    }

    static func usage() {
        out("""
        spike <command> [options]

          capabilities                         runtime preflight: permissions, speech assets, on-device model, displays
          transcribe-file <audio> [--ref T]    SpeechAnalyzer on a file, paced in real time; prints partial lag + WER
                                               [--locale en-US] [--fast] [--no-realtime]
          transcribe-set <dir>                 all <id>.aiff in dir against dir/questions.txt; summary table
          ocr-window <title-substring>         ScreenCaptureKit window capture → Vision OCR
                                               [--code] [--png out.png] [--expect file]
          capture-audio [--app Name]           SCStream system audio (app-scoped if --app) → live transcript
                                               [--seconds 12] [--locale en-US] [--wav out.wav] [--all]
          tap-audio --pid P [--mute]           Core Audio process tap (per-process, can silence at speaker) → live transcript
          on-device-model                      Foundation Models availability; [--classify] runs question detection
          evidence <resume.pdf> [--ask Q]      PDFKit ingest → lexical + semantic retrieval baseline
        """)
    }
}
