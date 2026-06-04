// TranslationJobService — post-meeting background transcript translation.
//
// When live translation (§3) was active and the meeting stops, this translates
// the saved transcript into the target language as a BACKGROUND job: it
// translates each utterance's text ONE AT A TIME (per-utterance, so progress is
// smooth — one step per line — and a small local model adheres better to a short
// input), tracks a progress percentage, and on completion sends the ORDERED
// translated lines to the engine, which renders the `## Transcript — <lang>`
// section from its OWN retained structure (same speaker + wall-clock + blockquote
// as the original) — so the translated section is a structural MIRROR of the
// original, not a divergent reconstruction. The user keeps using the app while
// it runs.
//
// Layering / privacy: this is an ORCHESTRATOR — no socket, no network. Each line
// goes through `LlmService.translateSegment` → Electron main (the egress
// chokepoint, ADR-0029/0031): a LOCAL model = zero egress; a CLOUD model redacts
// each line + aggregates a metadata-only log entry. The result is persisted ONLY
// via `EngineService.writeTranslationLines` (the engine is the single vault
// writer + git committer); the engine zips the lines with its retained
// per-utterance label + tStart.
//
// Jobs queue: a second meeting stopping while one is translating runs after —
// each writes to its own `session_id`, so neither is lost.

import { Injectable, computed, inject, signal } from '@angular/core';
import { EngineService } from './engine.service';
import { LlmService } from './llm.service';

/** Public progress state for the active (or just-finished) job. */
export interface TranslationJobState {
  /** The meeting this job translates (its saved file is the write target). */
  readonly sessionId: string;
  /** Human language name being translated INTO (e.g. "Vietnamese"). */
  readonly lang: string;
  /** Total lines (utterances) to translate. */
  readonly total: number;
  /** Lines completed so far. */
  readonly done: number;
  readonly phase: 'running' | 'done' | 'error';
  /** Short, content-free failure detail when phase === 'error'. */
  readonly detail?: string;
}

interface PendingJob {
  readonly sessionId: string;
  readonly lang: string;
  /** Original utterance texts, in the SAME order the engine saved them (so the
   *  engine can zip translated[i] with its retained utterance[i]). */
  readonly texts: readonly string[];
  readonly knownNames: string[];
}

@Injectable({ providedIn: 'root' })
export class TranslationJobService {
  private readonly llm = inject(LlmService);
  private readonly engine = inject(EngineService);

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
   * Enqueue a background translation of `texts` (one entry per saved-transcript
   * utterance, in order) into `lang`, to be saved to `sessionId`'s meeting file.
   * No-op for empty input / no language. Returns immediately; progress shows via
   * `job()` / `percent()`.
   */
  start(sessionId: string, lang: string, texts: readonly string[], knownNames: string[]): void {
    const clean = texts.filter((t) => t.trim().length > 0);
    if (!sessionId || !lang.trim() || clean.length === 0) return;
    this.queue.push({ sessionId, lang: lang.trim(), texts: clean, knownNames });
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
    this._job.set({ sessionId: j.sessionId, lang: j.lang, total: j.texts.length, done: 0, phase: 'running' });

    const out: string[] = [];
    for (let i = 0; i < j.texts.length; i++) {
      // Per-utterance single-line translation (ADR-0035 §3 path): correct prompt
      // for a bare line, LOCAL = zero egress, CLOUD redacts + aggregates the log.
      const res = await this.llm.translateSegment({
        text: j.texts[i],
        targetLang: j.lang,
        knownNames: j.knownNames,
      });
      if (!res.ok) {
        // Abort the whole job on a line failure — a partial translation written
        // to the vault would be misleading. Surface the content-free detail.
        this._job.update((s) => (s ? { ...s, phase: 'error', detail: res.detail } : s));
        this.llm.flushLiveTranslate();
        return;
      }
      // Fall back to the original line if the model returned nothing, so the
      // section never has a blank entry (timestamp/speaker with no body).
      out.push(res.translation.trim().length > 0 ? res.translation.trim() : j.texts[i]);
      this._job.update((s) => (s ? { ...s, done: i + 1 } : s));
    }

    // Persist via the engine: it renders `## Transcript — <lang>` from its OWN
    // retained per-utterance structure (label + wall-clock), zipping in these
    // ordered translated lines — a structural mirror of the original transcript.
    this.engine.writeTranslationLines(j.sessionId, j.lang, out);
    // Commit the aggregated cloud-log roll-up from the per-line sends.
    this.llm.flushLiveTranslate();
    this._job.update((s) => (s ? { ...s, phase: 'done' } : s));
  }
}
