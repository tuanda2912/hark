// LLM service — the main-process facade tying together config (prefs.llm),
// the encrypted keystore (ADR-0030), and the provider layer (ADR-0029).
//
// main.ts registers 5 ipcMain.handle channels that delegate straight to the
// functions here. This module owns the `configured` computation and is the
// single place that ever decrypts a key (via keystore.getKey) to hand to a
// provider for testConnection. Per ADR-0029, EVERY outbound LLM byte passes
// through here.

import { loadPrefs, savePrefs } from '../prefs';
import type {
  LlmConfig,
  LlmStatus,
  LlmTestResult,
  LlmProviderId,
  SummarizeReq,
  SummarizeResult,
  AskReq,
  AskResult,
  TranslateReq,
  TranslateResult,
  RedactionCounts,
  CloudCallLogEntry,
} from './types';
import { LLM_PROVIDER_IDS } from './types';
import * as keystore from './keystore';
import { KeyStorageUnavailableError } from './keystore';
import { makeProvider } from './provider';
import { redact } from './redaction';
import { appendCloudCall, readCloudLog } from './cloud-log';

/** Read the persisted LLM config (prefs.llm), or null if unconfigured. The
 *  prefs sanitizer guarantees a valid shape or undefined, so we trust it. */
function readConfig(): LlmConfig | null {
  const llm = loadPrefs().llm;
  if (!llm) return null;
  // baseUrl is optional; carry it through only when present.
  return llm.baseUrl !== undefined
    ? { provider: llm.provider, model: llm.model, baseUrl: llm.baseUrl }
    : { provider: llm.provider, model: llm.model };
}

/**
 * Compute the `configured` flag per the LOCKED contract:
 *   - 'anthropic'         → hasKey && !!model
 *   - 'openai-compatible' → !!baseUrl && !!model  (key OPTIONAL — a local
 *     endpoint needs none; testConnection validates whether a cloud one does)
 */
function computeConfigured(config: LlmConfig | null, hasKey: boolean): boolean {
  if (!config) return false;
  switch (config.provider) {
    case 'anthropic':
      return hasKey && !!config.model;
    case 'openai-compatible':
      return !!config.baseUrl && !!config.model;
    default: {
      const _never: never = config.provider;
      return Boolean(_never);
    }
  }
}

/** Build the status snapshot from current prefs.llm + keystore. The key is
 *  never read here — only its PRESENCE (hasKey). */
export function getStatus(): LlmStatus {
  const config = readConfig();
  // hasKey reflects the CURRENT provider's keystore entry. With no config yet
  // there's no "current provider", so hasKey is false.
  const hasKey = config ? keystore.hasKey(config.provider) : false;
  return {
    configured: computeConfigured(config, hasKey),
    hasKey,
    config,
  };
}

/** Validate an untrusted provider id from IPC. */
function isProviderId(v: unknown): v is LlmProviderId {
  return typeof v === 'string' && (LLM_PROVIDER_IDS as readonly string[]).includes(v);
}

/**
 * Persist provider/model/baseUrl to prefs.llm (CONFIG only — never a key) and
 * return a fresh status. The payload crosses IPC as untrusted data, so we
 * coerce it to a clean LlmConfig before handing it to savePrefs (which
 * re-validates again via sanitizeLlm). An invalid payload throws — the
 * renderer surfaces it; nothing partial is written.
 */
export function setConfig(raw: unknown): LlmStatus {
  const o = (typeof raw === 'object' && raw !== null ? raw : {}) as Record<string, unknown>;
  if (!isProviderId(o['provider'])) {
    throw new Error('invalid LLM provider');
  }
  if (typeof o['model'] !== 'string') {
    throw new Error('invalid LLM model');
  }
  const provider = o['provider'];
  const model = o['model'];
  const baseUrl = typeof o['baseUrl'] === 'string' ? o['baseUrl'] : undefined;

  const llm =
    baseUrl !== undefined ? { provider, model, baseUrl } : { provider, model };
  // Merge-safe partial save: only the `llm` slice is touched; prefs.savePrefs
  // preserves every other section (audio/privacy/window/onboarding).
  savePrefs({ llm });
  return getStatus();
}

