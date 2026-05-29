// AppComponent — Phase 4 MainWindow shell.
//
// Top bar (REC + meter + controls + trust lozenge) and the live
// transcript feed: finalized utterances render upright in history,
// in-flight partials float at the bottom italic with a blinking caret
// (the design's live-tail treatment). Tray, Q&A, settings, speaker
// tagging remain follow-up commits per ADR-0010.

import {
  ChangeDetectionStrategy,
  Component,
  OnDestroy,
  OnInit,
  computed,
  inject,
  signal,
} from '@angular/core';
import { EngineService } from './services/engine.service';
import { LANGUAGE_CHOICES } from './services/engine.types';
import { TranscriptLineComponent } from './components/transcript-line.component';

@Component({
  selector: 'hark-root',
  standalone: true,
  imports: [TranscriptLineComponent],
  templateUrl: './app.component.html',
  styleUrl: './app.component.css',
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class AppComponent implements OnInit, OnDestroy {
  private readonly engine = inject(EngineService);

  readonly connection = this.engine.connection;
  readonly capture = this.engine.capture;
  readonly heartbeat = this.engine.heartbeat;
  readonly hello = this.engine.hello;
  readonly segments = this.engine.segments;
  readonly lastError = this.engine.lastError;

  readonly languageChoices = LANGUAGE_CHOICES;
  /** Currently-selected language code; null = auto-detect. */
  readonly language = signal<string | null>(null);

  /** Ticks every second so the REC counter advances. */
  private readonly nowMs = signal<number>(0);
  private timerId: ReturnType<typeof setInterval> | null = null;

  // Finalized utterances (history) vs in-flight partials (live tail).
  readonly finalizedSegments = computed(() =>
    this.segments().filter((s) => s.isFinal),
  );
  readonly liveSegments = computed(() =>
    this.segments().filter((s) => !s.isFinal),
  );

  /** Elapsed capture time as HH:MM:SS, derived from capture.startedAt. */
  readonly recCounter = computed(() => {
    const c = this.capture();
    if (c.kind !== 'running') return '00:00:00';
    const startedMs = Date.parse(c.startedAt);
    if (Number.isNaN(startedMs)) return '00:00:00';
    const elapsed = Math.max(0, (this.nowMs() - startedMs) / 1000);
    return this.formatClock(elapsed);
  });

  ngOnInit(): void {
    this.nowMs.set(Date.now());
    this.timerId = setInterval(() => this.nowMs.set(Date.now()), 1000);
    void this.engine.connect();
  }

  ngOnDestroy(): void {
    if (this.timerId !== null) clearInterval(this.timerId);
  }

  // ─── Template helpers ───────────────────────────────────────────────

  isCapturing(): boolean {
    return this.capture().kind === 'running';
  }

  isConnected(): boolean {
    return this.connection().kind === 'connected';
  }

  connectionLabel(): string {
    const c = this.connection();
    switch (c.kind) {
      case 'idle': return 'idle';
      case 'connecting': return 'connecting…';
      case 'connected': return 'connected';
      case 'disconnected': return `disconnected (${c.reason})`;
      case 'error': return `error: ${c.message}`;
    }
  }

  rtfDisplay(): string {
    const hb = this.heartbeat();
    return hb ? hb.rtf_current.toFixed(2) : '—';
  }

  /** Format a t_start (seconds) as a transcript timestamp HH:MM:SS. */
  formatTime(seconds: number): string {
    return this.formatClock(seconds);
  }

  private formatClock(totalSeconds: number): string {
    const s = Math.floor(totalSeconds % 60);
    const m = Math.floor((totalSeconds / 60) % 60);
    const h = Math.floor(totalSeconds / 3600);
    const pad = (n: number) => String(n).padStart(2, '0');
    return `${pad(h)}:${pad(m)}:${pad(s)}`;
  }

  onStart(): void {
    this.engine.clearSegments();
    this.engine.startCapture({ language: this.language() });
  }

  onStop(): void {
    this.engine.stopCapture();
  }

  /** Empty string from the DOM <select> becomes null (auto-detect). */
  onLanguageChange(value: string): void {
    this.language.set(value === '' ? null : value);
  }
}
