# ADR-0027: Privacy & data-control model — opt-in sensitive data, transparent + local

- **Date:** 2026-06-02
- **Status:** Accepted
- **Deciders:** Dang Anh Tuan

## Context

Speaker enrollment (ADR-0026) stores **voiceprints** (biometric data), and the planned
audio-review screen needs **stored audio recordings**. Both carry real legal weight:
all-party-consent recording statutes (jurisdiction-dependent), and biometric-privacy law
(GDPR special-category data; Illinois BIPA; etc.). Storing such data — especially of *other*
meeting participants — without the user's informed choice, or silently syncing it off the
machine, is a liability. Hark is local-first; the right posture is **user-controlled,
transparent, privacy-first**, making lawful use *possible* without giving legal advice.

## Decision

**Three sensitive artifacts, each governed by the user:**

| Artifact | Purpose | Stored | Synced |
|---|---|---|---|
| Transcript (markdown) | the meeting notes | always (the product) | the user's vault, their choice |
| **Audio recording** | enables verify-by-ear review/playback | **opt-in** (off unless enabled) | **off by default** |
| **Voiceprint** (`vault/.speakers/`) | recognize speakers across meetings | **opt-in** | **off by default** |

- **Explicit opt-in at onboarding (informed consent):** a privacy step asks the user to
  knowingly enable *Keep audio* and *Remember speakers*. Both default **OFF** if skipped.
  Always changeable in **Settings → Privacy**.
- **Engine enforcement:** `capture.start` carries `keep_audio` + `remember_speakers` (default
  false). The engine **stores/matches voiceprints only when `remember_speakers`**, and
  **persists audio only when `keep_audio`**. Absent flags ⇒ false ⇒ nothing sensitive stored.
- **Sync of audio + voiceprints OFF by default:** they're already **gitignored** (never travel
  via a vault git remote). Folder-sync (iCloud/Dropbox) copies whole folders, so we **disclose**
  that and let the user exclude/disable. A future Hark-native sync honors per-type toggles.
- **Transparency surfaces:** README "Your data & privacy"; the onboarding privacy step; a
  Settings → Privacy pane ("what's stored / where" + toggles + delete actions); and a
  plain-language **legal note**: *"Recording and storing voiceprints may require consent under
  your local laws — you are responsible for obtaining it. Hark keeps everything on your Mac to
  support that. This is not legal advice."*
- Everything **deletable**; nothing sensitive is stored or synced without the explicit opt-in.

## Alternatives considered

- **Silent privacy-first defaults (off, no onboarding prompt).** ✅ simple. ❌ less transparent;
  an explicit informed-consent moment is stronger legally. **Rejected** in favor of an
  onboarding opt-in.
- **Remember-speakers on by default.** ✅ friendliest. ❌ stores biometric data without an
  explicit choice. **Rejected** — too risky for the legal surface.
- **Store audio/voiceprints in app-data (outside the vault).** ❌ violates rule #2 (audio/PII
  belong in the vault). **Rejected** — keep them in the vault, gitignored.

## Consequences

**Positive**
- Informed consent + user control + transparency → defensible posture; sensitive data never
  stored/synced without the user's explicit choice.
- Privacy-first by default; enrollment + audio-review stay dormant until enabled.

**Negative / tradeoffs accepted**
- Enrollment + audio-review are off until the user opts in (the cool features aren't on out of
  the box). Accepted — it's the right call for the legal surface.
- Onboarding gains a privacy step; we must keep the disclosures accurate as features evolve.

## Open questions

- Future Hark-native cross-machine sync design (per-type toggles).
- Data-retention / auto-delete policy (e.g. delete audio after N days).
- Per-meeting override of the global settings (probably unnecessary — global is simpler).

## References

- ADR-0026 (speaker enrollment), ADR-0024 (post-stop transcript), ADR-0016/0017 (diarization)
- CLAUDE.md hard rules #1 (audio leaves only via explicit user-invoked path), #2 (vault-only),
  #5 (voiceprints stay local)
- Design: `SettingsPrivacy.jsx`, `Onboarding.jsx`
- `docs/BACKLOG.md` — audio-review screen (gated by Keep-audio)
