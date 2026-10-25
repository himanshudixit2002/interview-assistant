# Phase 0 findings — feasibility spikes on the reference Mac

Measured 6 October 2026. Everything below ran on one machine with the disposable spikes in `../spikes`.
Synthetic text-to-speech stood in for the interviewer (five `say` voices, three of them Indian English), so
accuracy numbers are a vocabulary and latency smoke test, not an accent benchmark (plan §15.1). No real
video call, no cloud model and no microphone were used. Nothing left the device.

**Reference machine:** Apple M4, 16 GB, macOS 27.0.1 (26A434), 4.5K display at 2× scale. Command Line Tools
only (Swift 6.4, SDK 27.0); Xcode is not installed. This is the plan's "primary qualification tier" (§1.2).

## 1. Summary against the plan's targets

| Plan target (§14.1, §15.2) | Measured | Status |
|---|---|---|
| Partial transcription p95 < 800 ms from audio reaching the app | First partial arrives after **~3.9 s** of audio (default) or **~1.0 s** (`fastResults`); after that, partials track audio within ~20–90 ms, delivered in bursts | Not met for the first partial; met for steady state in fast mode |
| Stable question detection < 700 ms after the question ends | Engine finalizes each sentence **0.4–1.0 s** after a 1.5 s pause in fast mode (p50 ≈ 0.9 s); 1.0–3.8 s in default mode; a forced `finalize(through:)` returns in **73 ms** | Borderline; achievable with fast mode plus a VAD-triggered finalize |
| Screen freshness within 2 s | Window capture **87–110 ms**, warm OCR **134–249 ms** | Met |
| Session resident memory < 2 GB (hybrid profile) | Spike process 6–19 MB; system speech daemons **~75 MB + 27 MB** at ~8% CPU; on-device LLM runs out of process | Met with wide margin for the Apple-speech route |
| Pause stops new media promptly (p95 < 250 ms) | Stream stop + finalize **36–50 ms** | Met |
| Capture starts without prompting when already authorized | Screen Recording and microphone state readable without a prompt; ScreenCaptureKit content enumerated in **57 ms** | Met |

## 2. Speech: SpeechAnalyzer / SpeechTranscriber (macOS 26+)

Assets: English variants (including `en_IN`) were already installed; `hi_IN` is supported but not installed;
45 locales supported. Preferred input format 16 kHz mono Int16. Asset check 45–70 ms, prepare 25–125 ms.

### 2.1 Twelve questions, one fresh analyzer each, paced in real time

| Mode | First partial p50 / p95 | Partial lag p50 / p95 | Final after audio end p50 / p95 | WER |
|---|---|---|---|---|
| default (`volatileResults`) | 3934 / 3941 ms | 21 / 88 ms | 103 / 179 ms | 12.3 % (19/155) |
| `fastResults` | 1033 / 1037 ms | −76 / 21 ms | 88 / 111 ms | 12.9 % (20/155) |
| vocabulary via `setContext` | 3912 / 3956 ms | 15 / 55 ms | 73 / 109 ms | 12.3 % (identical text) |
| vocabulary via `analysisContext:` at init | 3938 / 3944 ms | 18 / 86 ms | 97 / 176 ms | 12.3 % (identical text) |

Nearly every error is a named technical entity: Kafka → "Cathco", Postgres → "infosters", Kubernetes pod →
"Kubernet spot", idempotent → "item potent", RabbitMQ → "Rabbit MQ", Cleartrip → "KeyTrip", lead → "led".
Four of the 19 counted errors are number formatting ("one billion" → "1000000000"), which is semantically fine;
excluding those the rate is about 9.7 %. **Contextual strings (`AnalysisContext.contextualStrings`) changed
nothing** in either placement, so the F19 vocabulary pack cannot rely on Apple's biasing alone.

When a whole file is fed at once instead of in real time, 11 s of audio transcribes in 120 ms (first partial
at 36 ms), so the ~3.9 s / ~1.0 s first-partial delay is a streaming cadence, not model warm-up.

