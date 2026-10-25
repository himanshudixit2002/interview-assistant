# Assessment of the master plan (v1.0) and recommended decisions

Written 6 October 2026 after reading the full plan and running its Phase 0 spikes on the reference Mac
(see [phase0-findings.md](phase0-findings.md)). The plan is unusually honest: targets are labeled as targets,
prices as hypotheses, and the arithmetic checks out. The recommendations below are about where it is out of
date with the platform, where it is too heavy for a founder-led start, and which decisions can be closed now.

## Verdict

Build it, on the founder-led proof-of-concept track, with three changes: raise the OS baseline to macOS 26,
drop the backend from the proof of concept (bring-your-own-key instead), and add Apple's on-device speech and
language models as first-class routes. The Phase 0 spikes show the native capture, OCR and local speech
pipeline is feasible on a 16 GB M4 today; the open risks are question-detection latency on the local engine,
technical-vocabulary accuracy, and evidence retrieval quality, all of which have workable mitigations.

## What is strong

- The assistance contract (§3) and the refusal to promise undetectability or guaranteed outcomes.
- Separation of transcription, screen analysis, answer drafting and retention as separate switches (§3.3).
- Evidence revisions and generation epochs (§8.4, §9.1, F42): the right model for a changing interview.
- The cost model is explicit, recomputable and correct (§16, §17). Every figure checked.
- Release gates are expressed as invariants (no cross-user access, no capture after stop, no duplicate billing).

## Issues and recommended changes

1. **OS baseline conflict.** §1.2 proposes macOS 15, but §7.3 correctly notes SpeechAnalyzer is macOS 26+, and
   Foundation Models (§4 does not mention it) is also 26+. Supporting 15 means a second local speech engine and
   no on-device LLM. Recommendation: macOS 26 minimum, Apple Silicon only, no Intel tier for the first year.
   By the time anything ships, 26 will be two releases old.
2. **Backend before product.** §6.3, F81 and the gateway are right for a paid product but wrong for a founder
   proof of concept. Recommendation: invert F86. Bring-your-own-key with keys in Keychain is the P0 route; the
   gateway, entitlements and usage ledger arrive in Phase 2, before anyone pays.
3. **Missing on-device reasoning tier.** The plan assumes every classification, summary and draft is cloud
   work. Measured: on-device question classification at ~320 ms with 10/10 on a small set, and a formatted
   short-first draft in ~4 s. Recommendation: add an on-device tier to the router (§9.5) for question detection,
   rolling summaries and answer structure; keep the cloud for technical correctness. The cost model gains a
   zero-marginal-cost route and the "local-only" mode (decision 6) becomes captions plus structure, honestly scoped.
4. **Latency targets versus the local engine.** First partials arrive ~1.0 s into speech in fast mode (3.9 s in
   default mode); the engine finalizes a question 0.4–1.0 s after a pause. The §14.1 partial target (p95 < 800 ms)
   is not met for the first partial. Recommendation: define the user-visible metric as "question ready ≤ 1 s
   after the interviewer stops", use fast mode plus a VAD-triggered finalize, and only add a cloud streaming
   speech route if sub-second partials prove necessary in user testing.
5. **Vocabulary pack (F19).** Apple's contextual strings had no effect in the spike. Recommendation: plan a
   post-recognition correction layer built from the target's job description, résumé and a curated tech list,
   and validate with real speakers before advertising name accuracy.
6. **Audio capture route (§7.1, §12.1).** Add the Core Audio process tap: per-process, millisecond start, no
   Screen Recording requirement, able to silence the tapped process. It is the natural captions-only route and
   the right fallback when ScreenCaptureKit's per-bundle scoping is too coarse. Test it against browser helper
   processes on a real call before relying on it.
7. **OCR assumptions (§8.2).** Vision's confidence did not flag a wrong `0` for `O` (confidence 1.00) and the
   fast level returned nothing on dark-theme code. Recommendation: accurate level only, warm the model during
   preflight (one-time ~28 s), normalize `‹ ›` to `< >`, and verify ambiguous glyphs by parsing the snippet
   rather than by confidence.
