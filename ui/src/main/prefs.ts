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
}

export const DEFAULT_PREFS: Prefs = {
  version: 1,
  audio: { mic: true, system: true, language: null },
  hasCompletedOnboarding: false,
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
 * Validate + persist prefs. Unknown keys are dropped (whitelist via
 * sanitize); the write is atomic-ish: a temp file is fully written and
 * fsync'd-by-rename over the real target, so readers never see a partial
 * file. Errors are logged, not thrown — a failed save must not take down
 * the main process.
 */
export function savePrefs(input: unknown): void {
  const clean = sanitize(input);
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

  return { version: 1, audio: { mic, system, language }, hasCompletedOnboarding };
}

function isRecord(v: unknown): v is Record<string, unknown> {
  return typeof v === 'object' && v !== null && !Array.isArray(v);
}
