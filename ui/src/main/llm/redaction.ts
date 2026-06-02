// PII redaction for CLOUD egress (ADR-0031 §2).
//
// Slice 2 routes real transcript text off the machine for the FIRST time.
// Before any CLOUD send we replace common PII with typed placeholders and
// count each category — the counts drive the on-screen "PII redacted" receipt
// and the cloud-call log. LOCAL (zero-egress) calls skip this entirely (full
// transcript, full quality) — see index.ts.
//
// SCOPE / HONESTY (ADR-0031 §3): this is regex + known-name collapse, NOT a
// general name detector. Arbitrary names spoken in free text are NOT caught
// (no NER yet — that's BACKLOG). The receipt/log state exactly what was
// redacted and must not imply more.
//
// PRIVACY: this module is pure string→string. It never logs, never persists,
// and never sees the network. The returned `text` is what main hands to the
// provider; the input transcript is discarded by the caller.

import type { RedactionCounts } from './types';

/** The fixed category set. Keys match the LOCKED contract's RedactionCounts. */
type Category = 'email' | 'phone' | 'money' | 'number' | 'url' | 'name';

// ── Patterns ──────────────────────────────────────────────────────────────
// All `g`-flagged so a single `replace` handles every occurrence and we can
// count via the replacer callback. Ordering of the PASSES (below) — not these
// definitions — is what prevents double-counting.

/** http(s) URLs. Run FIRST: a URL can embed dots, digits and an '@' that the
 *  email/number passes would otherwise mis-claim. */
const URL_RE = /\bhttps?:\/\/[^\s<>()]+/gi;

/** Email addresses. Run after URL, before phone/number (an email's domain/
 *  local part can contain digit runs). */
const EMAIL_RE = /\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b/g;

/** Money / currency amounts: a leading currency symbol ($ € £ ¥) followed by a
 *  numeric amount (optional thousands separators + decimals). Run before phone/
 *  number so "$1,200,000" is one [amount], not a long digit run. */
const MONEY_RE = /[$€£¥]\s?\d{1,3}(?:[.,]\d{3})*(?:\.\d+)?\b/g;

/** Common phone formats — optional +country, separators (space / dash / dot),
 *  optional area-code parens. Requires enough digits that it's plausibly a
 *  phone (≈7+ total) to avoid eating short standalone numbers. Run before the
 *  generic long-digit `number` pass. */
const PHONE_RE =
  /(?:\+?\d{1,3}[\s.-]?)?(?:\(\d{1,4}\)[\s.-]?)?\d{2,4}(?:[\s.-]\d{2,4}){1,3}\b/g;

/** Long digit runs (>= 7 digits) — IDs / cards / account numbers. Run LAST of
 *  the numeric passes so URLs / emails / money / phones have already consumed
 *  their digits and this only catches the standalone runs that remain. */
const NUMBER_RE = /\b\d{7,}\b/g;

/** Escape a known-name string for safe insertion into a RegExp. */
function escapeRegExp(s: string): string {
  return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

/**
 * Redact PII from `text` for CLOUD egress, returning the redacted text plus
 * per-category counts (ADR-0031 §2). Passes run in a fixed order so categories
 * don't double-count:
 *
 *   1. url    (https?://…)        → [url]
 *   2. email                      → [email]
 *   3. money  ($/€/£/¥ amounts)   → [amount]
 *   4. phone  (common formats)    → [phone]
 *   5. number (\b\d{7,}\b)        → [number]
 *   6. name   (knownNames, word-boundary, case-insensitive) → [name]
 *
 * `counts.total` is the sum of every category. `knownNames` entries that are
 * empty/whitespace are skipped; matching is case-insensitive and word-bounded
 * so "Tuan" doesn't clobber "Tuanda". Names run LAST, after the placeholders
 * are in place (placeholders are bracketed, names are alphabetic — no
 * collision).
 */
export function redact(
  text: string,
  knownNames: string[],
): { text: string; counts: RedactionCounts } {
  const byCategory: Record<string, number> = {
    email: 0,
    phone: 0,
    money: 0,
    number: 0,
    url: 0,
    name: 0,
  };

  let out = text;

  const pass = (re: RegExp, category: Category, placeholder: string): void => {
    out = out.replace(re, () => {
      byCategory[category] = (byCategory[category] ?? 0) + 1;
      return placeholder;
    });
  };

  // Order is load-bearing — see the JSDoc table above.
  pass(URL_RE, 'url', '[url]');
  pass(EMAIL_RE, 'email', '[email]');
  pass(MONEY_RE, 'money', '[amount]');
  pass(PHONE_RE, 'phone', '[phone]');
  pass(NUMBER_RE, 'number', '[number]');

  // Known speaker display-names → [name] (ADR-0031 §2). Word-boundary +
  // case-insensitive. De-duped + sorted longest-first so a longer name is
  // collapsed before a shorter substring of it could partially match.
  const names = Array.from(
    new Set(knownNames.map((n) => n.trim()).filter((n) => n.length > 0)),
  ).sort((a, b) => b.length - a.length);
  for (const name of names) {
    const nameRe = new RegExp(`\\b${escapeRegExp(name)}\\b`, 'gi');
    pass(nameRe, 'name', '[name]');
  }

  const total = Object.values(byCategory).reduce((sum, n) => sum + n, 0);
  return { text: out, counts: { total, byCategory } };
}
