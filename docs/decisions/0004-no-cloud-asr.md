# ADR-0004: No cloud ASR (Soniox / AssemblyAI / Deepgram / etc.)

- **Date:** 2026-05-24
- **Status:** Accepted
- **Deciders:** Dang Anh Tuan

## Context

Cloud ASR providers (Soniox, AssemblyAI, Deepgram, Speechmatics, Azure Speech, Google Speech-to-Text, OpenAI Whisper API, etc.) offer real-time streaming transcription with built-in speaker diarization, language identification, live translation, and 60+ language support. They're production-quality, well-documented, and would let Hark skip writing a Swift engine almost entirely.

This question recurs at every architecture discussion because the cloud option is technically tempting:

- Soniox would solve diarization + translation + multilingual *out of the box*
- WhisperKit local performance is good but not as polished
- Building the Swift engine takes weeks; integrating a cloud API takes days

So this ADR exists to **end the discussion permanently**.

## Decision

**Hark uses no cloud ASR. Ever. For any reason.** Transcription happens entirely on-device using WhisperKit (see [ADR-0003](0003-swift-whisperkit-engine.md)).

The only outbound network path for user-generated content is the explicit **Claude API** edge for summary, in-meeting Q&A, and the "high-quality" translation mode — and only when the user explicitly invokes an action. Even there, only **transcript text** crosses the boundary, never audio.

## Alternatives considered

- **Soniox** — cloud streaming ASR with built-in diarization + translation.
  - ✅ Pros: Solves 3 of the hardest engineering problems out of the box. Sub-second latency. ~60+ languages. Code-switching support.
  - ❌ Cons: Audio streams to US data centers. Closed-source model. Privacy policy is "trust us." Pay-per-audio-hour (~$0.10/hr range; ongoing cost). Internet dependency — no captions when WiFi flakes.
  - **Why rejected:** the entire reason Hark exists is "I don't trust closed-source binaries listening to my work calls." Soniox is exactly that, with an API key.

- **AssemblyAI / Deepgram / Speechmatics** — similar cloud ASR products.
  - Same evaluation as Soniox; rejected for the same reason.

- **Azure Speech / Google Speech-to-Text** — hyperscaler ASR.
  - Same evaluation; additionally raises corporate procurement concerns for the primary persona (enterprise IT often blocks third-party cloud connections by policy).

- **OpenAI Whisper API.**
  - Same evaluation. The fact that the *model* is open-source doesn't change anything — the *API* sends audio to OpenAI servers.

- **Hybrid: cloud ASR with audio scrubbing / pseudonymization before send.**
  - ✅ Pros: Could theoretically reduce sensitivity.
  - ❌ Cons: You can't pseudonymize audio. Voice is inherently identifying. PII in spoken content can't be redacted before transcription because you don't know what's PII until it's transcribed. The whole concept is incoherent.
  - **Why rejected:** doesn't actually solve the privacy problem; just dresses it up.

- **Self-hosted cloud ASR** (e.g., user runs Whisper on a server they control).
  - ✅ Pros: Privacy preserved if the user trusts their own server.
  - ❌ Cons: Requires the user to run a server. That is not the product. Different audience entirely.
  - **Why rejected:** out of scope for v1; Hark is desktop-app-local, not self-hosted-service.

## Consequences

**Positive — this decision IS the product:**
- The trust differentiator. "Audio never leaves your Mac" is the single sentence that distinguishes Hark from every competitor. Cloud ASR makes that sentence a lie.
- Removes a class of compliance objections: PDPA, GDPR, corporate Group Recording Policies, healthcare/legal privilege concerns. Users in regulated industries can use Hark where they cannot use Otter / Granola / Fireflies.
- No ongoing subscription dependency. Hark works on a plane, in a SCIF, on hotel WiFi, forever.
- No vendor lock-in. WhisperKit can be swapped for any local Whisper variant.
- Auditable: the entire transcription pipeline is open-source code on the user's machine. The `privacy-auditor` agent can verify no audio leaks.

**Negative / tradeoffs accepted:**
- More engineering work. We build the Swift engine ourselves (see [ADR-0003](0003-swift-whisperkit-engine.md)) instead of integrating a vendor SDK.
- Quality ceiling is whatever local Whisper variants achieve. Cloud providers often have proprietary models fine-tuned on more data. We accept being ~5–10% behind on WER for the trust win.
- Local diarization (FluidAudio) is less polished than Soniox's. Manual speaker tagging UX absorbs this gap (see [vault/docs/analysis/05-user-stories.md](~/Documents/vault/hark/docs/analysis/05-user-stories.md) Epic B).
- Translation in "fast" mode uses local NLLB-200 which is genuinely lower quality than cloud translation. Mitigated by the user-toggle to Claude API high-quality mode (acknowledged cloud-touch, explicit user action).
- We're tied to the Apple Silicon performance envelope. If on-device transcription stops being viable (it won't, but if), the product dies. Acceptable risk.

**Assumptions that must hold:**
- On-device transcription quality stays within the "good enough to actually use" band. Phase 0 measures this.
- The privacy-conscious user segment exists and cares enough to choose Hark over Otter despite higher friction. Validated by the primary persona being the developer themselves.
- Apple Silicon performance continues improving over 5+ years (it will).

## Open questions

- If/when local Whisper hits a plateau and cloud ASR gets *dramatically* better (3x+ WER advantage), is there a "premium cloud mode" with explicit per-meeting consent? Probably no — the slippery slope is real, and any optional cloud path undermines the marketing claim. Revisit only if it becomes existentially necessary.

## References

- [Project handoff doc](../../meetingmind-handoff.md) — "Rejected" section
- [CLAUDE.md hard rule #1](../../CLAUDE.md) — "Audio never leaves the machine"
- [vault/docs/product/01-vision-and-personas.md](~/Documents/vault/hark/docs/product/01-vision-and-personas.md) — the trust thesis
- This ADR exists specifically to prevent this discussion from recurring. Point future sessions here.
