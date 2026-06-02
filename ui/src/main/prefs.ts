// Prefs — lightweight, hand-rolled preferences persistence for the main
// process. No electron-store, no extra npm dependency (project rule):
// a single versioned JSON file under the app-support dir.
//
// Storage location (CLAUDE.md hard rule #2 — app data lives under
// ~/Library/Application Support/Hark/):
//   path.join(app.getPath('appData'), 'Hark', 'prefs.json')
//
// We deliberately do NOT use app.getPath('userData'): that resolves to
// ~/Library/Application Support/<app name>, and this app sets no
// productName/app.setName, so in dev it would be ".../Electron" and when
// packaged ".../hark-ui" — neither is the required ".../Hark/". Building
// the path off appData + a literal "Hark" pins it correctly in every mode.
//
// Robustness contract:
//   - loadPrefs() NEVER throws. Missing file, unreadable file, malformed
//     JSON, or a shape that fails validation all collapse to DEFAULT_PREFS.
//   - savePrefs() validates first (whitelisted keys only), then writes
//     atomically-ish (write to a temp file, then rename over the target)
//     so a crash mid-write can't leave a half-written prefs.json.

import { app } from 'electron';
import * as path from 'node:path';
import * as fs from 'node:fs';
import type { LlmProviderId } from './llm/types';
import { LLM_PROVIDER_IDS } from './llm/types';

/**
 * Versioned prefs schema. Keep this minimal and only add fields that have
 * real backing UI — dead prefs are worse than no prefs. `version` lets a
 * future migration distinguish shapes without guessing.
 */
export interface Prefs {
  readonly version: 1;
  readonly audio: {
    /** Default Mic source toggle, applied at app launch. */
    readonly mic: boolean;
    /** Default System-audio source toggle, applied at app launch. */
    readonly system: boolean;
    /** Default language: ISO-639-1 code, or null for auto-detect. */
    readonly language: string | null;
  };
  /**
   * Whether the user has finished the first-run onboarding flow. Defaults
   * to false, and — crucially — a *missing* field reads as false too (see
   * sanitize). So an old prefs.json from before this field existed, or a
   * fresh install with no file at all, both correctly read as "first run".
   * The renderer flips this true when the user taps "Start using Hark" and
   * persists it; the onboarding overlay never returns after that.
   */
  readonly hasCompletedOnboarding: boolean;
  /**
   * Privacy & data-control flags (ADR-0027). ALL default false — privacy-first.
   * Two govern what the engine stores locally; two govern future sync intent.
   * The engine gates behavior on `keep_audio` / `remember_speakers` in the
   * `capture.start` payload (absent ⇒ false ⇒ nothing sensitive stored). A
   * *missing* `privacy` block — an old prefs.json or fresh install — sanitizes
   * to all-false, so the safe state is the implicit one.
   *
   *  - keepAudio:        store the meeting's audio locally (enables a future
   *                      verify-by-ear review). Off ⇒ audio discarded after
   *                      transcription.
   *  - rememberSpeakers: store voiceprints in vault/.speakers/ so future
   *                      meetings auto-recognize people (ADR-0026). Off ⇒ no
   *                      voiceprints stored or matched.
   *  - syncAudio:        forward-looking — whether a future native sync may
   *                      carry stored audio off this Mac (already gitignored).
   *  - syncSpeakers:     forward-looking — same, for voiceprints.
   */
  readonly privacy: {
    readonly keepAudio: boolean;
    readonly rememberSpeakers: boolean;
    readonly syncAudio: boolean;
    readonly syncSpeakers: boolean;
  };
  /**
   * Last normal (non-maximized/non-fullscreen) window bounds, persisted by
   * the main process so the window reopens where the user left it. Optional
   * and back-compat: a *missing* `window` means "use the default size,
   * centered" (old prefs.json, fresh install, or a session that never
   * resized). `x`/`y` are optional too — present together once the window
   * has moved; absent → open at the default size but let the OS center it.
   * Bounds are validated against the live display layout at restore time
   * (main.ts), so an unplugged external monitor can't strand the window
   * off-screen.
   */
  readonly window?: {
    readonly width: number;
    readonly height: number;
    readonly x?: number;
    readonly y?: number;
  };
  /**
   * LLM provider configuration (ADR-0029/0030, Phase 6). CONFIG ONLY — the
   * API KEY is NEVER stored here; it lives encrypted in the separate
   * llm-keys.json keystore (ADR-0030). Optional + back-compat: a *missing*
   * `llm` block (old prefs.json, fresh install, or a user who hasn't set up an
   * LLM) reads as "unconfigured", which is the safe default — no provider, no
   * egress. The renderer sets this via window.hark.llm.setConfig.
   *
   *  - provider: which provider family ('anthropic' | 'openai-compatible').
   *  - model:    the model id string for that provider.
   *  - baseUrl:  endpoint base for 'openai-compatible' (OpenAI / OpenRouter /
   *              Gemini-compat / Ollama / LM Studio / llama.cpp). Ignored by
   *              'anthropic' (fixed endpoint). Optional.
   */
  readonly llm?: {
    readonly provider: LlmProviderId;
    readonly model: string;
    readonly baseUrl?: string;
  };
}

