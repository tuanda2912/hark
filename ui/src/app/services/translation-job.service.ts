// TranslationJobService — post-meeting background transcript translation.
//
// When live translation (§3) was active and the meeting stops, translating the
// WHOLE transcript in one shot is slow on a local model (minutes) and opaque
// (no progress, all-or-nothing). This service instead runs it as a BACKGROUND
// job: it splits the clean transcript into small chunks, translates them one at
// a time (each call is fast — no timeout, and a small local model adheres better
// to a short input than one giant prompt), tracks progress as a percentage, and
// on completion persists the assembled translation to the meeting file via the
// engine (the single vault writer) and surfaces a "ready" state. The user keeps
// using the app while it runs.
//
// Layering / privacy: this is an ORCHESTRATOR — it owns no socket and no network.
// Each chunk goes through `LlmService.translateQuiet` → Electron main (the egress
// chokepoint, ADR-0029/0031): a LOCAL model = zero egress; a CLOUD model redacts
// each chunk first + logs metadata-only. Chunks are COARSE (tens of lines), so a
// cloud run logs a handful of `translate` entries, not hundreds. The result is
// written ONLY via `EngineService.writeTranslation` (single writer + git commit).
//
// Jobs queue: if a second meeting stops while one is translating, it queues and
// runs after — each writes to its own `session_id`, so neither is lost.

import { Injectable, computed, inject, signal } from '@angular/core';
import { EngineService } from './engine.service';
import { LlmService } from './llm.service';

/** Public progress state for the active (or just-finished) job. */
export interface TranslationJobState {
  /** The meeting this job translates (its saved file is the write target). */
  readonly sessionId: string;
  /** Human language name being translated INTO (e.g. "Vietnamese"). */
  readonly lang: string;
  /** Total chunks to translate. */
  readonly total: number;
  /** Chunks completed so far. */
  readonly done: number;
  readonly phase: 'running' | 'done' | 'error';
  /** Short, content-free failure detail when phase === 'error'. */
  readonly detail?: string;
}

interface PendingJob {
  readonly sessionId: string;
  readonly lang: string;
  readonly transcript: string;
  readonly knownNames: string[];
}

@Injectable({ providedIn: 'root' })
export class TranslationJobService {
  private readonly llm = inject(LlmService);
  private readonly engine = inject(EngineService);

  /** Transcript lines per chunk. Small enough that each call is quick + a small
   *  local model translates it faithfully; large enough that a meeting is a
   *  handful of chunks (coarse progress + few cloud-log entries). */
  private static readonly LINES_PER_CHUNK = 24;

  /** The active (or most-recently-finished) job, or null when idle / dismissed.
   *  Drives the progress banner. */
  private readonly _job = signal<TranslationJobState | null>(null);
  readonly job = this._job.asReadonly();

  /** 0–100 completion of the active job (0 when idle). */
  readonly percent = computed(() => {
    const j = this._job();
    if (!j || j.total === 0) return 0;
    return Math.round((j.done / j.total) * 100);
  });

  private readonly queue: PendingJob[] = [];
  private running = false;

  /**
   * Enqueue a background translation of `transcript` (the CLEAN post-stop
   * transcript text) into `lang`, to be saved to `sessionId`'s meeting file.
   * No-op for empty input / no language. Returns immediately; progress shows via
   * `job()` / `percent()`.
   */
  start(sessionId: string, lang: string, transcript: string, knownNames: string[]): void {
    if (!sessionId || !lang.trim() || transcript.trim().length === 0) return;
    this.queue.push({ sessionId, lang: lang.trim(), transcript, knownNames });
    void this.drain();
  }

  /** Dismiss the finished/errored banner. No-op while a job is running. */
  dismiss(): void {
    if (this._job()?.phase !== 'running') this._job.set(null);
  }

  // ─── Internals ──────────────────────────────────────────────────────

  private async drain(): Promise<void> {
    if (this.running) return;
    this.running = true;
    try {
      while (this.queue.length > 0) {
        const next = this.queue.shift();
        if (next) await this.run(next);
      }
    } finally {
      this.running = false;
    }
  }

  private async run(j: PendingJob): Promise<void> {
    const chunks = TranslationJobService.chunk(j.transcript);
    if (chunks.length === 0) return;
    this._job.set({ sessionId: j.sessionId, lang: j.lang, total: chunks.length, done: 0, phase: 'running' });

    const out: string[] = [];
    for (let i = 0; i < chunks.length; i++) {
      const res = await this.llm.translateQuiet({
        transcript: chunks[i],
        targetLang: j.lang,
        knownNames: j.knownNames,
      });
      if (!res.ok) {
        // Abort the whole job on a chunk failure — a partial translation written
        // to the vault would be misleading. Surface the content-free detail.
        this._job.update((s) => (s ? { ...s, phase: 'error', detail: res.detail } : s));
        return;
      }
      out.push(res.translation);
      this._job.update((s) => (s ? { ...s, done: i + 1 } : s));
    }

    // Persist via the engine (single vault writer + git commit) — appends the
    // `## Transcript — <lang>` section to this meeting's file.
    this.engine.writeTranslation(j.sessionId, j.lang, out.join('\n'));
    this._job.update((s) => (s ? { ...s, phase: 'done' } : s));
  }

  /** Split a transcript into chunks of up to LINES_PER_CHUNK non-empty lines.
   *  Each chunk is itself a mini "Speaker mm:ss: text" block, so §1's
   *  structure-preserving prompt translates it cleanly; joining the results with
   *  newlines reassembles the full transcript order. */
  private static chunk(transcript: string): string[] {
    const lines = transcript.split('\n').filter((l) => l.trim().length > 0);
    const chunks: string[] = [];
    for (let i = 0; i < lines.length; i += TranslationJobService.LINES_PER_CHUNK) {
      chunks.push(lines.slice(i, i + TranslationJobService.LINES_PER_CHUNK).join('\n'));
    }
    return chunks;
  }
}