/**
 * Encrypt + store the key for the CURRENT provider and return fresh status.
 * Requires a config (so we know which provider the key is for). Propagates
 * KeyStorageUnavailableError (safeStorage off) to the caller, which surfaces a
 * clear "key storage unavailable" — we NEVER fall back to plaintext. The key
 * is never logged.
 */
export function setApiKey(rawKey: unknown): LlmStatus {
  if (typeof rawKey !== 'string' || rawKey.length === 0) {
    throw new Error('invalid API key');
  }
  const config = readConfig();
  if (!config) {
    throw new Error('set a provider before adding a key');
  }
  keystore.setKey(config.provider, rawKey);
  return getStatus();
}

/** Remove the CURRENT provider's stored key and return fresh status. No-op
 *  (still returns status) if there's no config or no stored key. */
export function clearApiKey(): LlmStatus {
  const config = readConfig();
  if (config) {
    keystore.clearKey(config.provider);
  }
  return getStatus();
}

/**
 * Live validation: build the provider from current config + decrypted key and
 * call testConnection. This is the ONLY outbound network in this slice, and it
 * fires only on explicit user invocation (ADR-0029). Returns a content-free
 * LlmTestResult; never throws for an HTTP/network failure (those map to
 * { ok:false, detail }). A KeyStorageUnavailableError (keychain off) IS mapped
 * to a clear result rather than thrown.
 */
export async function testConnection(): Promise<LlmTestResult> {
  const config = readConfig();
  if (!config) {
    return { ok: false, detail: 'No provider configured' };
  }

  let key: string | undefined;
  try {
    // getKey decrypts in main only; the plaintext stays in this scope and is
    // handed straight to the provider — never logged, never returned.
    key = keystore.getKey(config.provider) ?? undefined;
  } catch (err) {
    if (err instanceof KeyStorageUnavailableError) {
      return { ok: false, detail: 'Key storage unavailable' };
    }
    return { ok: false, detail: 'Could not read stored key' };
  }

  const provider = makeProvider(config, key);
  return provider.testConnection();
}

// ─── Summary (Slice 2 — ADR-0031) ─────────────────────────────────────────

/** Upper bound on the summary length. Summaries are concise (TL;DR + a few
 *  bulleted sections), so this is generous headroom, not a target. */
const SUMMARY_MAX_TOKENS = 2_000;

/**
 * System prompt for the meeting summary. Stable across calls (so Anthropic
 * prompt-caches it). Instructs a faithful, structured markdown summary; the
 * user message is the (redacted-if-cloud) transcript. Content-free — safe to
 * keep inline.
 */
const SUMMARY_PROMPT = [
  'You are a meeting-summary assistant. Summarize the transcript the user',
  'provides into clear, faithful Markdown. Use exactly these sections, each as',
  'an H2 heading, omitting a section only if it genuinely has no content:',
  '',
  '## TL;DR',
  'One or two sentences capturing the meeting at a glance.',
  '',
  '## Key points',
  'Bulleted list of the main discussion points.',
  '',
  '## Action items',
  'Bulleted list of concrete next steps. Attribute an owner ONLY if the',
  'transcript explicitly states one; otherwise leave it unattributed.',
  '',
  '## Decisions',
  'Bulleted list of decisions that were actually made.',
  '',
  '## Open questions',
  'Bulleted list of unresolved questions raised.',
  '',
  'Be faithful to the transcript. Do NOT invent facts, names, numbers, owners,',
  'or decisions that are not present. Some entities may appear as redaction',
  'placeholders such as [name], [email], [phone], [amount], [url], or [number];',
  'preserve them verbatim and do not guess what they originally were.',
].join('\n');

/** A LOCAL endpoint is OpenAI-compatible pointed at a loopback host. Anthropic
 *  is always cloud (fixed remote endpoint). A bad/missing baseUrl is treated
 *  as cloud (the safe assumption — never under-redact). */
