// LLM API-key store (ADR-0030) — encrypted-at-rest, main-process-only.
//
// The API key is a SECRET. Per ADR-0030 it is encrypted with Electron
// `safeStorage` (on macOS the encryption key is derived from the OS
// Keychain) and the ciphertext is stored — base64 — in a file SEPARATE from
// prefs.json so credentials never sit in the config file:
//   ~/Library/Application Support/Hark/llm-keys.json
//
// Shape on disk: { version: 1, keys: { <provider>: "<base64 ciphertext>" } }
// One entry per provider, so a user can keep e.g. both an Anthropic key and
// an OpenAI key and switch providers without re-entering.
//
// HARD INVARIANTS (privacy-audited surface — CLAUDE.md rules #2/#3, ADR-0030):
//   - getKey() exists ONLY for main to inject into a provider auth header at
//     call time. It is NEVER bridged to the renderer (see preload.ts).
//   - The key is NEVER logged, in plaintext OR ciphertext.
//   - If safeStorage.isEncryptionAvailable() is false we THROW a clear
//     "key storage unavailable" — we NEVER fall back to writing plaintext.
//   - Writes are atomic-ish (temp file + rename) like the prefs writer, so a
//     crash mid-write can't leave a half-written keystore.

import { app, safeStorage } from 'electron';
import * as path from 'node:path';
import * as fs from 'node:fs';
import type { LlmProviderId } from './types';
import { LLM_PROVIDER_IDS } from './types';

/** Thrown when the OS keychain / safeStorage backing is unavailable. The
 *  message is deliberately user-facing and content-free. */
export class KeyStorageUnavailableError extends Error {
  constructor() {
    super('Key storage unavailable (the system keychain could not be reached).');
    this.name = 'KeyStorageUnavailableError';
  }
}

interface KeyStoreFile {
  version: 1;
  /** provider id → base64(safeStorage ciphertext). Partial: only configured
   *  providers appear. */
  keys: Partial<Record<LlmProviderId, string>>;
}

/** Resolve the on-disk keystore path. Pinned to the same app-data dir the
 *  prefs writer uses (~/Library/Application Support/Hark/), but a SEPARATE
 *  file so secrets never mix with config (ADR-0030). */
function keyStorePath(): string {
  return path.join(app.getPath('appData'), 'Hark', 'llm-keys.json');
}

/** Read + parse the keystore. Returns an empty store on any failure (missing,
 *  corrupt, wrong shape) — never throws. Note this returns CIPHERTEXT only;
 *  nothing here is decrypted. */
function readStore(): KeyStoreFile {
  const empty: KeyStoreFile = { version: 1, keys: {} };
  let raw: string;
  try {
    raw = fs.readFileSync(keyStorePath(), 'utf8');
  } catch {
    // Missing/unreadable is the common first-run case.
    return empty;
  }
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    // eslint-disable-next-line no-console
    console.warn('[llm] llm-keys.json is not valid JSON; treating as empty');
    return empty;
  }
  if (typeof parsed !== 'object' || parsed === null) return empty;
  const rawKeys = (parsed as Record<string, unknown>)['keys'];
  const keys: Partial<Record<LlmProviderId, string>> = {};
  if (typeof rawKeys === 'object' && rawKeys !== null) {
    const o = rawKeys as Record<string, unknown>;
    for (const id of LLM_PROVIDER_IDS) {
      const v = o[id];
      // Only carry through valid base64-ish strings keyed by a known provider.
      if (typeof v === 'string' && v.length > 0) {
        keys[id] = v;
      }
    }
  }
  return { version: 1, keys };
}

/** Atomic-ish write (temp file + rename), mirroring the prefs writer. The file
 *  contains ONLY base64 ciphertext — never plaintext. */
function writeStore(store: KeyStoreFile): void {
  const file = keyStorePath();
  const dir = path.dirname(file);
  fs.mkdirSync(dir, { recursive: true });
  const tmp = path.join(dir, `llm-keys.${process.pid}.tmp`);
  fs.writeFileSync(tmp, JSON.stringify(store, null, 2), 'utf8');
  // Restrict to the owner — this is a credential file. Best-effort; on
  // failure the rename below still lands the (encrypted) content.
  try {
    fs.chmodSync(tmp, 0o600);
  } catch {
    /* non-fatal */
  }
  fs.renameSync(tmp, file);
}

/** True iff a key is stored for `provider`. Does NOT decrypt — just checks
 *  for the presence of ciphertext. Safe to call freely (drives `hasKey`). */
export function hasKey(provider: LlmProviderId): boolean {
  return typeof readStore().keys[provider] === 'string';
}

/**
 * Decrypt and return the stored key for `provider`, or null if none.
 * MAIN-PROCESS ONLY — this is never exposed across the contextBridge. Used
 * solely to inject the key into a provider's auth header at call time.
 * Throws KeyStorageUnavailableError if safeStorage can't decrypt (keychain
 * unavailable). The returned plaintext must never be logged.
 */
export function getKey(provider: LlmProviderId): string | null {
  const ciphertextB64 = readStore().keys[provider];
  if (typeof ciphertextB64 !== 'string') return null;
  if (!safeStorage.isEncryptionAvailable()) {
    throw new KeyStorageUnavailableError();
  }
  try {
    const buf = Buffer.from(ciphertextB64, 'base64');
    return safeStorage.decryptString(buf);
  } catch {
    // Corrupt ciphertext or a key bound to a different app identity/machine
    // (ADR-0030 "negative"). Treat as no key rather than leaking details.
    // eslint-disable-next-line no-console
    console.warn(`[llm] could not decrypt stored key for ${provider}`);
    return null;
  }
}

/**
 * Encrypt + persist `key` for `provider`. Throws KeyStorageUnavailableError
 * (and writes NOTHING) if encryption isn't available — we never fall back to
 * plaintext. The key is never logged.
 */
export function setKey(provider: LlmProviderId, key: string): void {
  if (!safeStorage.isEncryptionAvailable()) {
    throw new KeyStorageUnavailableError();
  }
  const ciphertext = safeStorage.encryptString(key);
  const store = readStore();
  store.keys[provider] = ciphertext.toString('base64');
  writeStore(store);
}

/** Remove the stored key for `provider` (no-op if none). Never throws on a
 *  missing entry; a write failure is logged, not thrown. */
export function clearKey(provider: LlmProviderId): void {
  const store = readStore();
  if (!(provider in store.keys)) return;
  delete store.keys[provider];
  try {
    writeStore(store);
  } catch (err) {
    // eslint-disable-next-line no-console
    console.warn('[llm] failed to write keystore while clearing key:', err);
  }
}

/** The absolute path the keystore lands at — for logging/diagnostics only.
 *  Contains the path, never the contents. */
export function getKeyStorePath(): string {
  return keyStorePath();
}
