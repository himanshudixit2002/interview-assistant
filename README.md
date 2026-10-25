# macOS interview assistant

Native Mac interview preparation and permitted live assistance, grounded in the candidate's confirmed experience.
Planning document: [docs/master-plan.md](docs/master-plan.md) (v1.0, 6 October 2026).

Status: **Phase 1 private alpha built** (plan §18.3). Baseline: macOS 26+, Apple Silicon.

- [docs/phase1-status.md](docs/phase1-status.md): what is built, how to run it, known limitations, next steps.
- [docs/assessment.md](docs/assessment.md): review of the plan and recommended resolutions of its decision register.
- [docs/phase0-findings.md](docs/phase0-findings.md): measured results from the feasibility spikes on the reference Mac.
- [spikes/](spikes/): disposable Swift spikes from Phase 0. See `spikes/run-all.sh`.

## Building the app

```bash
./build.sh && open "Interview Assistant.app"
```

`swift test` runs the unit tests. Modules: `InterviewCore`, `InterviewStorage`, `InterviewEvidence`,
`InterviewMedia`, `InterviewReasoning`, `InterviewOrchestration`, `InterviewApp` (see `Package.swift`).

## Running the spikes

```bash
cd spikes && swift build -c release && ./run-all.sh
```

Individual commands (`./.build/release/spike` with no arguments prints the full list):

| command | what it measures |
|---|---|
| `capabilities` | permissions, ScreenCaptureKit content, speech locales/assets, OCR languages, on-device model, embeddings |
| `transcribe-set fixtures [--fast] [--vocab a,b]` | SpeechAnalyzer on synthetic questions, paced in real time: first partial, partial lag, final latency, WER |
| `transcribe-file <audio> [--fast] [--no-realtime]` | one file, verbose partial/final timeline |
| `ocr-window --render fixtures/sample_code.py --code --crop-top 32` | window capture → Vision OCR → indentation reconstruction → comparison |
| `capture-audio --app "QuickTime Player" --seconds 12 [--endpoint-ms 600]` | ScreenCaptureKit app-scoped system audio → live transcript |
| `tap-audio --pid <pid> --mute [--fast] [--endpoint-ms 600]` | Core Audio process tap (per process, can silence at the speaker) → live transcript |
| `on-device-model --classify --fewshot --draft` | Foundation Models availability, question classification, short-first draft timing |
| `evidence <resume.pdf> [--ask "question"]` | PDF ingest → claim segmentation → lexical vs on-device semantic retrieval |

Synthetic audio is generated with `say` (`fixtures/make-audio.sh`); it exercises vocabulary and latency, not real accents.