function isLocalEgress(config: LlmConfig): boolean {
  if (config.provider !== 'openai-compatible') return false;
  const base = config.baseUrl;
  if (typeof base !== 'string' || base.length === 0) return false;
  let host: string;
  try {
    host = new URL(base).hostname;
  } catch {
    return false; // Unparseable → assume cloud (redact).
  }
  // Normalize an IPv6 bracketed form ([::1]) to its inner host.
  const h = host.replace(/^\[|\]$/g, '').toLowerCase();
  return h === 'localhost' || h === '127.0.0.1' || h === '::1';
}

/**
 * Summarize a meeting transcript (ADR-0031). The egress fork is the first
 * decision:
 *   - LOCAL (loopback OpenAI-compatible) → send the FULL transcript, NO
 *     redaction (zero egress, full quality). Redaction counts all zero.
 *   - CLOUD (Anthropic, or remote OpenAI-compatible) → REDACT first
 *     (redact(transcript, knownNames)) and send only the redacted text.
 *
 * Every call — cloud OR local — appends one METADATA-ONLY entry to the
 * cloud-call log (lengths, redaction total, egress, status). On any error we
 * log a status:'error' entry (no content) and return { ok:false, detail }
 * where `detail` is the provider's content-free, status-derived message.
 *
 * PRIVACY: the transcript and the summary are NEVER logged here and NEVER
 * written to the cloud log — only their character lengths. The provider layer
 * guarantees no request/response body leaks into logs or the thrown detail.
 */
export async function summarize(req: SummarizeReq): Promise<SummarizeResult> {
  // Coerce untrusted IPC input.
  const transcript = typeof req?.transcript === 'string' ? req.transcript : '';
  const knownNames = Array.isArray(req?.knownNames)
    ? req.knownNames.filter((n): n is string => typeof n === 'string')
    : [];

  if (transcript.length === 0) {
    return { ok: false, detail: 'Nothing to summarize' };
  }

  const config = readConfig();
  if (!config) {
    return { ok: false, detail: 'No provider configured' };
  }

  const egress: 'cloud' | 'local' = isLocalEgress(config) ? 'local' : 'cloud';

  // Decrypt the key (main-only) to inject into the provider. A local endpoint
  // may legitimately have none — that's fine; only cloud is guaranteed to need
  // it (the provider/endpoint surfaces a 401 if it does and there's none).
  let key: string | undefined;
  try {
    key = keystore.getKey(config.provider) ?? undefined;
  } catch (err) {
    const detail =
      err instanceof KeyStorageUnavailableError
        ? 'Key storage unavailable'
        : 'Could not read stored key';
    logCloudCall({
      action: 'summary',
      config,
      egress,
      inChars: 0,
      outChars: 0,
      redactionTotal: 0,
      status: 'error',
      detail,
    });
    return { ok: false, detail };
  }

  // Fork: redact for cloud, pass through for local (ADR-0031 §1).
  const zeroCounts: RedactionCounts = {
    total: 0,
    byCategory: { email: 0, phone: 0, money: 0, number: 0, url: 0, name: 0 },
  };
  const { text: userText, counts } =
    egress === 'cloud' ? redact(transcript, knownNames) : { text: transcript, counts: zeroCounts };

  const provider = makeProvider(config, key);

  try {
    const { text: summary } = await provider.complete({
      system: SUMMARY_PROMPT,
      user: userText,
      maxTokens: SUMMARY_MAX_TOKENS,
    });
    logCloudCall({
      action: 'summary',
      config,
      egress,
      // inChars = the text actually SENT (redacted, for cloud); never the raw
      // transcript content — just its length.
      inChars: userText.length,
      outChars: summary.length,
      redactionTotal: counts.total,
      status: 'ok',
    });
    return { ok: true, summary, model: config.model, egress, redaction: counts };
  } catch (err) {
    // The provider throws ONLY content-free, status-derived messages (or a
    // generic network/timeout string) — safe to surface + log as `detail`.
    const detail = err instanceof Error ? err.message : 'Summary failed';
    logCloudCall({
      action: 'summary',
      config,
      egress,
      inChars: userText.length,
      outChars: 0,
      redactionTotal: counts.total,
      status: 'error',
      detail,
    });
    return { ok: false, detail };
  }
}

