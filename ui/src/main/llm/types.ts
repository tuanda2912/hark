// LLM foundation — shared wire/contract types (Phase 6, Slice 1).
//
// This is the LOCKED contract a parallel renderer agent codes against. The
// renderer declares its own matching TS interfaces; THIS file is the
// main-process source of truth for the IPC payload shapes. Keep the two in
// lockstep — if a field changes here, the renderer's mirror changes too.
//
// Architecture: per ADR-0029 all LLM calls originate in the Electron MAIN
// process (never the Swift engine, never the sandboxed renderer). Per
// ADR-0030 the API key lives encrypted via Electron safeStorage and NEVER
// crosses the contextBridge — the renderer can only learn `hasKey: boolean`.

/**
 * Which provider family a config targets.
 *  - 'anthropic'         → https://api.anthropic.com (x-api-key auth). Key REQUIRED.
 *  - 'openai-compatible' → a configurable baseUrl covering OpenAI / Gemini /
 *    OpenRouter (cloud, key needed) AND Ollama / LM Studio / llama.cpp (local
 *    on localhost, NO key needed → zero egress). Key OPTIONAL.
 */
export type LlmProviderId = 'anthropic' | 'openai-compatible';

/** The set of valid provider ids, used to validate untrusted IPC input. */
export const LLM_PROVIDER_IDS: readonly LlmProviderId[] = ['anthropic', 'openai-compatible'];

/**
 * The non-secret LLM configuration — provider/model/baseUrl. This is the
 * ONLY part persisted to prefs.json (the key lives separately in the
 * encrypted keystore, ADR-0030). `baseUrl` is meaningful only for
 * 'openai-compatible'; it is ignored for 'anthropic' (which has a fixed
 * endpoint).
 */
export interface LlmConfig {
  provider: LlmProviderId;
  model: string;
  baseUrl?: string;
}

/**
 * Status snapshot the renderer reads to drive Settings UI. `hasKey` reflects
 * the keystore for the CURRENT provider; `configured` is the computed
 * "ready to use" flag (rule below). The key itself is NEVER included.
 *
 * `configured` rule:
 *   - 'anthropic'         → hasKey && !!config.model
 *   - 'openai-compatible' → !!config.baseUrl && !!config.model (key optional;
 *     testConnection validates whether a cloud endpoint actually needs one)
 */
export interface LlmStatus {
  configured: boolean;
  hasKey: boolean;
  config: LlmConfig | null;
}

/**
 * Result of a cheap live validation call (testConnection). `detail` is a
 * SHORT, human-readable, content-free message — derived only from the HTTP
 * status / a generic network-failure string. It NEVER echoes a response
 * body, request body, or key (which may contain content / secrets).
 */
export interface LlmTestResult {
  ok: boolean;
  detail: string;
}

// ─── Slice 2: meeting summary (ADR-0031) ──────────────────────────────────
//
// The summary path is the FIRST time user content (transcript text) leaves
// the machine. These shapes are part of the LOCKED contract the renderer
// codes against (window.hark.llm.summarize / getCloudLog). Per ADR-0031:
//   - cloud egress is REDACTED before send + logged; local egress is full
//     transcript, redaction all-zero, still logged (egress: 'local').
//   - the cloud-call log stores METADATA ONLY — never transcript/summary text.

/**
 * A summarize request from the renderer. `transcript` is the (already
 * speaker-back-annotated) meeting text. `knownNames` is the roster's display
 * names so the redactor can collapse them to `[name]` for CLOUD egress
 * (ADR-0031 §2). Both arrive as untrusted IPC data; main coerces them.
 */
export interface SummarizeReq {
  transcript: string;
  knownNames?: string[];
}

/**
 * Per-category redaction tally for the on-screen receipt + the cloud log.
 * `total` = sum of all categories. For a LOCAL (zero-egress) call every count
 * is 0 — nothing was redacted because nothing left the Mac.
 * Category keys: email, phone, money, number, url, name.
 */
export interface RedactionCounts {
  total: number;
  byCategory: Record<string, number>;
}

/**
 * Result of a summarize call. On success the renderer gets the markdown
 * summary plus the egress kind + redaction receipt; on failure a short,
 * content-free `detail` (derived from the HTTP status, never a body).
 */
export type SummarizeResult =
  | {
      ok: true;
      summary: string;
      model: string;
      egress: 'cloud' | 'local';
      redaction: RedactionCounts;
    }
  | { ok: false; detail: string };

// ─── Slice 3: this-meeting Q&A (Phase 6) ──────────────────────────────────
//
// Same egress + redaction discipline as Slice 2's summary: a CLOUD provider
// gets a REDACTED transcript AND a REDACTED question (the question is user
// content leaving the machine too); a LOCAL (loopback) endpoint gets both
// as-is (zero egress, redaction all-zero). Every call appends one
// METADATA-ONLY cloud-log entry with action:'qa' — never the question,
// transcript, or answer text. Part of the LOCKED contract the renderer codes
// against (window.hark.llm.ask).

/**
 * An ask request from the renderer. `question` is the user's free-text
 * question. The grounding context depends on `scope`:
 *
 *   - 'meeting' (default): `transcript` is the (already speaker-back-annotated)
 *     meeting text the model must answer from.
 *   - 'vault' (Phase 6 slice 4c, ADR-0032): `context` is the top-K vault chunk
 *     TEXTS the renderer retrieved from the engine's local RAG index, in
 *     citation order (the model cites them as [1], [2], …). The chunk METADATA
 *     (note paths / offsets) stays in the renderer for source-card rendering —
 *     main only needs the text to build + redact the prompt.
 *
 * `knownNames` is the roster's display names so the redactor can collapse them
 * to `[name]` for CLOUD egress. On the cloud path EVERY piece of user content
 * leaving the machine is redacted: the question AND the transcript (meeting) or
 * the question AND each context chunk (vault). All arrive as untrusted IPC
 * data; main coerces them.
 */
