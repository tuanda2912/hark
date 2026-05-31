# ADR-0013: License Hark under the MIT License

- **Date:** 2026-05-31
- **Status:** Accepted
- **Deciders:** Dang Anh Tuan

## Context

Hark is intended to be open-source, but the repository had **no LICENSE file**. Legally that means *all rights reserved* — a public repo others can read but cannot use, modify, or distribute. We need to pick and commit a license before any of this lands publicly.

Constraints shaping the choice: solo developer, pre-v1; macOS-only with eventual **App Store** distribution (per the handoff doc); local-first / privacy-first product; the **indie-Swift ecosystem norm**; and we've already vendored MIT-licensed third-party skills under `.claude/skills/`.

## Decision

License Hark under the **MIT License**. A `LICENSE` file at the repo root carries `Copyright (c) 2026 Dang Anh Tuan`.

Vendored third-party material under `.claude/skills/` (e.g. `swift-concurrency-pro`, `swift-testing-pro`) **retains its own upstream MIT license** (© Paul Hudson) via the `LICENSE` file kept in each skill folder. Hark's root MIT covers the original work.

## Alternatives considered

- **Apache-2.0** — permissive, plus an explicit **patent grant** and patent-retaliation clause; it's also what the official Swift project uses.
  - ✅ Pros: defensive patent protection; signals "professional"; GPLv3-compatible.
  - ❌ Cons: more ceremony (a `NOTICE` file convention, "state your changes in modified files"); ~10 KB vs MIT's ~170 words. The patent grant is largely theoretical for a solo app *integrating* existing tech (WhisperKit, Core Audio) rather than inventing patentable algorithms, and it does **not** shield against third-party patent trolls anyway.
  - **Why rejected (for now):** the friction outweighs the benefit at the solo / pre-contributor stage. See the revisit trigger below.

- **GPL-3.0 / copyleft** —
  - ❌ Cons: forces downstream code to stay open and is **incompatible with App Store distribution**.
  - **Why rejected:** conflicts with the macOS/App-Store direction and with keeping a closed commercial build as an option.

- **No license (status quo)** —
  - ❌ "All rights reserved" — not actually open source.
  - **Why rejected:** defeats the goal of being open-source.

## Consequences

**Positive:**
- The simplest, most-recognized license — zero cognitive overhead for users or contributors.
- Aligned with the indie-Swift ecosystem and with our vendored MIT dependencies.
- **App-Store-safe** (unlike GPL/LGPL).
- Compatible with every current dependency — MIT (WhisperKit, Electron, Angular) and Apache-2.0 (Swift NIO, the Swift toolchain) alike.
- Preserves **all author options**: because the author holds copyright, Hark can still be dual-licensed, shipped as a closed commercial build, or relicensed later regardless of the MIT grant to others.

**Tradeoffs accepted:**
- MIT is **silent on patents** (no express grant). Acceptable at the solo stage; the real patent exposure for an ASR/audio app comes from third parties, which no permissive license mitigates.

**Must remain true / revisit trigger:**
- If Hark gains **meaningful outside contributors**, reconsider **Apache-2.0** (for the contributor patent grant) or adopt a **CLA** — and supersede this ADR then.
- The `LICENSE` copyright holder should always reflect the actual owner; update the name if it changes.

## References

- Vendored skills retain upstream MIT (© Paul Hudson): `.claude/skills/swift-concurrency-pro/LICENSE`, `.claude/skills/swift-testing-pro/LICENSE`
- The [twostraws/Swift-Agent-Skills](https://github.com/twostraws/Swift-Agent-Skills) directory's contribution note: MIT / Apache-2.0 / BSD / ISC / Unlicense are App-Store-compatible; GPLv2/GPLv3/LGPL are not.
- Project scope: [CLAUDE.md](../../CLAUDE.md), [meetingmind-handoff.md](../../meetingmind-handoff.md)