// ─── End-of-meeting transcript translation (BACKLOG translation §1) ─────────

/** Upper bound on a translation. A translation is ~the length of the input, so
 *  this is generous headroom for a typical meeting; a very long transcript may
 *  hit it (single-shot v1 — chunked translation is the documented follow-up). */
const TRANSLATE_MAX_TOKENS = 8_192;

/**
 * System prompt for whole-transcript translation. The target language is
 * interpolated (so it's NOT prompt-cached across languages — fine, translation
 * is infrequent). Instructs a faithful, structure-preserving, line-for-line
 * translation (NOT a summary), and to pass redaction placeholders through
 * verbatim. Content-free.
 */
function translateSystemPrompt(targetLang: string): string {
  return [
    `You are a translator. Translate the meeting transcript the user provides into ${targetLang}.`,
    'Preserve the structure EXACTLY: keep every speaker label and timestamp line as-is (e.g.',
    '"Speaker 1 00:12:") and translate ONLY the spoken text after it. Do NOT summarize, omit,',
    'merge, reorder, or add anything — translate faithfully and completely, line for line. If a',
    'line is already in the target language, keep it. Some entities may appear as redaction',
    'placeholders such as [name], [email], [phone], [amount], [url], or [number]; preserve them',
    'verbatim — never translate, expand, or guess them.',
  ].join('\n');
}

/**
 * Translate a whole meeting transcript into `targetLang` (BACKLOG translation
 * §1). A near-clone of `summarize`'s egress discipline:
 *   - LOCAL (loopback) → send the FULL transcript, NO redaction (zero egress).
 *   - CLOUD → REDACT the transcript first (redact(transcript, knownNames)) and
 *     send only the redacted text.
 * One METADATA-ONLY cloud-log entry (action:'translate'); the transcript and the
 * translation are NEVER logged — only their lengths. On error a content-free,
 * status-derived `{ ok:false, detail }`.
 */
export async function translate(req: TranslateReq): Promise<TranslateResult> {
  const transcript = typeof req?.transcript === 'string' ? req.transcript : '';
  const targetLang = typeof req?.targetLang === 'string' ? req.targetLang.trim() : '';
  const knownNames = Array.isArray(req?.knownNames)
    ? req.knownNames.filter((n): n is string => typeof n === 'string')
    : [];

  if (transcript.length === 0) {
    return { ok: false, detail: 'Nothing to translate' };
  }
  if (targetLang.length === 0) {
    return { ok: false, detail: 'No target language selected' };
  }

  const config = readConfig();
  if (!config) {
    return { ok: false, detail: 'No provider configured' };
  }

  const egress: 'cloud' | 'local' = isLocalEgress(config) ? 'local' : 'cloud';

  let key: string | undefined;
  try {
    key = keystore.getKey(config.provider) ?? undefined;
  } catch (err) {
    const detail =
      err instanceof KeyStorageUnavailableError
        ? 'Key storage unavailable'
        : 'Could not read stored key';
    logCloudCall({
      action: 'translate',
      config,
      egress,
      inChars: 0,
      outChars: 0,
      redactionTotal: 0,
      status: 'error',
      detail,
    });
    return { ok: false, detail };
  }

  // Fork: redact for cloud, pass through for local (zero egress).
  const { text: userText, counts } =
    egress === 'cloud'
      ? redact(transcript, knownNames)
      : { text: transcript, counts: freshZeroCounts() };

  const provider = makeProvider(config, key);

  try {
    const { text: translation } = await provider.complete({
      system: translateSystemPrompt(targetLang),
      user: userText,
      maxTokens: TRANSLATE_MAX_TOKENS,
    });
    logCloudCall({
      action: 'translate',
      config,
      egress,
      inChars: userText.length,
      outChars: translation.length,
      redactionTotal: counts.total,
      status: 'ok',
    });
    return {
      ok: true,
      translation,
      targetLang,
      model: config.model,
      egress,
      redaction: counts,
    };
  } catch (err) {
    const detail = err instanceof Error ? err.message : 'Translation failed';
    logCloudCall({
      action: 'translate',
      config,
      egress,
      inChars: userText.length,
      outChars: 0,
      redactionTotal: counts.total,
      status: 'error',
      detail,
    });
    return { ok: false, detail };
  }
}

