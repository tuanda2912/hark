# ADR-0015: Transcript persistence to the vault (v1)

- **Date:** 2026-06-01
- **Status:** Accepted (decision locked 2026-06-01; implementation deferred to a later phase — see status note below). Supersedes [08-websocket-api-contract.md](../../../hark-docs/docs/design/08-websocket-api-contract.md) line 295 "engine writes" **for v1 only** — see Decision.
- **Deciders:** Dang Anh Tuan

## Context

**Status note (2026-06-01):** The four decisions below — the markdown **format**, the **write-owner** (Electron main for v1), **auto-save on `capture.stop`**, and **local-only git** — are **locked now** and won't be re-litigated. The **build is deferred to a later phase** (after the current Phase 4 UI surfaces land); when it's scheduled, this ADR is the spec to follow verbatim.

Hark is a **second-brain**: the whole point is a durable, searchable markdown record of every meeting. Yet today the engine **discards every final segment on `capture.stop`** — nothing is written anywhere. The user ran a meeting, stopped capture, went looking for the transcript file the product promises, and found **nothing**. That gap has to close for v1.

The design docs already specify the persisted artefact in detail — the file shape ([07-data-flows.md](../../../hark-docs/docs/design/07-data-flows.md) ~95–117), the vault layout ([06-architecture-overview.md](../../../hark-docs/docs/design/06-architecture-overview.md) ~180), and the `meeting.saved` frame ([08-websocket-api-contract.md](../../../hark-docs/docs/design/08-websocket-api-contract.md) ~172–189). What they assume but cannot yet hold is **diarization** (Phase 5, FluidAudio): speaker labels, name matching, and the embeddings in `vault/.speakers/`. v1 ships **pre-diarization**, which changes *who* is best placed to write the file. This ADR records the v1 persistence path and the migration back to the documented design once Phase 5 lands.

The project's hard rules constrain this tightly: [CLAUDE.md](../../CLAUDE.md) rule #2 (transcripts/PII go **only** to the vault), rule #4 (the vault is sacred — never auto-delete, history recoverable via git), rule #5 (speaker embeddings stay local), rule #6 (an ADR before any network-socket dependency).

## Decision

Persist each meeting to the vault as a markdown file, **auto-saved on `capture.stop`**, following the design-doc format **verbatim** and committing it to a **local-only git repo**. For v1 the **Electron main process** owns the write — a deliberate, documented deviation from the docs that assign it to the engine.