export const DEFAULT_PREFS: Prefs = {
  version: 1,
  audio: { mic: true, system: true, language: null },
  hasCompletedOnboarding: false,
  // Privacy-first: every sensitive/sync flag is OFF until the user opts in
  // (at onboarding or in Settings → Privacy). ADR-0027.
  privacy: {
    keepAudio: false,
    rememberSpeakers: false,
    syncAudio: false,
    syncSpeakers: false,
  },
};

/** Resolve the on-disk prefs path. Pinned to ~/Library/Application Support/Hark/. */
function prefsPath(): string {
  return path.join(app.getPath('appData'), 'Hark', 'prefs.json');
}

/**
 * Read + parse prefs.json. Returns DEFAULT_PREFS on any failure (missing,
 * corrupt, wrong shape) — never throws, so the renderer always gets a
 * usable object.
 */
export function loadPrefs(): Prefs {
  const file = prefsPath();
  let raw: string;
  try {
    raw = fs.readFileSync(file, 'utf8');
  } catch {
    // Missing or unreadable — first launch is the common case.
    return DEFAULT_PREFS;
  }
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    // Corrupt JSON — fall back rather than crash the app.
    // eslint-disable-next-line no-console
    console.warn('[hark] prefs.json is not valid JSON; using defaults');
    return DEFAULT_PREFS;
  }
  // Normalize through the validator so partial/foreign shapes can't leak in.
  return sanitize(parsed);
}

/**
 * Validate + persist prefs with MERGE semantics. This is the key
 * correctness contract: there are now multiple independent writers —
 *   - the renderer saves `audio` + `hasCompletedOnboarding`, and
 *   - the main process saves `window` bounds (resize/move/close),
 * each sending only *its* slice of the prefs. A naive
 * `sanitize(input) → write` would rebuild the whole object from the
 * partial payload and silently reset every key the caller didn't include
 * (e.g. a window-bounds save would wipe the user's audio toggles and
 * onboarding flag, and vice-versa).
 *
 * So we always: load the current on-disk prefs → overlay only the
 * whitelisted keys that are actually present in `input` → write the merged
 * result. `sanitize` still runs over the merged object as the final trust
 * boundary (drops unknown keys, fixes types), and the write stays
 * atomic-ish (temp file + rename) so readers never see a partial file.
 * Errors are logged, not thrown — a failed save must not take down main.
 */
