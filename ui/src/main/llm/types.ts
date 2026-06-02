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