**1. Format & layout — follow the design docs verbatim.**
Path: `~/Documents/vault/hark/meetings/YYYY-MM-DD-{slug}.md` (lowercase `meetings/`, per the newer docs 06/07/08; the old handoff's `Meetings/` is **superseded**). YAML front-matter + a `## Transcript` body of blockquoted, wall-clock-timestamped utterances, 📌 on bookmarked moments — Obsidian-compatible:

```markdown
---
title: Q2 Planning Sync
date: 2026-05-24T10:30:00+07:00
duration_sec: 2715
attendees: []
bookmarks: 4
hark_version: 0.1.0
---

## Transcript

> 10:30:02
> Welcome everyone. Let's start with the Camunda migration status...

> 📌 10:31:42
> We decided to push the cutover to next Monday.
```

`date` is ISO-8601 with offset; `duration_sec`, `bookmarks`, `hark_version` as shown. **v1 is pre-diarization, so there are no speaker names:** `attendees: []` and utterance headers are **just the timestamp** (no `**Speaker N**` prefix). When Phase 5 adds diarization, the `**Name** · HH:MM:SS` header and a populated `attendees` array slot straight back in.

**2. Write-owner for v1 = the Electron main process** — a deliberate deviation from [08 line 295](../../../hark-docs/docs/design/08-websocket-api-contract.md) ("engine writes them"). The docs assign the write to the engine **because the engine will own FluidAudio diarization** — the speaker-bearing fields, name matching, and the `meeting.saved` frame are all diarization outputs the engine alone can produce. **Pre-diarization, the engine holds no privileged information the renderer lacks:** the renderer already has the full ordered final-segment list plus bookmarks. Writing from main is **smaller, all-TypeScript, reuses the atomic temp-file-write-then-rename pattern from `prefs.ts`** ([ADR-0014](0014-ui-preferences-persistence.md)), and needs **zero engine or wire changes**.
**Migration path:** when Phase 5 lands, the write moves into the engine, triggered by the `meeting.saved` frame, exactly as the docs specify. This ADR supersedes line 295 **for v1 only**.

**3. Save trigger = auto-save on `capture.stop`,** with a user-initiated **Discard** affordance. Discarding **deletes the file and commits the deletion** — so the content is still recoverable from git history (rule #4: never auto-delete, history recoverable). The deletion is **user-initiated**, not automatic, and the commit keeps it reversible.

**4. Git — the vault is a local git repo.** On first save, `git init` the vault if `.git` is absent and set a **local** git identity (`user.name "Hark"`, `user.email "hark@localhost"`) so commits never fail on a machine with no global git config. **Never clobber an existing repo or config.** Each saved meeting is committed locally with a Conventional Commit message (e.g. `feat(meeting): add {slug}`). **No remote is added and nothing is pushed** — purely local versioning. A vault `.gitignore` excludes `.speakers/` as forward-safety, so voice embeddings (rule #5) can never land in a repo the user might later push.

**5. Title** — a small editable title field in the UI top bar, defaulting to a timestamp-derived name. The `{slug}` is kebab-cased from the title; filename collisions get a `-2`/`-3` suffix (**never overwrite** — rule #4).

## Alternatives considered

- **Engine writes the file now** (the documented design).
  - ✅ Pros: matches the docs; one write-owner for v1 and Phase 5.
  - ❌ Cons: front-loads Phase 5 Swift work and wire changes (the `meeting.saved` frame, an engine-side git+markdown writer) for **zero v1 benefit** — the engine has no speaker data to add pre-diarization.
  - **Why rejected:** premature. The engine's privileged role *is* diarization; until that exists, moving the write there buys nothing and costs Swift + protocol churn. Deferred to Phase 5 as the explicit migration path.

- **Plain files, no git.**
  - ✅ Pros: simpler — just write the `.md`.
  - ❌ Cons: a stray edit or a discard is unrecoverable.
  - **Why rejected:** counter to hard rule #4 ("all changes go through git commits so history is recoverable"). Git is the mechanism that lets us offer Discard *and* keep the content recoverable.

- **Store in `localStorage` or app-data** (`~/Library/Application Support/Hark/`).
  - ❌ Cons: transcripts are **user content**, not config.
  - **Why rejected:** rule #2 — transcripts/PII belong in the vault and nowhere else. App-data is for rebuildable caches and prefs ([ADR-0014](0014-ui-preferences-persistence.md)); the vault is for the user's stuff.

## Consequences

**Positive:**
- The product's core promise — a **durable, Obsidian-readable markdown record** — is fulfilled for v1.
- Output matches the design-doc format exactly, so the Phase 5 engine-write can produce **byte-compatible files** and diarization slots in additively (names + `attendees`).
- The write is **all-TypeScript in main**, reuses the proven `prefs.ts` atomic-write pattern, and ships with **no engine/wire changes**.
- The vault gains **local git history** — every meeting versioned, every discard reversible — at zero network surface.

**Tradeoffs accepted:**
- **Two write-owners over the project's lifetime:** main now, engine after Phase 5. The migration is real work, but it's bounded and explicitly scoped to when diarization arrives.
- **v1 transcripts carry no speaker attribution** (`attendees: []`, timestamp-only headers). This is inherent to pre-diarization, not a persistence choice — the format reserves the speaker fields for later.
- Main now performs **git operations** on the vault. We own `git init` / local-identity / commit correctness, and must never clobber a user's existing vault repo or config.

**Must remain true / revisit trigger:**
- Git stays **local-only** — no remote, no push. The instant a remote/push is contemplated, that's a new ADR under rule #6 (it would open a network socket) and a privacy review of what's in the repo.
- When **Phase 5 (FluidAudio diarization)** lands, move the write into the engine behind `meeting.saved` and retire this ADR's deviation from line 295. The format does not change — only the writer.
- `.speakers/` must remain gitignored so embeddings never enter the repo (rule #5).

## Privacy / threat-model note

The write targets the **vault** — the single sanctioned location for transcripts/PII (rule #2). Git is **local-only**: no socket opened, no remote configured, nothing pushed, so **no network-dependency ADR is needed** under rule #6. The vault `.gitignore` excludes `.speakers/`, keeping voice embeddings out of any repo the user might later push (rule #5). Discard deletes-and-commits rather than auto-deleting, preserving recoverability (rule #4). **No transcript or audio leaves the machine.**

## Open questions

- **Vault root override.** v1 assumes `~/Documents/vault/hark`. If a Settings panel later lets the user relocate the vault, the git-init / write path must follow it (a prefs read, not a new store).
- **Mid-meeting crash.** Auto-save fires on `capture.stop`; an app crash *during* a live meeting loses the in-flight transcript. Periodic autosave / crash-recovery is out of scope for v1 and can be a later ADR.

## References

- Hard rules: [CLAUDE.md](../../CLAUDE.md) (rules #2, #4, #5, #6)
- File shape: [07-data-flows.md](../../../hark-docs/docs/design/07-data-flows.md) §2 (~95–117)
- Vault layout / data stores: [06-architecture-overview.md](../../../hark-docs/docs/design/06-architecture-overview.md) (~180)
- `meeting.saved` frame and "engine writes" (~line 295): [08-websocket-api-contract.md](../../../hark-docs/docs/design/08-websocket-api-contract.md) (~172–189, 295) — superseded for v1 by this ADR
- Atomic-write pattern reused: [ADR-0014](0014-ui-preferences-persistence.md) (`prefs.ts`)
- Migration trigger: Phase 5 (FluidAudio diarization)