// ─── This-meeting Q&A (Slice 3 — Phase 6) ──────────────────────────────────

/** Upper bound on a Q&A answer. Answers are short, grounded responses (not a
 *  full summary), so this is generous headroom, not a target. */
const QA_MAX_TOKENS = 1_024;

/**
 * System prompt for this-meeting Q&A. Stable across calls (so Anthropic
 * prompt-caches it). Grounds the model strictly in the provided transcript —
 * it must answer from what was actually said, may quote/refer to it, and must
 * say it doesn't know rather than invent when the transcript lacks the answer.
 * Content-free — safe to keep inline.
 */
const QA_PROMPT = [
  'You are a meeting Q&A assistant. Answer the user\'s question using ONLY the',
  'meeting transcript provided in the user message. Ground every claim in what',
  'was actually said — quote or refer to the relevant parts of the transcript',
  'when helpful. If the transcript does not contain the information needed to',
  'answer, say plainly that the meeting does not cover it (or that you do not',
  'know based on the transcript) rather than inventing an answer, guessing, or',
  'drawing on outside knowledge. Do NOT fabricate facts, names, numbers,',
  'owners, or decisions that are not present. Some entities may appear as',
  'redaction placeholders such as [name], [email], [phone], [amount], [url], or',
  '[number]; treat them as opaque, preserve them verbatim, and do not guess',
  'what they originally were.',
].join('\n');

/**
 * System prompt for VAULT-scope Q&A (Phase 6 slice 4c, ADR-0032). Grounds the
 * model strictly in the NUMBERED sources (vault chunks the renderer retrieved
 * from the engine's local RAG index) and asks for inline [n] citations matching
 * the source numbers — so the answer's claims deep-link to their source notes.
 * Distinguishes citation markers ([2]) from redaction placeholders ([name]).
 * Stable across calls (Anthropic prompt-caches it). Content-free.
 */
const VAULT_QA_PROMPT = [
  'You are a knowledge-base Q&A assistant. Answer the user\'s question using',
  'ONLY the numbered Sources in the user message — excerpts retrieved from the',
  'user\'s personal notes/vault. Ground every claim in those sources and CITE',
  'them inline with bracketed numbers matching the source numbers, e.g. "The',
  'deadline is Friday [2]." Cite each sentence that draws on a source. If the',
  'sources do not contain the information needed, say plainly that the vault',
  'does not cover it rather than inventing an answer, guessing, or drawing on',
  'outside knowledge. Do NOT fabricate facts, names, numbers, owners, or',
  'decisions that are not present. Some entities may appear as redaction',
  'placeholders such as [name], [email], [phone], [amount], [url], or [number];',
  'treat them as opaque, preserve them verbatim, and do not guess what they',
  'originally were. Keep citation markers like [2] distinct from redaction',
  'placeholders like [name].',
].join('\n');

/**
 * Build the VAULT-scope user message: the question followed by the numbered
 * Sources block ("[1] …", "[2] …") the model cites against. Pure (no network,
 * no redaction) — callers pass the ALREADY-redacted texts on the cloud path, or
 * the raw texts on the local path. Exported for unit testing the numbering.
 */
export function buildVaultUserMessage(question: string, chunkTexts: string[]): string {
  const sources = chunkTexts
    .map((t, i) => `[${i + 1}] ${t.trim()}`)
    .join('\n\n');
  return `Question: ${question}\n\nSources:\n${sources}`;
}

/** A fresh all-zero redaction tally (the local-egress receipt, and the reduce
 *  seed for vault-scope cloud sends). A new object each call so no caller can
 *  mutate a shared one. */
