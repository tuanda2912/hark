# Hark — On-device test checklist (needs the user)

**Why this file:** these are the things I (Claude) **cannot** verify headlessly —
they need real audio, a configured model, and your eyes. The automated gates
(build, privacy-audit, logic review) are green for everything below; this is the
second half of "done." Tick each as you go.

**Last updated:** 2026-06-04 · Live translation removed/deferred (ADR-0037);
translation is now on-demand after a meeting stops.

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

## 4. Translation — on-demand, AFTER the meeting stops  ⟵ CHANGED (today, ADR-0037)
> Live (translate-during-capture) translation was **removed and deferred** to the
> backlog. **Confirm there are NO translate controls during a meeting** — the
> controls bar has neither a `→ EN` toggle nor a `translate…` picker. Translation is
> now a post-stop action. Needs a configured model (step 0); best tested with the
> **local Ollama model** (proves zero egress).

- [ ] **No live controls:** start a capture and confirm the controls bar shows no
      `→ EN` and no `translate…` — only source/language selectors + the trust lozenge.
- [ ] Capture a short meeting in a **non-English** language → **Stop**.
- [ ] Saved card → **Translate** → the panel shows a language picker + an honest
      **egress disclosure**: LOCAL → "Runs on your local model — nothing leaves your
      Mac"; CLOUD → "Each line is sent to your cloud model (redacted) and recorded in
      Settings → Privacy." Confirm it matches your configured model.
- [ ] Pick a target (e.g. **Vietnamese**) → **Translate**. The panel **closes** and a
      persistent banner shows **"Translating → <lang> N%"** that climbs to 100%
      **while you keep using the app**, then **"<lang> translation ready"**.
- [ ] **Expect in the saved `.md`:** a `## Transcript — <lang>` section that
      **mirrors** the original `## Transcript` — same speaker labels, same wall-clock
      timestamps, same blockquote format — just translated. No timestamp/format drift.
- [ ] **Completeness (ADR-0036):** the translated section has the **same number of
      lines** as the original, and a long run-on utterance is **not truncated**.
- [ ] **Re-translate / switch language:** open Translate again, pick a different
      language → the file gains/replaces that language's section.

## 5. Privacy verification (the trust check)
- [ ] **Local zero-egress:** after a LOCAL summary / Q&A / post-stop translation,
      open **Settings → Privacy** (cloud-activity log). Entries should be marked
      **`local`** with **0 redactions** — nothing left the Mac.
- [ ] **Translation aggregation:** with a CLOUD model, after a post-stop **Translate**
      completes there should be **ONE** aggregated translation entry (not one per
      line), showing a line count + char volume + redaction total — metadata only,
      never the text.
- [ ] **Cloud redaction:** a cloud summary of a transcript containing an email /
      phone / amount should report N redactions in the receipt.

## 8. Light / dark theme  ⟵ NEW (today, `e84cb21`)
- [ ] **Settings → Appearance → Theme** has **System / Light / Dark**. Default is
      **System** (follows your macOS Light/Dark setting).
- [ ] Switch to **Light** → the whole app repaints to the light palette instantly
      (no restart). Switch to **Dark** → back. Switch to **System** → matches your
      Mac; flip macOS appearance and confirm Hark follows live.
- [ ] **Eyeball each screen in light** against the design screenshots (in
      `hark-docs/docs/design/ui/screenshots/`): `02-mw-light`, `08-rev-light`,
      `10-qa-light`, `12-set-light`, `16-ob-1-trust-light`, `21-comp-light`,
      `24-st-tagging-modal-light`. Flag anything that looks off (contrast, a
      stuck-dark element) — components are token-driven so it should "just work,"
      but light mode hasn't had a human pass yet.
- [ ] The choice **persists across restarts**.

> Bonus (also fixed today): the **external vault-search backend** choice
> (Settings → Vault search → External) now persists across restarts — it was
> silently reverting to Built-in before. If you test external RAG, confirm it
> stays selected after a relaunch.

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