export function savePrefs(input: unknown): void {
  // Start from what's already persisted so untouched slices survive.
  const existing = loadPrefs();
  const patch = isRecord(input) ? input : {};

  // Overlay only keys the caller actually supplied. `'k' in patch` (not a
  // truthiness check) so an explicit `false` / `null` / `0` still applies;
  // a missing key keeps the existing value. `audio` merges per-field too,
  // so a partial `audio` object can't drop sibling fields.
  const mergedAudio = isRecord(patch['audio'])
    ? { ...existing.audio, ...patch['audio'] }
    : existing.audio;

  // Same per-field merge for the privacy block: a partial `privacy` object
  // can't drop sibling flags (e.g. saving only `keepAudio` keeps the other
  // three at their persisted values).
  const mergedPrivacy = isRecord(patch['privacy'])
    ? { ...existing.privacy, ...patch['privacy'] }
    : existing.privacy;

  const merged: Record<string, unknown> = {
    version: 1,
    audio: mergedAudio,
    hasCompletedOnboarding:
      'hasCompletedOnboarding' in patch
        ? patch['hasCompletedOnboarding']
        : existing.hasCompletedOnboarding,
    privacy: mergedPrivacy,
    window: 'window' in patch ? patch['window'] : existing.window,
    // The `llm` block is treated as a whole-value overlay (like `window`):
    // a partial save that OMITS `llm` keeps the persisted config, and a save
    // that INCLUDES `llm` replaces it wholesale. Per-field merging isn't
    // needed — setConfig always sends the complete {provider, model, baseUrl?}
    // triple, never a fragment. sanitizeLlm below is the final trust boundary.
    llm: 'llm' in patch ? patch['llm'] : existing.llm,
  };

  const clean = sanitize(merged);
  const file = prefsPath();
  const dir = path.dirname(file);
  try {
    fs.mkdirSync(dir, { recursive: true });
    const tmp = path.join(dir, `prefs.${process.pid}.tmp`);
    fs.writeFileSync(tmp, JSON.stringify(clean, null, 2), 'utf8');
    fs.renameSync(tmp, file);
  } catch (err) {
    // eslint-disable-next-line no-console
    console.warn('[hark] failed to save prefs:', err);
  }
}

/** The absolute path prefs.json lands at — handy for logging/diagnostics. */
export function getPrefsPath(): string {
  return prefsPath();
}

/**
 * Coerce arbitrary input into a valid Prefs. This is the trust boundary:
 * anything that crosses IPC from the renderer (or sits on disk) is treated
 * as untrusted `unknown` and rebuilt field-by-field from DEFAULT_PREFS, so
 * a malicious or buggy payload can only ever set the whitelisted keys to
 * type-correct values — never inject extra keys or wrong types.
 */
function sanitize(input: unknown): Prefs {
  const o = isRecord(input) ? input : {};
  const audio = isRecord(o['audio']) ? o['audio'] : {};

  const mic = typeof audio['mic'] === 'boolean' ? audio['mic'] : DEFAULT_PREFS.audio.mic;
  const system =
    typeof audio['system'] === 'boolean' ? audio['system'] : DEFAULT_PREFS.audio.system;
  // Language is an opaque ISO-639-1 string or null. We don't validate it
  // against LANGUAGE_CHOICES here — the renderer owns that list and an
  // unknown code is harmless (the engine treats unknown as auto-detect).
  const language =
    typeof audio['language'] === 'string'
      ? audio['language']
      : audio['language'] === null
        ? null
        : DEFAULT_PREFS.audio.language;

  // Additive, back-compat: a missing (or non-boolean) field is "not yet
  // onboarded" = first run. Only an explicit `true` on disk suppresses
  // the flow, so we never accidentally skip onboarding on a malformed read.
  const hasCompletedOnboarding =
    typeof o['hasCompletedOnboarding'] === 'boolean'
      ? o['hasCompletedOnboarding']
      : DEFAULT_PREFS.hasCompletedOnboarding;

  // Privacy block (ADR-0027). Rebuilt flag-by-flag from DEFAULT_PREFS so a
  // missing block, a partial one, or any non-boolean value collapses to the
  // safe state: false. Only an explicit `true` on disk turns a flag on.
  const privacy = sanitizePrivacy(o['privacy']);

  // Optional window bounds. Only carried through when the whole rect is
  // sane — width/height must be finite positive numbers; x/y are optional
  // but, if present, must be finite numbers (negative is legal: a window on
  // a display to the left of the primary has a negative x). A missing or
  // malformed `window` is simply dropped, so the field stays absent and the
  // caller falls back to the default size. We do NOT clamp to display
  // geometry here — that's resolved against the *live* screen layout at
  // restore time (main.ts), since displays can change between save and load.
  const window = sanitizeWindow(o['window']);

  // Optional LLM config (ADR-0029/0030). Only carried through when the
  // provider is a known enum AND model is a string; otherwise dropped so the
  // field stays absent (= unconfigured = safe, no egress). CONFIG ONLY — there
  // is no key field here to validate.
  const llm = sanitizeLlm(o['llm']);

  const base: Prefs = {
    version: 1,
    audio: { mic, system, language },
    hasCompletedOnboarding,
    privacy,
  };
  const withWindow = window ? { ...base, window } : base;
  return llm ? { ...withWindow, llm } : withWindow;
}