function freshZeroCounts(): RedactionCounts {
  return {
    total: 0,
    byCategory: { email: 0, phone: 0, money: 0, number: 0, url: 0, name: 0 },
  };
}

/**
 * Answer a question about THIS meeting (Slice 3). Mirrors `summarize` exactly,
 * with one difference: the QUESTION is user content too, so on the cloud path
 * BOTH the transcript and the question are redacted independently and their
 * counts are SUMMED into the returned receipt. Egress fork:
 *   - LOCAL (loopback OpenAI-compatible) → send FULL question + transcript, NO
 *     redaction (zero egress, full quality). Redaction counts all zero.
 *   - CLOUD (Anthropic, or remote OpenAI-compatible) → REDACT the question and
 *     the transcript separately and send only the redacted text.
 *
 * Every call — cloud OR local — appends one METADATA-ONLY cloud-log entry
 * (action:'qa'; lengths, summed redaction total, egress, status). On any error
 * we log a status:'error' entry (no content) and return { ok:false, detail }
 * with the provider's content-free, status-derived message.
 *
 * PRIVACY: the question, transcript, and answer are NEVER logged here and
 * NEVER written to the cloud log — only their character lengths. The provider
 * layer guarantees no request/response body leaks into logs or thrown detail.
 */
export async function ask(req: AskReq): Promise<AskResult> {
  // Coerce untrusted IPC input.
  const question = typeof req?.question === 'string' ? req.question : '';
  const scope: 'meeting' | 'vault' = req?.scope === 'vault' ? 'vault' : 'meeting';
  const transcript = typeof req?.transcript === 'string' ? req.transcript : '';
  // Vault-scope context: drop empties so an all-blank list reads as "no
  // context" (the guard below) rather than a prompt full of empty [n] sources.
  const context = Array.isArray(req?.context)
    ? req.context.filter((c): c is string => typeof c === 'string' && c.trim().length > 0)
    : [];
  const knownNames = Array.isArray(req?.knownNames)
    ? req.knownNames.filter((n): n is string => typeof n === 'string')
    : [];

  // The cloud-log action distinguishes the two scopes (honest receipt). Used in
  // every log line below, including the early-return error paths.
  const action = scope === 'vault' ? 'qa-vault' : 'qa';

  if (question.length === 0) {
    return { ok: false, detail: 'No question asked' };
  }
  // Grounding guard depends on scope: vault needs retrieved chunks, meeting
  // needs a transcript. (For vault, an empty list means retrieval found
  // nothing — the host surfaces that before calling, but guard defensively.)
  if (scope === 'vault') {
    if (context.length === 0) {
      return { ok: false, detail: 'No vault context to answer from' };
    }
  } else if (transcript.length === 0) {
    return { ok: false, detail: 'No transcript to answer from' };
  }

  const config = readConfig();
  if (!config) {
    return { ok: false, detail: 'No provider configured' };
  }

  const egress: 'cloud' | 'local' = isLocalEgress(config) ? 'local' : 'cloud';

  // Decrypt the key (main-only) to inject into the provider. A local endpoint
  // may legitimately have none — that's fine; only cloud is guaranteed to need
  // it (the provider/endpoint surfaces a 401 if it does and there's none).
  let key: string | undefined;
  try {
    key = keystore.getKey(config.provider) ?? undefined;
  } catch (err) {
    const detail =
      err instanceof KeyStorageUnavailableError
        ? 'Key storage unavailable'
        : 'Could not read stored key';
    logCloudCall({
      action,
      config,
      egress,
      inChars: 0,
      outChars: 0,
      redactionTotal: 0,
      status: 'error',
      detail,
    });
    return { ok: false, detail };
  }

  // Fork: redact ALL user content for cloud (the question is user content too;
  // for vault, EACH retrieved chunk is vault content leaving the machine); pass
  // everything through for local (zero egress). The receipt SUMS every redacted
  // piece's tally. System prompt + user message are scope-specific.
  let system: string;
  let user: string;
  let counts: RedactionCounts;

  if (egress === 'cloud') {
    const q = redact(question, knownNames);
    if (scope === 'vault') {
      // Redact each chunk independently; sum the question's + every chunk's
      // counts. The model sees only the redacted texts, numbered [1..K].
      const redactedChunks = context.map((c) => redact(c, knownNames));
      counts = [q.counts, ...redactedChunks.map((r) => r.counts)].reduce(
        (acc, c) => sumCounts(acc, c),
        freshZeroCounts(),
      );
      system = VAULT_QA_PROMPT;
      user = buildVaultUserMessage(
        q.text,
        redactedChunks.map((r) => r.text),
      );
    } else {
      const t = redact(transcript, knownNames);
      counts = sumCounts(q.counts, t.counts);
      system = QA_PROMPT;
      user = `Question: ${q.text}\n\nMeeting transcript:\n${t.text}`;
    }
  } else {
    // LOCAL — zero egress: send the full question + grounding context as-is.
    counts = freshZeroCounts();
    if (scope === 'vault') {
      system = VAULT_QA_PROMPT;
      user = buildVaultUserMessage(question, context);
    } else {
      system = QA_PROMPT;
      user = `Question: ${question}\n\nMeeting transcript:\n${transcript}`;
    }
  }

  const provider = makeProvider(config, key);

  try {
    const { text: answer } = await provider.complete({
      system,
      user,
      maxTokens: QA_MAX_TOKENS,
    });
    logCloudCall({
      action,
      config,
      egress,
      // inChars = the length of the text actually SENT (redacted, for cloud) —
      // question + grounding context; never the raw content, just the length.
      inChars: user.length,
      outChars: answer.length,
      redactionTotal: counts.total,
      status: 'ok',
    });
    return { ok: true, answer, model: config.model, egress, redaction: counts };
  } catch (err) {
    // The provider throws ONLY content-free, status-derived messages (or a
    // generic network/timeout string) — safe to surface + log as `detail`.
    const detail = err instanceof Error ? err.message : 'Q&A failed';
    logCloudCall({
      action,
      config,
      egress,
      inChars: user.length,
      outChars: 0,
      redactionTotal: counts.total,
      status: 'error',
      detail,
    });
    return { ok: false, detail };
  }
}

