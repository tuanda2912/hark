# ADR-0031: Content egress governance — local-vs-cloud, PII redaction, cloud-call log (Phase 6 slice 2)

- **Date:** 2026-06-02
- **Status:** Accepted
- **Deciders:** Dang Anh Tuan

## Context

Slice 2 (meeting summary) is the **first time user content (transcript text) leaves the
machine**. ADR-0029 put the egress in Electron main; now we need the *governance*: what is
redacted, how local vs cloud differ, and how every egress is made transparent (the design's
"PII redacted · View log"). Rules #1 (content leaves only via explicit user action), #3 (no
silent exfiltration).

## Decision

**1. Local vs cloud is the first fork.**
- **Local provider** (OpenAI-compatible with a `localhost` / `127.0.0.1` base URL) → send the
  **full transcript**, **no redaction**. It never leaves the Mac — full quality, zero egress.
- **Cloud provider** (Anthropic, or OpenAI-compatible with a remote base URL) → **redact before
  send** (below).

**2. Redaction (cloud only), ON by default, v1 scope.** Regex-replaced with typed placeholders:
- emails, phone numbers, money/currency amounts, long digit runs (≥ 7 digits → IDs / cards /
  account numbers), URLs;
- plus the meeting's **known speaker display-names** (from the roster) collapsed to their labels
  (`"Tuan"` → `"Speaker 1"`).
- Returns per-category counts (drives the receipt + log).

**3. Honest limitation — we do NOT overclaim.** Arbitrary names mentioned in free speech are
**not** auto-detected (no NER yet). The on-screen receipt + the log state exactly what was
redacted; they must not imply more. Full NER name redaction is BACKLOG.

**4. Cloud-call log (transparency).** Every summarize (and future Q&A / translation) action is
logged locally to app-data `cloud-calls.json`: timestamp, action, provider, model, **egress
(cloud|local)**, char counts in/out, redaction total, status, optional cost estimate.
**Transcript content is NEVER logged — metadata only.** Local actions are logged too, marked
`egress: local`, so the user sees the full picture. Surfaced in Settings → Privacy.

**5. Never sent:** audio, voiceprints — only (redacted, if cloud) transcript text. Egress stays
in main (ADR-0029).

**6. Persistence through the engine.** The generated summary is written back to the meeting
markdown by the **engine** (`VaultWriter` appends a `## Summary` section + local git-commit),
via a `summary.write` wire command — NOT by main writing the vault behind the engine's back.
Keeps vault writes + the git-history rule (#4) centralized in the one owner.

## Alternatives considered

- **Redact even for local models.** ❌ pointless (zero egress already) and hurts summary quality.
  **Rejected.**
- **No redaction for cloud.** ❌ violates the privacy posture. **Rejected.**
- **Full NER name redaction now.** ❌ needs a local NER model + tuning; heavier. **Deferred** —
  v1 ships regex + known-name collapse and is honest about the gap.
- **Main appends the summary to the vault directly.** ❌ two writers to the "sacred" vault +
  bypasses the git-commit owner. **Rejected** — go through the engine.

## Consequences

**Positive** — cloud egress is redacted + fully logged; local is full-quality + zero-egress;
transparency receipt + activity log; vault writes stay single-owner.

**Negative / accepted** — regex redaction misses free-text names (documented, not overclaimed);
collapsing known names to labels slightly lowers cloud-summary specificity (the privacy trade);
summary persistence depends on the engine still holding the meeting (v1: the just-finished
meeting, like the rename MVP).

## Open questions

- Local NER name redaction; a user-facing redaction toggle (design has one); spend caps;
  streaming the summary; summarizing older meetings (needs snapshot reload, shared with the
  rename MVP limitation).

## References

- ADR-0029 (egress chokepoint in main), ADR-0030 (key storage), ADR-0027 (privacy model),
  ADR-0020 (speaker.rename — the `summary.write` command mirrors its shape), CLAUDE.md #1/#3/#4.
- Design: `hark-docs/docs/design/07-data-flows.md` (summary flow), `SettingsPrivacy.jsx`
  (activity log), `PostMeetingReview.jsx` (summary).
- `docs/BACKLOG.md` — NER redaction, redaction toggle, spend cap, streaming.
