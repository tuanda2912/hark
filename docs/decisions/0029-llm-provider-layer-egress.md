# ADR-0029: LLM provider layer & network egress — main-process, provider-agnostic (Phase 6)

- **Date:** 2026-06-02
- **Status:** Accepted
- **Deciders:** Dang Anh Tuan

## Context

Phase 6 adds the LLM-powered features: meeting **summaries**, in-meeting/post-meeting **Q&A**
("Ask Hark"), and a future **high-quality translation** mode. These are the **only** path by
which user content may leave the machine (CLAUDE.md rule #1), and rule #6 requires an ADR
before anything opens a network socket. Today the whole app is network-free except the
loopback WebSocket: the Swift engine (`harkd`) is **audited loopback-only and never opens an
outbound socket**, the Electron main makes no calls, and the renderer CSP is loopback-only.

We must decide: **where** LLM calls originate, the **provider abstraction** (the user wants
cloud *and* local models, not just Claude — directive 2026-06-02), and the **privacy
chokepoint**.

## Decision

**LLM calls originate in the Electron main process (Node) — never the Swift engine, never the
sandboxed renderer.**

- **Why main, not the engine:** keeps `harkd` network-free, preserving its audited
  "never opens an outbound socket" property. The engine is the most privileged process (holds
  TCC audio); adding an HTTP client + outbound surface there is the wrong place.
- **Why main, not the renderer:** the renderer stays sandboxed with an unchanged,
  loopback-only CSP — no per-provider domain whitelisting, and the **API key never enters the
  renderer/DevTools context**. The renderer calls main over IPC; main streams results back via
  IPC events.

**Provider abstraction:** an `LlmProvider` interface in main with two implementations:
- **Anthropic-native** → `https://api.anthropic.com` (`x-api-key`, `anthropic-version`).
- **OpenAI-compatible** → a configurable `baseUrl` covering OpenAI / Gemini / OpenRouter
  (cloud) **and** Ollama / LM Studio / llama.cpp (local, on `localhost`). **Local = zero
  egress** — the privacy win; cloud becomes one *option*, not the only path.

**No vendor SDK** — use Node's built-in global `fetch` against the documented REST endpoints.
Avoids third-party SDK telemetry + supply-chain/native-dep surface; the egress stays small and
auditable. (Revisit only if streaming ergonomics force it.)

**Privacy invariants (load-bearing):**
- **Text only ever crosses.** Main is handed transcript text / meeting markdown — it has **no
  audio path** into a provider. Audio + voiceprints **never** leave (rules #1, #5).
- **Single egress chokepoint:** every outbound LLM byte goes through main's provider layer.
- **User-invoked only.** No background/auto calls.
- **Every call logged** (cloud-call activity log): timestamp, action, provider, model, char/token
  counts, redaction count, status, cost — **never the transcript content itself**.
- **PII redaction ON by default** before any *cloud* send (mechanism detailed in the summary
  slice / a follow-on ADR). Local providers bypass egress entirely.
- **CSP unchanged.** Renderer makes no cloud calls.

This outbound-HTTPS dependency (to the user-configured provider endpoint, only on explicit
action) is the network-socket dependency rule #6 asks us to record. It will be **privacy-audited
before merge** — it is the first outbound network in the app.

## Alternatives considered

- **Calls from the renderer** (add the provider domain to CSP `connect-src`). ❌ relaxes the
  renderer's network policy, exposes the key to the sandboxed/DevTools context, brittle
  per-provider whitelisting. **Rejected.**
- **Calls from the Swift engine.** ❌ breaks `harkd`'s audited network-free property; wrong
  process (on-device ASR/diarization, holds TCC audio). **Rejected.**
- **Vendor SDKs** (`@anthropic-ai/sdk`, `openai`). ❌ native/transitive deps + possible
  telemetry; raw `fetch` to REST is small + auditable. **Rejected for v1.**

## Consequences

**Positive** — engine stays network-free; one auditable egress chokepoint; key isolated in main;
provider-agnostic incl. a zero-egress local option; no CSP change.

**Negative / accepted** — main now has outbound network (first in the app), so the log +
redaction are load-bearing and the layer must be privacy-audited; raw `fetch` means we parse SSE
streaming ourselves.

## Open questions

- Spend caps / monthly budget (design shows a cap). 
- Full NER name redaction (v1 starts with regex + speaker-label collapse).
- Vault-wide RAG retrieval (local embeddings + SQLite-vec) for cross-meeting Q&A.
- Streaming over IPC with backpressure.

## References

- CLAUDE.md rules #1 (audio/content leaves only via explicit user-invoked path), #3 (no
  telemetry), #6 (ADR for any network socket); ADR-0004 (no cloud ASR — the Claude API edge),
  ADR-0030 (API key storage), ADR-0027 (privacy/data-control).
- Design: `hark-docs/docs/design/07-data-flows.md` (summary + Q&A sequences),
  `QAPanel.jsx`, `PostMeetingReview.jsx`, `SettingsPrivacy.jsx` (cloud-call log).
- `docs/BACKLOG.md` — Phase 6 multi-provider, redaction log, spend cap.