/** Sum two RedactionCounts into one (per-category + total). Used by `ask`,
 *  which redacts the question and the transcript independently and reports the
 *  combined receipt. */
function sumCounts(a: RedactionCounts, b: RedactionCounts): RedactionCounts {
  const byCategory: Record<string, number> = {};
  for (const key of new Set([...Object.keys(a.byCategory), ...Object.keys(b.byCategory)])) {
    byCategory[key] = (a.byCategory[key] ?? 0) + (b.byCategory[key] ?? 0);
  }
  return { total: a.total + b.total, byCategory };
}

/** Build + append a cloud-log entry. METADATA ONLY — callers pass lengths and
 *  ids, never content. The timestamp is stamped here. */
function logCloudCall(args: {
  action: string;
  config: LlmConfig;
  egress: 'cloud' | 'local';
  inChars: number;
  outChars: number;
  redactionTotal: number;
  status: 'ok' | 'error';
  detail?: string;
}): void {
  const entry: CloudCallLogEntry = {
    ts: new Date().toISOString(),
    action: args.action,
    provider: args.config.provider,
    model: args.config.model,
    egress: args.egress,
    inChars: args.inChars,
    outChars: args.outChars,
    redactionTotal: args.redactionTotal,
    status: args.status,
  };
  if (args.detail !== undefined) entry.detail = args.detail;
  appendCloudCall(entry);
}

/** Read the local cloud-call activity log (metadata-only). Drives Settings →
 *  Privacy. Most-recent last; returns [] on any failure. */
export function getCloudLog(): CloudCallLogEntry[] {
  return readCloudLog();
}

/** Absolute keystore path — for diagnostics logging only. */
export { getKeyStorePath } from './keystore';
/** Absolute cloud-call log path — for diagnostics logging only. */
export { getCloudLogPath } from './cloud-log';