8. **Screen-share visibility of the panel is undecided.** The plan rules out concealment but never says whether
   the answer panel is excluded from screen capture (`NSWindow.sharingType = .none`), which is the mechanism
   "invisible overlay" products use. Recommendation: keep the panel capturable and say so in the product; add it
   to the decision register so it is a deliberate choice rather than an accident of implementation.
9. **P0 is too large for one person.** Roughly fifty P0 features. The plan allows declared subsets (§18.1);
   declare one now (below) so "P0" stops meaning "everything before anyone can try it".
10. **Xcode.** The reference machine has only Command Line Tools. Spikes build fine that way, but guided
    generation (`@Generable`), Instruments, signing identities and notarization need Xcode. Install it before
    Phase 1; it is free and about 15 GB.
11. **Buffer timestamps (§7.4).** Passing host-clock start times per buffer silenced the speech engine. Feed
    contiguously and keep gap markers in the transcript model instead.

## Decision register (§23), recommended resolutions

| # | Question | Recommendation |
|---|---|---|
| 1 | First audience | Software-engineering candidates, English first. The founder is the first user. |
| 2 | Team shape | Founder-led proof of concept (§17.5), cash budget for inference, one test machine and testers. |
| 3 | Funded macOS/Intel scope | macOS 26+, Apple Silicon 16 GB primary, 8 GB as a tested constrained tier, no Intel. |
| 4 | Geography, currency, region | Start where the founder's network is (India) plus US English; USD pricing; single region near the first cohort. Yours to confirm. |
| 5 | Permitted-live scenarios | Lead with mock interviews and captions; enable live suggestions only in explicitly permitted sessions. Validate demand in the §18.2 interviews before investing in live polish. |
| 6 | Local-only reasoning | Experimental: captions, question detection, structure and summaries on device; technical answers via cloud. Never claim local technical correctness. |
| 7 | Premium routing threshold | Open until the Day 7 comparison runs (needs API keys and a spend cap). |
| 8 | Retained transcripts by default | No. Agree with the plan. |
| 9 | Distribution | Developer ID + notarization (Apple Developer Program, Xcode). App Store later. |
| 10 | Rights | Own résumé, original question bank, Apple system models (no redistribution), approved public docs only. |
| 11 | Support and refunds | Decide with the first paid cohort; not needed for the proof of concept. |
| 12 | Competitor claims | Only after the §2.2 protocol; none before. |

## Proposed alpha scope (declared P0 subset)

One profile; résumé import for text PDF and plain text with fact confirmation (F01, F02); story library (F04);
one interview target with isolated context (F05); selected-window OCR with region crop and freshness stamp
(F25–F28); meeting audio via ScreenCaptureKit or process tap with a level meter (F13, F22); Apple local speech in
fast mode with transcript correction (F15, F18); question detection by rules plus the on-device classifier with
a manual Ask (F16); short-first grounded suggestions through a bring-your-own-key cloud route, with evidence
links and a "missing information" state (F37–F41); stale-answer cancellation (F42); pause/stop (F76); local notes
(F79); privacy settings and deletion (F78). Deferred until Phase 2: accounts, billing, gateway, preflight polish,
accessibility audit, signed updates, mock interviewer.

## First two weeks from here

1. Decide items 1–6 and 9 above; install Xcode.
2. Run the remaining Phase 0 days that need a person: a real Meet or Zoom call with AirPods and a display change,
   recorded real-accent samples through the fixture harness, and the cloud routine-versus-strong comparison with a
   spend cap.
3. Build the Phase 1 skeleton from the spike modules: `CaptureManager`, `AudioPipeline`, `TranscriptionService`,
   `ScreenUnderstanding` and the question/context revision model (§6.4), as a real app bundle with purpose strings.
4. Prototype the four-region answer panel (§5.3) and the correction flow before touching cloud routing.
