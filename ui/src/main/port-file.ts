// Polls ~/Library/Application Support/Hark/engine.port until harkd has
// written the port + pid JSON. ADR-0008 §1 defines this file as the
// canonical port-discovery channel between the UI and the engine.

import { promises as fs } from 'node:fs';
import * as os from 'node:os';
import * as path from 'node:path';

export interface PortFile {
  readonly port: number;
  readonly pid: number;
  readonly version: string;
}

export function portFilePath(): string {
  return path.join(
    os.homedir(),
    'Library',
    'Application Support',
    'Hark',
    'engine.port',
  );
}

/** Read + parse the port file once. Throws if missing or malformed. */
export async function readPortFile(): Promise<PortFile> {
  const p = portFilePath();
  const raw = await fs.readFile(p, 'utf8');
  const parsed = JSON.parse(raw) as unknown;
  if (
    !parsed ||
    typeof parsed !== 'object' ||
    typeof (parsed as PortFile).port !== 'number' ||
    typeof (parsed as PortFile).pid !== 'number' ||
    typeof (parsed as PortFile).version !== 'string'
  ) {
    throw new Error(`malformed engine.port at ${p}`);
  }
  return parsed as PortFile;
}

/**
 * Wait until the port file matches `expectedPid` and is readable.
 *
 * On M1 cold start, harkd can take 90+ seconds to compile WhisperKit's
 * mlmodelc bundles to ANE before writing the port file (see STATUS open
 * thread #15). Default timeout is generous to absorb this.
 */
export async function waitForPortFile(opts: {
  expectedPid: number;
  timeoutMs?: number;
  pollIntervalMs?: number;
}): Promise<PortFile> {
  const timeoutMs = opts.timeoutMs ?? 180_000;
  const interval = opts.pollIntervalMs ?? 250;
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    try {
      const pf = await readPortFile();
      if (pf.pid === opts.expectedPid) return pf;
    } catch {
      // missing or stale — keep polling
    }
    await sleep(interval);
  }
  throw new Error(
    `timed out waiting for engine.port after ${timeoutMs}ms ` +
      `(expected pid=${opts.expectedPid})`,
  );
}

function sleep(ms: number): Promise<void> {
  return new Promise((r) => setTimeout(r, ms));
}
