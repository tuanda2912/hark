// LLM provider wire/IPC types (ADR-0029).
//
// These mirror the contract the Electron MAIN process exposes on
// `window.hark.llm`. The renderer NEVER makes a network call and NEVER sees a
// stored API key — main owns the provider HTTP, encrypts the key via
// safeStorage, and only ever hands the renderer back an `LlmStatus`
// (booleans + the non-secret config) or an `LlmTestResult`.
//
// Keep this file in lockstep with the main-process bridge in `src/main/**`.
// If main adds a field, add it here too — a field "exists" only if both
// sides agree.

/** Which provider family a config targets. */
export type LlmProviderId = 'anthropic' | 'openai-compatible';

/** The non-secret model configuration. Note: NO key here — the key is set
 *  separately via `setApiKey` and never round-trips back to the renderer. */
export interface LlmConfig {
  provider: LlmProviderId;
  model: string;
  /** Base URL for the OpenAI-compatible path (cloud endpoint or a local
   *  model server: Ollama / LM Studio / llama.cpp). Unused for anthropic. */
  baseUrl?: string;
}

/** Snapshot of provider readiness, computed by main. The renderer consumes
 *  these flags as-is — it does not re-derive `configured`. */
export interface LlmStatus {
  /** True when this provider is usable: anthropic needs a saved key + model;
   *  openai-compatible needs a baseUrl + model (key optional). */
  configured: boolean;
  /** Whether a key is currently saved for the active provider. Drives the
   *  "key saved" indicator — the key itself is never exposed. */
  hasKey: boolean;
  /** The current non-secret config, or null if nothing is configured yet. */
  config: LlmConfig | null;
}

/** Result of a `testConnection()` probe — a one-line human-readable verdict. */
export interface LlmTestResult {
  ok: boolean;
  detail: string;
}

// ─── Summarize (Phase 6 slice 2, ADR-0031) ──────────────────────────────
//
// The renderer hands main the transcript TEXT only (never audio/voiceprints).
// `knownNames` are the meeting's applied speaker display-names so main can
// collapse them to their labels before a CLOUD send (so a name like "Tuan"
// doesn't egress as itself). For a LOCAL provider main sends the full
// transcript with no redaction (zero egress). Redaction/egress decisions live
// entirely in main — the renderer only consumes the result.

/** What the renderer sends main to summarize: the assembled transcript text
 *  plus the applied speaker display-names main should collapse on a cloud send.
 *  Text only — never audio. */
export interface SummarizeReq {
  /** The transcript as readable lines (e.g. "Speaker 1 00:12: …"). */
  transcript: string;
  /** Applied speaker display-names for known-name → label collapse (cloud).
   *  Optional / may be empty when no names have been applied yet. */
  knownNames?: string[];
}

/** Per-category redaction tally main computed before a cloud send (all zero
 *  for a local provider). Drives the receipt + the cloud-activity log. */
export interface RedactionCounts {
  /** Total items replaced across all categories. */
  total: number;
  /** Count keyed by category token ("email", "phone", "money", "id", "url",
   *  "name", …). Display-only; categories are main's to define. */
  byCategory: Record<string, number>;
}

/**
 * Result of a `summarize()` call. Discriminated on `ok`:
 *  - success carries the summary markdown, the model that produced it, whether
 *    it went to the cloud or ran locally, and the redaction tally;
 *  - failure carries a one-line human-readable `detail`.
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

// ─── Ask (this-meeting Q&A) (Phase 6 slice 3, ADR-0031) ─────────────────
//
// Same egress model as summarize: the renderer hands main the transcript TEXT
// only (never audio/voiceprints) plus the meeting's applied speaker
// display-names so main can collapse them to labels before a CLOUD send. For a
// LOCAL provider main sends the full transcript with no redaction (zero
// egress). Redaction/egress/logging all live in main — the renderer consumes
// the answer text only and persists nothing.

/** What the renderer sends main to answer a question. The grounding context
 *  depends on `scope`:
 *   - 'meeting' (default): `transcript` — this meeting's assembled text.
 *   - 'vault' (Phase 6 slice 4c): `context` — the top-K vault chunk TEXTS the
 *     renderer retrieved from the engine's local RAG index, in citation order.
 *  Plus the applied speaker display-names main collapses on a cloud send. Text
 *  only — never audio. Keep in lockstep with main's `AskReq`. */
export interface AskReq {
  /** The user's natural-language question. */
  question: string;
  /** Which knowledge to answer from. Defaults to 'meeting' when absent. */
  scope?: 'meeting' | 'vault';
  /** Meeting scope: the transcript as readable lines (e.g. "Speaker 1 00:12: …"). */
  transcript?: string;
  /** Vault scope: retrieved chunk texts in citation order (1-based [n]). Main
   *  numbers + redacts these; the chunk metadata stays renderer-side for the
   *  source cards. */
  context?: string[];
  /** Applied speaker display-names for known-name → label collapse (cloud).
   *  Optional / may be empty when no names have been applied yet. */
  knownNames?: string[];
}

/**
 * Result of an `ask()` call. Discriminated on `ok` (mirrors `SummarizeResult`):
 *  - success carries the answer text, the model that produced it, whether it
 *    went to the cloud or ran locally, and the redaction tally;
 *  - failure carries a one-line human-readable `detail`.
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

/**
 * One row of the local cloud-activity log (ADR-0031). Metadata ONLY — the
 * transcript content is never logged. Both cloud and local actions are
 * recorded (local marked `egress: 'local'`) so the user sees the full picture.
 * Mirrors the `cloud-calls.json` shape main appends to; read-only in the UI.
 */
export interface CloudCallLogEntry {
  /** ISO-8601 timestamp of the call. */
  ts: string;
  /** The action that triggered it, e.g. "summarize". */
  action: string;
  /** Provider id/family, e.g. "anthropic" / "openai-compatible". */
  provider: string;
  /** The model used. */
  model: string;
  /** Whether content actually left the Mac (cloud) or ran locally. */
  egress: 'cloud' | 'local';
  /** Characters sent / received — size only, never content. */
  inChars: number;
  outChars: number;
  /** Total items redacted before send (0 for local). */
  redactionTotal: number;
  /** Whether the call succeeded. */
  status: 'ok' | 'error';
  /** Optional one-line error detail when `status === 'error'`. */
  detail?: string;
}