export interface AskReq {
  question: string;
  /** Which knowledge the answer is grounded in. Defaults to 'meeting' when
   *  absent (back-compat with the Slice 3 contract). */
  scope?: 'meeting' | 'vault';
  /** Meeting-scope grounding: the transcript text. Required for 'meeting'. */
  transcript?: string;
  /** Vault-scope grounding: retrieved chunk texts in citation order. Required
   *  for 'vault'. Main numbers them [1..K] in the prompt and redacts each one
   *  for a cloud send. */
  context?: string[];
  knownNames?: string[];
}

/**
 * Result of an ask call. On success the renderer gets the model's `answer`
 * plus the egress kind + a redaction receipt (the SUM of the question's and
 * transcript's per-category counts on the cloud path; all-zero on local).
 * On failure a short, content-free `detail` (derived from the HTTP status,
 * never a body).
 */
export type AskResult =
  | {
      ok: true;
      answer: string;
      model: string;
      egress: 'cloud' | 'local';
      redaction: RedactionCounts;
    }
  | { ok: false; detail: string };

// ─── End-of-meeting transcript translation (Phase 6, BACKLOG translation §1) ──
//
// Same egress + redaction discipline as summarize: CLOUD gets a REDACTED
// transcript + a "translate to <lang>" prompt; LOCAL (loopback) gets the full
// transcript, zero egress. One metadata-only cloud-log entry (action:'translate').
// `targetLang` is a human language NAME the model understands and the vault
// heading uses (e.g. "Thai", "Vietnamese", "English") — never sensitive.

/** A translate request from the renderer: the assembled transcript TEXT, the
 *  target language name, and the roster's applied display-names so the redactor
 *  can collapse them to `[name]` for a CLOUD send. Text only — never audio. */
export interface TranslateReq {
  transcript: string;
  /** Human language name to translate INTO (e.g. "Thai"). */
  targetLang: string;
  knownNames?: string[];
}

/**
 * Result of a translate call. Mirrors SummarizeResult: on success the
 * `translation` text + the egress kind + a redaction receipt (the transcript's
 * per-category counts on cloud; all-zero on local) + the echoed `targetLang`.
 * On failure a short, content-free `detail`.
 */
export type TranslateResult =
  | {
      ok: true;
      translation: string;
      targetLang: string;
      model: string;
      egress: 'cloud' | 'local';
      redaction: RedactionCounts;
    }
  | { ok: false; detail: string };

// ─── Live per-segment translation (ADR-0035, translation §3) ──────────────
//
// Live translation to an ARBITRARY (non-English) target. As each FINALIZED
// segment lands, the renderer sends ITS text here to be translated and shown
// under the original (bilingual live view). Whisper's on-device `.translate`
// only does English (§2); arbitrary targets go through the configured LLM —
// reusing the SAME egress discipline as summarize/translate:
//   - LOCAL (loopback) → send the line as-is, zero egress (the RECOMMENDED setup
//     for live translation).
//   - CLOUD → REDACT the line first (each finalized line is content leaving the
//     machine), and it's an OPT-IN, egress-disclosed mode.
// Logging is AGGREGATED, not per-call: hundreds of lines per meeting would
// flood the 500-entry cloud-log + churn disk. See `recordLiveTranslate` /
// `flushLiveTranslate` in index.ts — one rolled-up `translate-live` entry.

/** A single-segment translate request: the finalized line's TEXT, the target
 *  language NAME (e.g. "Vietnamese"), and the roster's applied display-names so
 *  the redactor can collapse them on a CLOUD send. Live segments are
 *  speaker-unlabeled (diarization is post-stop), so `knownNames` is usually
 *  empty — redaction still runs its pattern detectors. Text only — never audio. */
export interface TranslateSegmentReq {
  text: string;
  /** Human language name to translate INTO (e.g. "Thai"). */
  targetLang: string;
  knownNames?: string[];
}

/**
 * Result of a single-segment translate. Mirrors TranslateResult but lighter —
 * no echoed targetLang/model (the caller knows the target; the egress kind is
 * what matters for the live indicator). On success the `translation` text + the
 * egress kind + a redaction receipt (the line's per-category counts on cloud;
 * all-zero on local). On failure a short, content-free `detail`.
 */
export type TranslateSegmentResult =
  | {
      ok: true;
      translation: string;
      egress: 'cloud' | 'local';
      redaction: RedactionCounts;
    }
  | { ok: false; detail: string };

/**
 * One entry in the local cloud-call activity log (ADR-0031 §4). METADATA
 * ONLY — there is deliberately NO transcript/summary/question/answer field.
 * `inChars` is the length of the text actually SENT (redacted, for cloud);
 * `outChars` the response length; `redactionTotal` mirrors
 * RedactionCounts.total. Local actions are logged too (egress: 'local',
 * redactionTotal: 0) so the user sees the full picture.
 */
export interface CloudCallLogEntry {
  ts: string;
  /** The action that triggered the call: 'summary', 'qa', 'qa-vault',
   *  'translate' (whole transcript), or 'translate-live' (the AGGREGATED
   *  per-segment live-translation roll-up — one entry covers N finalized lines). */
  action: string;
  provider: string;
  model: string;
  egress: 'cloud' | 'local';
  inChars: number;
  outChars: number;
  redactionTotal: number;
  status: 'ok' | 'error';
  detail?: string;
}
