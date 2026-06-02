# ADR-0023: First-run onboarding flow

- **Date:** 2026-06-02
- **Status:** Accepted
- **Deciders:** Dang Anh Tuan

## Context

With the app packaged (ADR-0021) and the model-load progress screen shipped (ADR-0022,
"Slice 1"), the remaining first-run gap is the **onboarding flow** the design specifies
(`hark-docs/docs/design/ui/` screens 13/14/15: Trust → Permissions → Setup). A fresh user
should understand the privacy posture and the permissions macOS is about to ask for
*before* the prompts appear — "no surprises" is core to a privacy-first product.

The design predates the final engine stack and a few unbuilt features, so building it
faithfully requires keeping the **visual language** exactly while making the **content
honest** about what Hark actually does.

## Decision

A three-screen onboarding overlay, shown on first run, gated on a new persisted
**`hasCompletedOnboarding`** prefs flag (default `false`; a missing field reads as `false`,
so existing installs see it once). "Start using Hark" sets the flag. The overlay sits above
everything (incl. the loading screen); the engine warms up behind it, masking the model
download. Content adapted for accuracy:

- **Trust:** engine label corrected to **WhisperKit large-v3-turbo** (not the design's
  "whisper.cpp"). Three points: local capture/transcription, opt-in itemized cloud, plain-
  markdown vault you control.
- **Permissions:** **two**, not three. **Microphone** (live status via Electron
  `systemPreferences.getMediaAccessStatus`, optional `askForMediaAccess` when undecided) and
  **System Audio Recording** — Core Audio Process Taps (`kTCCServiceAudioCapture`),
  **deliberately not Screen Recording** (ADR-0011), requested lazily at first capture
  (ADR-0012), so it's informational ("macOS will ask the first time you record"). The
  design's **Accessibility / global-hotkeys** card was **dropped** — global hotkeys aren't
  built, so showing it would be dishonest.
- **Setup:** the real (fixed) vault path with `writable` / `git-tracked` chips and a working
  "Reveal in Finder". The **folder picker** and **Anthropic API-key** field are rendered in
  the design's layout but **disabled/deferred** — configurable vault + Keychain key are
  future work (the key aligns with the design's own "add later" framing). The "Obsidian
  detected" chip was dropped (can't be truthfully detected for a fixed path).

## Alternatives considered

- **Match the design verbatim** (three permissions incl. "Screen recording" + Accessibility;
  functional folder picker + key field).
  - ❌ Would mislabel a permission we deliberately don't use (Screen Recording), and present
    unbuilt features (global hotkeys, configurable vault, cloud key) as if they worked.
  - **Why rejected:** honesty beats literal fidelity; the design is the *visual* north star,
    not a spec on engine internals (same reason the footer says WhisperKit, not whisper.cpp).
- **No onboarding — rely on lazy permission prompts only.**
  - ❌ Drops the "explain why before macOS asks" trust moment that the privacy product needs.
  - **Why rejected:** the trust/permissions explainer is the point.
- **Request all permissions upfront from the onboarding screen.**
  - ❌ Our model is lazy (ADR-0012); system audio (`kTCCServiceAudioCapture`) can't be
    pre-granted without starting a tap, so a "Grant" button there would be fake.
  - **Why rejected:** only mic can be cleanly pre-prompted; the rest is informational.

## Consequences

**Positive**
- Honest first-run that builds trust and explains permissions before macOS asks.
- The engine warms up *behind* onboarding, hiding the model-download wait.
- Back-compat flag: existing installs see it once, then never again.
- Mic permission status is real (live), so the screen isn't purely decorative.

**Negative / tradeoffs accepted**
- Screen 3 isn't fully functional yet — the **folder picker** and **API-key** field are
  disabled placeholders. Full design fidelity needs **configurable vault path** + **Keychain
  key storage** (both tracked in BACKLOG). The screen converges on the design once those land.
- The onboarding has only a dark variant so far (design has a light variant, screen 16) —
  tracked under the BACKLOG "Light theme" item.
- Content diverges from the design's literal copy (documented here so a future session
  doesn't "fix" the permissions screen back to Screen Recording).

**What needs to remain true**
- The permission model stays Process Taps + lazy (ADR-0011/0012). If it ever changes, revisit
  the permissions screen.
- If configurable vault and/or a Keychain key land, screen 3's deferred controls get enabled.

## Open questions

- Configurable vault location (BACKLOG) and Keychain API key (Phase 6, BACKLOG) — the two
  gates to full screen-3 fidelity.
- Light-theme variant of the onboarding (BACKLOG "Light theme").
- Global hotkeys — would re-introduce the Accessibility card if built.

## References

- ADR-0011 (Process Taps / TCC, not Screen Recording), ADR-0012 (lazy permissions),
  ADR-0021 (packaging), ADR-0022 (model-load progress / Slice 1)
- Design: `hark-docs/docs/design/ui/` screens 13/14/15 (+ 16 light), `artboards/Onboarding.jsx`
- `docs/BACKLOG.md` — configurable vault, Keychain key, onboarding light theme
- UI: `components/onboarding.component.*`, `app.component.*`; main: `prefs.ts`, `preload.ts`,
  `main.ts`; `services/preferences.service.ts`
