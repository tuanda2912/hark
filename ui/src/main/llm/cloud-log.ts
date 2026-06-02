// Cloud-call activity log (ADR-0031 §4) — local, metadata-only.
//
// Every LLM action that could leave the machine (and every local one, marked
// egress: 'local') appends one CloudCallLogEntry here so the user sees the
// full egress picture in Settings → Privacy. Stored as a single versioned JSON
// file under the app-data dir (same resolution prefs.ts / keystore.ts use):
//   ~/Library/Application Support/Hark/cloud-calls.json
//
// HARD INVARIANT (privacy-audited surface — CLAUDE.md #3, ADR-0031 §4):
//   - METADATA ONLY. There is NO transcript/summary/prompt/response field on
//     CloudCallLogEntry, and this module never receives or writes content —
//     only lengths (inChars/outChars), the redaction TOTAL, provider/model
//     ids, the egress kind, and a status. Never a key, never a body.
//   - Writes are atomic-ish (temp file + rename), like prefs/keystore, so a
//     crash mid-write can't leave a half-written log.
//   - The log is capped to the most recent ~500 entries so it can't grow
//     unbounded.

import { app } from 'electron';
import * as path from 'node:path';
import * as fs from 'node:fs';
import type { CloudCallLogEntry } from './types';

/** Keep at most this many of the most-recent entries. */
const MAX_ENTRIES = 500;

interface CloudLogFile {
  version: 1;
  entries: CloudCallLogEntry[];
}

/** Resolve the on-disk log path. Pinned to the same app-data dir prefs.ts /
 *  keystore.ts use (~/Library/Application Support/Hark/). */
function cloudLogPath(): string {
  return path.join(app.getPath('appData'), 'Hark', 'cloud-calls.json');
}

/** Read + parse the log file. Returns an empty log on any failure (missing,
 *  corrupt, wrong shape) — never throws. Only carries through entries that
 *  match the metadata shape, dropping anything foreign. */
function readFile(): CloudLogFile {
  const empty: CloudLogFile = { version: 1, entries: [] };
  let raw: string;
  try {
    raw = fs.readFileSync(cloudLogPath(), 'utf8');
  } catch {
    return empty; // Missing/unreadable — the common first-run case.
  }
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    // eslint-disable-next-line no-console
    console.warn('[llm] cloud-calls.json is not valid JSON; treating as empty');
    return empty;
  }
  if (typeof parsed !== 'object' || parsed === null) return empty;
  const rawEntries = (parsed as Record<string, unknown>)['entries'];
  if (!Array.isArray(rawEntries)) return empty;
  const entries: CloudCallLogEntry[] = [];
  for (const e of rawEntries) {
    const norm = normalizeEntry(e);
    if (norm) entries.push(norm);
  }
  return { version: 1, entries };
}

/** Coerce an untrusted on-disk object into a clean CloudCallLogEntry, or null
 *  if it doesn't look like one. Defensive — the file could be hand-edited or
 *  corrupt; we never trust its shape. */
function normalizeEntry(v: unknown): CloudCallLogEntry | null {
  if (typeof v !== 'object' || v === null) return null;
  const o = v as Record<string, unknown>;
  const egress = o['egress'];
  const status = o['status'];
  if (typeof o['ts'] !== 'string') return null;
  if (typeof o['action'] !== 'string') return null;
  if (typeof o['provider'] !== 'string') return null;
  if (typeof o['model'] !== 'string') return null;
  if (egress !== 'cloud' && egress !== 'local') return null;
  if (status !== 'ok' && status !== 'error') return null;
  if (typeof o['inChars'] !== 'number') return null;
  if (typeof o['outChars'] !== 'number') return null;
  if (typeof o['redactionTotal'] !== 'number') return null;
  const entry: CloudCallLogEntry = {
    ts: o['ts'],
    action: o['action'],
    provider: o['provider'],
    model: o['model'],
    egress,
    inChars: o['inChars'],
    outChars: o['outChars'],
    redactionTotal: o['redactionTotal'],
    status,
  };
  if (typeof o['detail'] === 'string') entry.detail = o['detail'];
  return entry;
}

/** Atomic-ish write (temp file + rename), mirroring prefs/keystore. */
function writeFile(file: CloudLogFile): void {
  const target = cloudLogPath();
  const dir = path.dirname(target);
  fs.mkdirSync(dir, { recursive: true });
  const tmp = path.join(dir, `cloud-calls.${process.pid}.tmp`);
  fs.writeFileSync(tmp, JSON.stringify(file, null, 2), 'utf8');
  fs.renameSync(tmp, target);
}

/**
 * Append one entry to the log (most-recent last) and write it back, capping to
 * the MAX_ENTRIES most recent. METADATA ONLY — the caller must never put
 * content in `entry`. A write failure is logged (content-free), not thrown — a
 * failed log write must never take down a summary the user actually got.
 */
export function appendCloudCall(entry: CloudCallLogEntry): void {
  try {
    const file = readFile();
    file.entries.push(entry);
    if (file.entries.length > MAX_ENTRIES) {
      file.entries = file.entries.slice(file.entries.length - MAX_ENTRIES);
    }
    writeFile(file);
  } catch (err) {
    // eslint-disable-next-line no-console
    console.warn('[llm] failed to append cloud-call log entry:', err);
  }
}

/** Read the full log (most-recent last). Returns [] on any failure. */
export function readCloudLog(): CloudCallLogEntry[] {
  return readFile().entries;
}

/** The absolute path the log lands at — for diagnostics logging only. */
export function getCloudLogPath(): string {
  return cloudLogPath();
}
