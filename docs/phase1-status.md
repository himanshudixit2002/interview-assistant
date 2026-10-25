# Phase 1 status — private alpha build

Updated 6 October 2026. Baseline confirmed: macOS 26 or later, Apple Silicon only. Cloud route: Chinese
OpenAI-compatible providers (DeepSeek default; Qwen, Kimi, GLM, MiniMax presets).

## What is built and verified

The app is a SwiftPM package with six modules and a SwiftUI shell (`build.sh` assembles a signed `.app`).
All automated tests pass (48 tests across core, storage, reasoning, evidence and orchestration), and the
app was launched in demo mode with a scripted session and a résumé import; both flows rendered correctly.

| Module | Delivers | Plan items |
|---|---|---|
| `InterviewCore` | records, session state machine, revision/epoch gate, context budgeter, answer block protocol + parser, grounding verifier, price registry + budget ledger, rule classifiers, OCR normalization, vocabulary corrector, content-free telemetry | §5.5, §8.4, §9.1–9.4, §9.6, §11.2–11.3, §14.4, §16.6, F15–F19, F37–F42 |
| `InterviewStorage` | SQLite store with AES-GCM encrypted payloads, Keychain-held key, migrations, retention purge, full deletion job | §10.2, §13.2–13.4, F78 |
| `InterviewEvidence` | PDF/text ingestion with diagnostics, section-aware claim proposals, job-description mapping, hybrid retrieval, contradiction checker | F01–F05, F08, §10.1 |
| `InterviewMedia` | window capture by identity with region crop, accurate OCR with row reconstruction and change detection, ScreenCaptureKit and Core Audio tap audio routes, speech activity endpointing, SpeechAnalyzer fast-results transcription with gap markers | F13, F15, F22, F25–F29, F30, F33, §7, §8 |
| `InterviewReasoning` | provider presets and price table, OpenAI-compatible SSE streaming client, on-device Foundation Models provider, mock provider, router with circuit breaker, reserve/settle executor with one bounded retry | §9.5, §11.3, §16, F77, F86 |
| `InterviewOrchestration` | session coordinator (start/pause/stop, epochs, stale cancellation, reconnect, save-or-discard with countdown), question detector (rules + on-device classifier), context builder, prompt library per question type, answer orchestrator with pre-display verification, preflight, heuristic review, original mock question bank | §5.2–5.4, §6.4, §9, §14.3, F16, F61, F62, F75, F76 |
| `InterviewApp` | onboarding, profile/claims approval, story library, targets with requirement coverage, session setup + preflight, live four-region panel, compact floating panel (visible to screen share by design), review + Markdown export, mock practice with rubric, settings (provider/key/budget/retention/delete-all/diagnostics) | §5, F73, F74 (in-app shortcuts), F78–F80 |

## How to run

```bash
cd ~/Desktop/interview-assistant && ./build.sh && open "Interview Assistant.app"
```

Add a provider key under Settings › Reasoning (stored in the login Keychain). Without a key the app still
runs: captions, question detection and suggestions use the on-device model where Apple Intelligence is on.

Demo mode for UI checks without any key or network: `IA_DEMO=1 IA_DATA_DIR=/tmp/ia IA_EPHEMERAL_KEY=1`.

## Fixes after the first hands-on run (6 October 2026, evening)

- Source pickers were empty until Screen Recording was granted, so Start stayed disabled: the app now lists
  running apps through NSWorkspace and windows through the window server with no permission, shows a
  Permissions box with Grant and Relaunch buttons, and defaults to the Core Audio tap route, which needs no
  Screen Recording at all.
- The tap now follows an application's audio processes by bundle identifier (browser helpers, Electron
  helpers, Safari's WebKit GPU process) and re-resolves every three seconds, so a call that starts after
  Start, or a browser that spawns a new audio helper, is picked up without restarting.
- Pause and Resume killed the transcript stream (single-consumer AsyncStream); each start now returns its own stream.
- Practice mode no longer replaces a running live session.
- Settings › Reasoning has a "Test connection" button that sends one tiny request and reports reply, latency and cost.
- A Keychain denial no longer silently produces an unreadable database: the key falls back to a protected
  file in the data folder and the app says so; data written with another key is reported instead of hidden.
- Errors now show in a banner in the live panel with the recovery action.
- `swift run ia-selftest spikes/fixtures/q07pad.aiff` exercises the real tap → speech → detection → answer
  chain headlessly; it passed on the reference Mac (question detected 0.4 s after the final, answer 0.8 s later).

## Known limitations of this alpha

- Ad-hoc signing: after each rebuild macOS may ask once to allow Keychain access to the vault key; a stable
  signing identity (Apple Development or Developer ID) removes that.
- Not yet verified on a real video call: the audio routes and transcript were measured on played-back
  audio in Phase 0. Browser meetings play audio from helper processes; test the Core Audio tap route first.
- Cloud route untested end-to-end against a live provider (no key yet). The client follows the
  OpenAI-compatible streaming contract and is covered by parser and executor tests with a mock.
- Microphone channel (F14), DOCX and scanned-PDF import, vocabulary pack UI, global hotkeys outside the app,
  rich exports, accounts/billing/gateway, signed updates, encrypted sync and organization controls are not built.
- Review refinement by a model, adaptive hints and the research features (§19) are not started.

## Next

1. Put a DeepSeek key in Settings and run one real question through the routine and strong routes; record
   tokens, latency and cost in the usage ledger (plan Day 7).
2. Run a real Meet/Zoom call with the compact panel: source selection, AirPods reconnect, a display change,
   and a 60-minute soak (plan Days 3 and 9).
3. Decide a signing identity; then notarization and a staged update channel (Phase 2 hardening).
