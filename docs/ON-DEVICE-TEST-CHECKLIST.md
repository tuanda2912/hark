# Hark — On-device test checklist (needs the user)

**Why this file:** these are the things I (Claude) **cannot** verify headlessly —
they need real audio, a configured model, and your eyes. The automated gates
(build, privacy-audit, logic review) are green for everything below; this is the
second half of "done." Tick each as you go.

**Last updated:** 2026-06-03 · After translation §3 (ADR-0035 Option C).

---

## 0. One-time setup — configure a model

Most items need an LLM. Two ways (Settings → gear icon, or ⌘,):

- **Local (RECOMMENDED — zero egress):** run Ollama, then in Settings pick
  **OpenAI-compatible**, `baseUrl` = `http://localhost:11434/v1`, model =
  whatever you pulled (e.g. `llama3.1`, `qwen2.5`). No key needed. This is the
  privacy-clean path and the one to use to prove **zero egress**.
- **Cloud (HQ):** pick **Anthropic** + paste a key, or OpenAI-compatible with a
  cloud `baseUrl` + key. Use this to confirm the **redaction + egress receipts**.

Use **Test connection** in Settings first — it should say OK.

---

## 1. Meeting summary
- [ ] Capture a short meeting → Stop → on the saved card, **Summarize**.
- [ ] **Expect:** a structured markdown summary (TL;DR / Key points / Actions / …).
- [ ] Receipt is honest: **local** → "ran locally · nothing left your Mac";
      **cloud** → "sent to {model} · redacted N item(s)".
- [ ] **Save to note** → the meeting `.md` gets a `## Summary` section (git-committed).

## 2. This-meeting Q&A
- [ ] Ask panel (right column), scope **This meeting** → ask something answerable
      from the transcript.
- [ ] **Expect:** a grounded answer; "I don't know from the transcript" when it's
      genuinely not covered (no hallucination).

## 3. Vault-wide Q&A (built-in RAG)
- [ ] Have a few `.md` notes in `~/Documents/vault/hark`. On a clean start the
      Ask panel shows **"Indexing your vault…"** then ready.
- [ ] Scope **Vault** → ask a question answerable from your notes.
- [ ] **Expect:** an answer with **numbered [n] citations** + source cards
      (note name + heading + snippet). Retrieval is local (nothing leaves the Mac).

## 4. Translation §1 — end-of-meeting (any language)
- [ ] Saved card → **Translate** → pick a language → **Translate**.
- [ ] **Expect:** a faithful, line-for-line translation (NOT a summary) + the same
      honest egress receipt. **Save to note** → `## Transcript — <lang>` section.

## 5. Translation §2 — live → English (on-device, no model needed)
- [ ] Before Start, toggle **`→ EN`** on. Start, **play/speak non-English audio**.
- [ ] **Expect:** captions appear **in English** (the line text itself is English).
      Pure on-device — no model required, nothing leaves the Mac.

## 6. Translation §3 — live → arbitrary target  ⟵ NEW (today)
> The new per-segment LLM path (ADR-0035 Option C). Needs a configured model.
> **Best tested with the local Ollama model** (proves zero egress).

- [ ] Before Start: the **`translate…` picker** sits right after `→ EN`. With **no
      model** configured it's disabled (tooltip points you to Settings) — confirm.
- [ ] Configure the **local** model (step 0), then pick a target (e.g. **Vietnamese**).
- [ ] **Mutual exclusion:** picking a target clears `→ EN`; toggling `→ EN` back on
      clears the picker. Confirm both directions.
- [ ] **Egress hint:** with a LOCAL model the bar shows **`on-device`** (green).
      With a CLOUD model it shows **`↑ cloud · redacted`**. Confirm the right one.
- [ ] Start, **play/speak audio in a different language than the target**.
- [ ] **Expect:** each finalized line keeps its **original** text, with the
      **translation underneath** (bilingual). Lines already in the target language
      are left alone (no duplicate echo).
- [ ] **Latency feel:** does the translation appear soon enough after each line
      finalizes to be useful? (Local model speed depends on your Mac + model size.)
- [ ] **Locked during capture:** the picker is disabled while recording (chosen
      before Start) — confirm.

## 7. Privacy verification (the trust check)
- [ ] **Local zero-egress:** after a LOCAL summary / Q&A / §3 live-translation
      session, open **Settings → Privacy** (cloud-activity log). Entries should be
      marked **`local`** with **0 redactions** — nothing left the Mac.
- [ ] **§3 aggregation:** with a CLOUD model + §3 on, after you **stop** the
      meeting there should be **ONE** `translate-live` entry (not one per line),
      showing a line count + char volume + redaction total — metadata only, never
      the text.
- [ ] **Cloud redaction:** a cloud summary of a transcript containing an email /
      phone / amount should report N redactions in the receipt.

---

## Notes for next session (Phase 7 — packaging/notarization)

Phase 7 is **~60% done** (commit `746abd0`): `ui/electron-builder.yml`
(arm64 dmg+zip, hardened runtime, entitlements, sidecar bundling, mic/system-audio
usage strings), `build/notarize.js` (no-op unless Apple creds present), and a
signed dev `Hark.app` was produced.

**Remaining — and what I need from you to finish it:**
1. **Apple Developer credentials** (for real notarization): a **Developer ID
   Application** signing identity in your Keychain + env vars `APPLE_ID`,
   `APPLE_APP_SPECIFIC_PASSWORD`, `APPLE_TEAM_ID`. Without these `npm run dist`
   builds + signs ad-hoc but skips notarization.
2. **An app icon** — `ui/build/icon.icns` (1024px source). None exists yet; until
   then electron-builder uses the default Electron icon.
3. **TCC attribution check** (your eyes, on a notarized build): launch the
   signed+notarized app and confirm the **mic / system-audio permission prompt
   says "Hark"** (not "Electron") and that capture works — this is the whole point
   of the `cs.inherit` entitlement on the sidecar.

(Minor: the header comment in `electron-builder.yml` still says "not yet wired
into package.json scripts" — stale; `pack`/`dist` scripts exist. Worth a 1-line
fix when we touch Phase 7.)