### 2.2 One 68-second session, 13 sentences with 1.5 s pauses, one analyzer

- Fast mode: first partial 1026 ms; every sentence was finalized by the engine on its own, 412–998 ms after it
  ended (p50 ≈ 900 ms); 14 finals; WER 14.8 %.
- Default mode: first partial 3943 ms; finals 1.0–3.8 s after each sentence (p50 ≈ 2.1 s); WER 14.2 %.
- Accuracy in both modes is within noise of the per-utterance runs; fast mode's cost is mostly on names
  ("n log n" → "N-login", "Kafka over RabbitMQ" → "cough can overrapping MQ").

### 2.3 Live audio

Two capture routes ran simultaneously on the same QuickTime playback (4 s of silence then an 18-word question):

| | ScreenCaptureKit (`SCStream`, app-scoped) | Core Audio process tap (`CATapDescription`) |
|---|---|---|
| Start-up | stream running in 107 ms | pid → audio object 42–65 ms, tap created 3–4 ms |
| Permission | existing Screen Recording grant, no prompt | no prompt either |
| Scope | per application bundle (plan §7.1 caveat holds) | per process id, including processes without a bundle |
| Format delivered | 48 kHz mono as configured | 48 kHz stereo Float32 interleaved |
| First sound seen | within 26 ms of the other route | within 26 ms of the other route |
| Extra | delivers silence buffers continuously even before the app plays | can silence the tapped process at the speaker (`muteBehavior = .muted`, reported by the API, not verified by ear) |

Both routes produced the same transcript. Default mode delivered partials in bursts about every 4 s and finals
2.0–3.8 s late; fast mode with a 600 ms silence endpoint produced the two sentence finals **454 ms and 589 ms**
after speech ended, before the forced finalize fired. Passing a host-clock `bufferStartTime` with every buffer
silenced the engine completely (zero results); contiguous feeding without timestamps works, so gaps must be
tracked separately (plan §7.4).

## 3. Screen understanding: ScreenCaptureKit + Vision

The spike rendered `fixtures/sample_code.py` in its own non-activated window, captured that window by identity
(`SCContentFilter(desktopIndependentWindow:)`), cropped the title bar with `sourceRect` (F27), and ran
`RecognizeTextRequest` with language correction off and a few code tokens as custom words.

- Capture: 2200×1520 px at scale 2.0 in 87–110 ms. Window enumeration 57 ms.
- OCR, accurate level: **27.8 s on the first-ever run** (model load), then 134–249 ms warm. Fast level returned
  zero observations on this dark-theme monospace text and is unusable for code.
- Accuracy on 20 code lines: character error rate **2.7 %**, 12/20 lines exact. Error classes: `<=`/`>=` read as
  `‹=`/`›=` (systematic, trivially normalizable); `[` → `l` and `]` → `1` in some positions; `O = 0` read as
  `0 = 0` with confidence 1.00; `== "` dropped inside the dunder line; spurious spaces (`set ()`, `limit _mb`);
  the closing `"""` line not detected at all.
- Indentation reconstructed from bounding boxes was correct for every recognized line, and wrapped observations
  on one row were re-merged by x position (F30).
- Vision's confidence flagged nothing in the warm run, including the wrong `0`. The plan's "low confidence on
  `0` versus `O` deserves confirmation" (§8.2) needs a syntax-aware check instead; confidence alone is not a signal.

## 4. On-device Foundation Models (Apple Intelligence)

Available on this machine. Model runs out of process; in-process footprint 9 MB.

- Question classification (F16), 10 utterances, temperature 0: naive prompt 7/10; with eight few-shot examples
  **10/10**. Latency p50 318 ms, p95 366 ms. Cold first call 2.5 s; `prewarm()` plus a first call 349 ms, so
  prewarm belongs in preflight (F75).
