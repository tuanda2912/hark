// LLM service — the main-process facade tying together config (prefs.llm),
// the encrypted keystore (ADR-0030), and the provider layer (ADR-0029).
//
// main.ts registers 5 ipcMain.handle channels that delegate straight to the
// functions here. This module owns the `configured` computation and is the
// single place that ever decrypts a key (via keystore.getKey) to hand to a
// provider for testConnection. Per ADR-0029, EVERY outbound LLM byte passes
// through here.

import { loadPrefs, savePrefs } from '../prefs';
import type { LlmConfig, LlmStatus, LlmTestResult, LlmProviderId } from './types';
import { LLM_PROVIDER_IDS } from './types';
import * as keystore from './keystore';
import { KeyStorageUnavailableError } from './keystore';
import { makeProvider } from './provider';

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

/** Absolute keystore path — for diagnostics logging only. */
export { getKeyStorePath } from './keystore';