/**
 * Validate the optional LLM config slice (ADR-0029/0030). Returns undefined —
 * dropping the field entirely — unless `provider` is a recognized enum value
 * AND `model` is a non-empty string. `baseUrl`, when present, must be a string
 * (and is only kept then). Anything else collapses to undefined, i.e. the safe
 * "unconfigured" state. This NEVER carries a key: there is no key field in the
 * Prefs schema — secrets live in the encrypted keystore (ADR-0030).
 */
function sanitizeLlm(input: unknown): Prefs['llm'] | undefined {
  if (!isRecord(input)) return undefined;
  const provider = input['provider'];
  const model = input['model'];
  if (typeof provider !== 'string') return undefined;
  if (!(LLM_PROVIDER_IDS as readonly string[]).includes(provider)) return undefined;
  if (typeof model !== 'string' || model.length === 0) return undefined;

  const baseUrl = input['baseUrl'];
  const out: { provider: LlmProviderId; model: string; baseUrl?: string } = {
    provider: provider as LlmProviderId,
    model,
  };
  if (typeof baseUrl === 'string' && baseUrl.length > 0) {
    out.baseUrl = baseUrl;
  }
  return out;
}

/** Validate the privacy block. Each flag is a strict boolean; anything else
 *  (missing, wrong type) falls back to the DEFAULT_PREFS value (all false), so
 *  the privacy-first state is the one a malformed/absent payload yields. */
function sanitizePrivacy(input: unknown): Prefs['privacy'] {
  const p = isRecord(input) ? input : {};
  const flag = (k: keyof Prefs['privacy']): boolean =>
    typeof p[k] === 'boolean' ? (p[k] as boolean) : DEFAULT_PREFS.privacy[k];
  return {
    keepAudio: flag('keepAudio'),
    rememberSpeakers: flag('rememberSpeakers'),
    syncAudio: flag('syncAudio'),
    syncSpeakers: flag('syncSpeakers'),
  };
}

/** Validate the optional window-bounds slice; returns undefined if absent
 *  or unusable so the field stays off the persisted object entirely. */
function sanitizeWindow(input: unknown): Prefs['window'] | undefined {
  if (!isRecord(input)) return undefined;
  const width = input['width'];
  const height = input['height'];
  // Width/height are required and must be positive finite numbers.
  if (!isFinitePositive(width) || !isFinitePositive(height)) return undefined;

  const x = input['x'];
  const y = input['y'];
  // x/y are optional and only kept as a pair (a half-set position is
  // ambiguous — drop both and let the OS center). Negative is valid.
  if (Number.isFinite(x) && Number.isFinite(y)) {
    return { width, height, x: x as number, y: y as number };
  }
  return { width, height };
}

function isFinitePositive(v: unknown): v is number {
  return typeof v === 'number' && Number.isFinite(v) && v > 0;
}

function isRecord(v: unknown): v is Record<string, unknown> {
  return typeof v === 'object' && v !== null && !Array.isArray(v);
}
