# ADR-0014: Local preferences persistence for the Electron UI

- **Date:** 2026-06-01
- **Status:** Accepted
- **Deciders:** Dang Anh Tuan

## Context

The Electron UI's capture-source selections (mic on/off, system on/off) and the chosen ASR language were **transient renderer state** — held in memory and reset to defaults on every launch. For a tool meant to be a **daily driver**, re-picking "mic + system, English" before each meeting is friction the user feels every single day.

A forthcoming Settings panel also needs *somewhere* to put choices. There is currently no persistence layer in the UI at all, so this is the first time we have to answer "where does app config live, and how is it written?" — a question the project's hard rules constrain tightly: [CLAUDE.md](../../CLAUDE.md) rule #2 says app data goes in `~/Library/Application Support/Hark/` and **never** in the vault, and rule #6 requires an ADR before adding anything that opens a network socket.

## Decision

Add a small **user-preferences persistence layer** in the Electron **main process**, storing a versioned JSON file at `~/Library/Application Support/Hark/prefs.json`. The path is built as `app.getPath('appData')` joined with a literal `'Hark'` — **not** `app.getPath('userData')`, which (with no `productName` set) would resolve to `.../Electron` in dev and `.../hark-ui` when packaged. This pins the file in the sanctioned app-data location, **not** the vault.

The schema is minimal and versioned:

```json
{ "version": 1, "audio": { "mic": true, "system": true, "language": null } }
```

It persists the user's default capture-source and language selections so they survive relaunch. Implementation is a **hand-rolled** (~30-line) JSON reader/writer in the main process: read on demand via IPC, **validated before write**, and exposed to the renderer over a **whitelisted `contextBridge` API**. No file is ever written outside the `~/Library/Application Support/Hark/` dir.

## Alternatives considered

- **`electron-store` dependency** — the de-facto npm package for exactly this.
  - ✅ Pros: atomic writes, schema/migration helpers, battle-tested.
  - ❌ Cons: a new runtime dependency (and its transitive tree) for what a hand-rolled reader/writer covers; CLAUDE.md is deliberately dependency-cautious.
  - **Why rejected:** ~30 lines of `JSON.parse`/validate/`writeFile` cover this need with **zero new supply-chain surface** and no new network-capable code. Revisit only if prefs grow complex enough to need real schema migrations or atomic-write guarantees beyond what's trivial to hand-roll.

- **Renderer `localStorage`** — keep it entirely in the Chromium layer.
  - ✅ Pros: no IPC, no main-process code.
  - ❌ Cons: lives inside the **Chromium profile dir** — opaque, not the sanctioned Hark app-data location, awkward to inspect or back up — and it splits app state across two stores (some in `userData`, some in the Chromium profile).
  - **Why rejected:** violates the spirit of hard rule #2 (one well-known app-data location) and makes the state harder to reason about and support.

- **Store prefs in the vault** (`~/Documents/vault/hark`).
  - ❌ Cons: the vault is **sacred** (rule #4) and is for *user content* — notes, transcripts, speaker embeddings — under git history. App config is not user content.
  - **Why rejected:** mixing app config into the vault pollutes it and muddies the "vault = the user's stuff" contract.

## Consequences

**Positive:**
- Capture source + language **persist across relaunch** — the daily-driver friction is gone.
- A clean, ready surface for the upcoming Settings panel to read/write through.
- Config lives in **one well-known, inspectable, backup-able location** (`~/Library/Application Support/Hark/prefs.json`), consistent with hard rule #2.
- **No new dependency, no new network surface** — fully within the project's dependency-caution posture.

**Tradeoffs accepted:**
- Hand-rolled read/write means **no atomic-write or migration machinery** out of the box — a crash mid-write could in principle corrupt `prefs.json`. Acceptable because the file is tiny, non-authoritative (it holds *defaults*, not user content), and trivially regenerable; a corrupt/missing file falls back to baked-in defaults.
- We own the **schema-versioning discipline** ourselves: any future field change must bump `version` and handle older shapes on read.

**Must remain true / revisit trigger:**
- Prefs stay **small and config-only**. If they start needing migrations, atomic guarantees, or grow into something resembling user content, reconsider `electron-store` (or moving content-shaped data into the vault) and supersede this ADR.
- The file must **never** hold transcripts, audio, or PII — only UI defaults.

## Privacy / threat-model note

This change **opens no network socket**, writes **nothing outside `~/Library/Application Support/Hark/`**, and stores **no user content** (no transcripts, audio, or PII — only UI defaults like capture toggles and language code). It therefore complies with hard rule #2 (app data in the sanctioned location, vault untouched) and needs **no network-dependency ADR** under rule #6.

## Open questions

- Whether the Settings panel will need a broader pref schema (window state, theme, vault path overrides). When it does, that's a `version` bump handled on read — not a new store.

## References

- Hard rules and decision-log conventions: [CLAUDE.md](../../CLAUDE.md) (rules #2, #4, #6)
- Relates to: [ADR-0010](0010-phase-4-ui-scaffold.md) (Phase 4 UI scaffold)
- Storage location convention: `~/Library/Application Support/Hark/` per the "Where things live" table in CLAUDE.md
