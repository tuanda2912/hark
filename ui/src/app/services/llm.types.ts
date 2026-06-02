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
