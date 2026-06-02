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
