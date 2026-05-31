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
  HostListener,
  OnDestroy,
  OnInit,
  computed,
  inject,
  signal,
} from '@angular/core';
import { Subscription } from 'rxjs';
import { EngineService } from './services/engine.service';
import { LANGUAGE_CHOICES, DisplayedSegment } from './services/engine.types';
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

  readonly bookmarks = this.engine.bookmarks;

  readonly languageChoices = LANGUAGE_CHOICES;
  /** Currently-selected language code; null = auto-detect. */
  readonly language = signal<string | null>(null);

  // Capture source selection, locked at capture.start.
  // NOTE: capturing the mic forces a Bluetooth headset into HFP
  // (hands-free) mode, which kills A2DP playback — so to transcribe
  // audio you're hearing through BT headphones, turn Mic OFF.
  readonly micEnabled = signal(true);
  readonly systemEnabled = signal(true);

  /** Transient confirmation shown after a bookmark is created. */
  readonly bookmarkToast = signal<string | null>(null);
  private toastTimer: ReturnType<typeof setTimeout> | null = null;
  private bookmarkSub: Subscription | null = null;

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
  readonly recCounter = computed(() => this.formatClock(this.elapsedSeconds()));

  ngOnInit(): void {
    this.nowMs.set(Date.now());
    this.timerId = setInterval(() => this.nowMs.set(Date.now()), 1000);
    // Show a transient confirmation when the engine echoes a bookmark back.
    this.bookmarkSub = this.engine.bookmarkCreated$.subscribe((bm) => {
      this.showBookmarkToast(`Bookmark saved at ${this.formatClock(bm.t)}`);
    });
    void this.engine.connect();
  }

  ngOnDestroy(): void {
    if (this.timerId !== null) clearInterval(this.timerId);
    if (this.toastTimer !== null) clearTimeout(this.toastTimer);
    this.bookmarkSub?.unsubscribe();
  }

  /** ⌘⇧B — mark the current moment. Mirrors the design's shortcut. */
  @HostListener('window:keydown', ['$event'])
  onKeydown(ev: KeyboardEvent): void {
    if (ev.metaKey && ev.shiftKey && ev.key.toLowerCase() === 'b') {
      ev.preventDefault();
      this.onBookmark();
    }
  }

  // ─── Template helpers ───────────────────────────────────────────────

  isCapturing(): boolean {
    return this.capture().kind === 'running';
  }

  isConnected(): boolean {
    return this.connection().kind === 'connected';
  }

  /** Start is allowed only when connected, idle, and at least one source
   *  is selected (capturing nothing makes no sense). */
  canStart(): boolean {
    return (
      this.isConnected() &&
      !this.isCapturing() &&
      (this.micEnabled() || this.systemEnabled())
    );
  }

  toggleMic(): void {
    if (!this.isCapturing()) this.micEnabled.update((v) => !v);
  }

  toggleSystem(): void {
    if (!this.isCapturing()) this.systemEnabled.update((v) => !v);
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

  /** True if any bookmark's moment falls within this segment's range,
   *  so the line shows a pin. This is how a time-only bookmark becomes
   *  visually anchored to the content the user was hearing. */
  isBookmarked(s: DisplayedSegment): boolean {
    return this.bookmarks().some((b) => b.t >= s.tStart && b.t < s.tEnd);
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
    this.engine.startCapture({
      mic: this.micEnabled(),
      system: this.systemEnabled(),
      language: this.language(),
    });
  }

  onStop(): void {
    this.engine.stopCapture();
  }

  onBookmark(): void {
    if (!this.isCapturing()) return;
    this.engine.createBookmark(this.elapsedSeconds());
  }

  /** Seconds since capture start; 0 when not running. */
  private elapsedSeconds(): number {
    const c = this.capture();
    if (c.kind !== 'running') return 0;
    const startedMs = Date.parse(c.startedAt);
    if (Number.isNaN(startedMs)) return 0;
    return Math.max(0, (this.nowMs() - startedMs) / 1000);
  }

  private showBookmarkToast(message: string): void {
    this.bookmarkToast.set(message);
    if (this.toastTimer !== null) clearTimeout(this.toastTimer);
    this.toastTimer = setTimeout(() => this.bookmarkToast.set(null), 2500);
  }

  /** Empty string from the DOM <select> becomes null (auto-detect). */
  onLanguageChange(value: string): void {
    this.language.set(value === '' ? null : value);
  }
}
