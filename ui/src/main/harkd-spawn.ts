// HarkdSpawn — owns the harkd child process from the Electron main side.
//
// Resolves the binary path (dev: from the engine repo's release build;
// prod: from the packaged Resources folder once Phase 5 lands), spawns
// it, plumbs stderr through to main's stdout, and waits for the
// engine.port file to confirm readiness.
//
// On exit (process death or app shutdown), sends SIGTERM and waits up
// to 5 seconds before SIGKILL.

import { spawn, ChildProcess } from 'node:child_process';
import * as path from 'node:path';
import { promises as fs } from 'node:fs';
import { app } from 'electron';
import { waitForPortFile, PortFile } from './port-file';

const SHUTDOWN_GRACE_MS = 5_000;

export interface HarkdHandle {
  readonly port: number;
  readonly pid: number;
  readonly engineVersion: string;
  readonly child: ChildProcess;
  stop(): Promise<void>;
}

/**
 * Locate the harkd executable. Dev: assumes the engine repo has been
 * built via `swift build -c release` and lives at a relative path from
 * the ui project root. Prod (Phase 5): looks in process.resourcesPath.
 */
async function resolveBinaryPath(): Promise<string> {
  if (app.isPackaged) {
    // Packaged: electron-builder `extraResources` copies harkd to
    // Contents/Resources/engine/harkd (see ui/electron-builder.yml). The
    // `engine/` subdir keeps Resources tidy and leaves room for future assets.
    return path.join(process.resourcesPath, 'engine', 'harkd');
  }
  // Dev path: ui/src/main/harkd-spawn.ts → dist/main/harkd-spawn.js when
  // compiled. We resolve relative to the ui directory (one above dist).
  // Layout: <repo>/engine/.build/release/harkd  vs  <repo>/ui/dist/main/
  const candidates = [
    path.resolve(app.getAppPath(), '..', 'engine', '.build', 'release', 'harkd'),
    // Fallback if cwd is the ui dir during ng serve mode.
    path.resolve(process.cwd(), '..', 'engine', '.build', 'release', 'harkd'),
  ];
  for (const c of candidates) {
    try {
      await fs.access(c, fs.constants.X_OK);
      return c;
    } catch {
      // try next
    }
  }
  throw new Error(
    'harkd binary not found. Build it first:\n' +
      '  cd engine && swift build -c release\n' +
      `Tried: ${candidates.join(', ')}`,
  );
}

/** Spawn harkd and wait for it to write engine.port. */
export async function spawnHarkd(): Promise<HarkdHandle> {
  const binary = await resolveBinaryPath();
  // eslint-disable-next-line no-console
  console.log(`[hark] spawning ${binary}`);
  const child = spawn(binary, [], {
    stdio: ['ignore', 'inherit', 'inherit'],
  });

  let exited = false;
  const exitPromise = new Promise<number | null>((resolve) => {
    child.once('exit', (code) => {
      exited = true;
      // eslint-disable-next-line no-console
      console.log(`[hark] harkd exited with code=${code}`);
      resolve(code);
    });
  });

  if (!child.pid) {
    throw new Error('harkd failed to start (no pid assigned)');
  }

  let portFile: PortFile;
  try {
    portFile = await Promise.race([
      waitForPortFile({ expectedPid: child.pid }),
      exitPromise.then((code) => {
        throw new Error(`harkd exited before writing port file (code=${code})`);
      }),
    ]);
  } catch (err) {
    if (!exited) {
      child.kill('SIGTERM');
    }
    throw err;
  }

  // eslint-disable-next-line no-console
  console.log(
    `[hark] harkd ready: pid=${portFile.pid} port=${portFile.port} version=${portFile.version}`,
  );

  return {
    port: portFile.port,
    pid: portFile.pid,
    engineVersion: portFile.version,
    child,
    async stop() {
      if (exited) return;
      child.kill('SIGTERM');
      const killed = await Promise.race([
        exitPromise.then(() => true),
        new Promise<boolean>((r) => setTimeout(() => r(false), SHUTDOWN_GRACE_MS)),
      ]);
      if (!killed) {
        // eslint-disable-next-line no-console
        console.warn('[hark] harkd did not exit on SIGTERM; sending SIGKILL');
        child.kill('SIGKILL');
        await exitPromise;
      }
    },
  };
}