- Short-first draft (F37) from a question plus two confirmed facts: first token 2.1 s, total 4.1 s for ~107
  tokens (~54 tokens/s). Output followed the one-sentence-plus-three-points format and emitted a "Missing:" line,
  **but the third bullet was an unsupported inference** despite instructions. Grounding must be enforced outside
  the model (§9.6); the model is suitable for structure, classification and summaries, not as the truth gate.
- `@Generable` guided generation could not be compiled: its macro plugin ships with Xcode, not Command Line Tools.

## 5. Evidence ingestion and retrieval

Run on the candidate's own one-page résumé PDF, locally.

- PDFKit text extraction: 5,154 characters in 113 ms; not encrypted.
- Naive segmentation produced 15 candidate claims, including header and contact noise; section-aware
  segmentation is required before fact confirmation (F02).
- `NLEmbedding` sentence embeddings (512-dim): 15 claims in 297 ms. Semantic retrieval found plausible
  evidence for two of six sample questions (a performance question and a payments question) and missed the
  right bullets for a debugging question and an AI-tooling question; lexical overlap was often empty, which is
  the correct "missing information" outcome (F38) rather than an invented story.
- Conclusion: on-device `NLEmbedding` alone is not good enough for question-to-evidence retrieval; use hybrid
  retrieval with a stronger embedding model or an on-device-model reranker. A vector database is still not needed
  at this scale (§9.4).

## 6. Arithmetic check of the plan

All cost, pricing, contribution and load figures in §16.3–§16.5, §17.1, §17.3 and §20.1 were recomputed and
match the document.

## 7. What this changes in the plan

1. **Baseline macOS 26 or later.** SpeechAnalyzer and Foundation Models exist only there, and the reference
   machine runs 27. Supporting macOS 15 would mean a second speech stack for no measured benefit (§1.2, §7.3).
2. **Live speech uses `fastResults`** for detection, with a VAD-triggered `finalize(through:)` around 400–500 ms
   of silence; revise the partial-latency target to "first partial ≤ 1.2 s, final ≤ 1 s after the pause", or
   plan a cloud streaming route if sub-second partials are required (§14.1).
3. **Vocabulary pack needs a post-recognition correction layer** (fuzzy match against company, library and
   product names) and validation with real speakers; Apple's contextual strings did nothing here (F19).
4. **Add the Core Audio process tap as a second audio route.** It is per-process, starts in milliseconds, and
   is the natural captions-only path with narrower permissions (§3.4, §12.1). ScreenCaptureKit remains for
   window capture and app-scoped audio. Browser meetings (Meet, Teams on web) play audio from helper processes,
   so scoping by pid versus bundle must be tested on a real call.
5. **OCR: accurate level only, warm it in preflight** (one-time ~28 s), normalize angle quotes, and verify
   ambiguous glyphs with syntax checks rather than confidence (§8.2).
6. **Add an on-device tier to the architecture and cost model** (§6.1, §9.5, §16): zero-marginal-cost question
   classification, summaries and drafting structure. It makes a local-only captions-plus-structure mode real
   (decision 6) without claiming local technical correctness.
7. **Memory target is easy** on the Apple-speech route; the 2 GB budget only matters if an in-process engine
   such as WhisperKit is adopted for macOS 15 or non-English locales.
8. **Do not pass host-clock buffer start times** to the analyzer; feed contiguously and mark gaps separately (§7.4).

## 8. Still open in Phase 0 (needs the user or spend)

- Day 3/9: a real Zoom or Meet call with AirPods reconnect, display change and a 60-minute soak (§18.9).
- Day 4: real accents and recordings; the TTS voices only prove vocabulary behaviour.
- Day 7: routine-versus-strong cloud reasoning comparison on 50–100 labeled tasks (needs API keys and a spend cap).
- Day 8: the short-answer panel prototype (design work, not a feasibility risk).
- Xcode install: required for `@Generable`, Instruments, signing identities and notarization tooling.
