// AppComponent — Phase 4 MainWindow shell.
//
// Top bar (REC + meter + controls + trust lozenge) and the live
// transcript feed: finalized utterances render upright in history,
// in-flight partials float at the bottom italic with a blinking caret
// (the design's live-tail treatment). Tray, Q&A, settings, speaker
// tagging remain follow-up commits per ADR-0010.

import {
  afterRenderEffect,
  ChangeDetectionStrategy,
  Component,
  effect,
  ElementRef,
  HostListener,
  OnDestroy,
  OnInit,
  computed,
  inject,
  signal,
  viewChild,
} from '@angular/core';
import { Subscription } from 'rxjs';
import { EngineService } from './services/engine.service';
import { PreferencesService } from './services/preferences.service';
import { LANGUAGE_CHOICES, DisplayedSegment } from './services/engine.types';
import { TranscriptLineComponent } from './components/transcript-line.component';
import { StatusBannerComponent } from './components/status-banner.component';
import { SettingsPanelComponent } from './components/settings-panel.component';

@Component({
  selector: 'hark-root',
  standalone: true,
  imports: [TranscriptLineComponent, StatusBannerComponent, SettingsPanelComponent],
  templateUrl: './app.component.html',
  styleUrl: './app.component.css',
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class AppComponent implements OnInit, OnDestroy {
  private readonly engine = inject(EngineService);
  private readonly prefs = inject(PreferencesService);

  readonly connection = this.engine.connection;
  readonly capture = this.engine.capture;
  readonly heartbeat = this.engine.heartbeat;
  readonly hello = this.engine.hello;
  readonly ready = this.engine.ready;
  readonly segments = this.engine.segments;
  readonly lastError = this.engine.lastError;

  readonly bookmarks = this.engine.bookmarks;

  /** Connected but the model is still loading — show the warming-up banner
   *  and keep Start disabled until `meta.ready` arrives. */
  readonly warmingUp = computed(() => this.isConnected() && !this.ready());

  /** Latest engine warning (e.g. rtf_high). Shown in a warning banner;
   *  cleared when capture starts or stops so it doesn't linger stale. */
  readonly warning = signal<string | null>(null);
  private warningSub: Subscription | null = null;

  readonly languageChoices = LANGUAGE_CHOICES;
  /** Currently-selected language code; null = auto-detect. */
  readonly language = signal<string | null>(null);

  // Capture source selection, locked at capture.start.
  // NOTE: capturing the mic forces a Bluetooth headset into HFP
  // (hands-free) mode, which kills A2DP playback — so to transcribe
  // audio you're hearing through BT headphones, turn Mic OFF.
  readonly micEnabled = signal(true);
  readonly systemEnabled = signal(true);

  /** Settings modal visibility. Toggled by the gear button + ⌘, . */
  readonly settingsOpen = signal(false);

  /** Seed the live top-bar selections from the persisted defaults once the
   *  prefs have loaded from disk. Runs once: after `loaded()` flips true we
   *  copy the saved values into the live signals, then mark seeded so the
   *  persist effect below can start mirroring user changes back. We can't
   *  seed synchronously because PreferencesService loads over async IPC. */
  private seeded = false;
  private readonly _seedFromPrefs = effect(() => {
    if (this.seeded || !this.prefs.loaded()) return;
    this.micEnabled.set(this.prefs.mic());
    this.systemEnabled.set(this.prefs.system());
    this.language.set(this.prefs.language());
    this.seeded = true;
  });

  /** Persist the live selections as the new defaults whenever the user
   *  changes them — but only while NOT capturing (the toggles + picker are
   *  already locked during capture, so this only fires on deliberate idle
   *  edits) and only after the initial seed (so we never write placeholder
   *  defaults over freshly-loaded prefs). */
  private readonly _persistDefaults = effect(() => {
    const mic = this.micEnabled();
    const system = this.systemEnabled();
    const language = this.language();
    if (!this.seeded || this.isCapturing()) return;
    this.prefs.setAudioDefaults({ mic, system, language });
  });

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

  // ─── Transcript auto-scroll (follow the tail) ───────────────────────
  /** The scrollable transcript container (the <main>). */
  private readonly transcriptScroll =
    viewChild<ElementRef<HTMLElement>>('transcriptScroll');
  /** Whether to keep the view pinned to the newest line. Goes false when the
   *  user scrolls up to read history (so we don't yank them back down), and
   *  true again when they return to the bottom. */
  private followTail = true;
  // Pin to the latest line as the transcript grows — but only while the user
  // is at the bottom. afterRenderEffect runs AFTER the DOM updates, so
  // scrollHeight already reflects the new content; it re-runs only when
  // segments() changes (it never reads the per-second REC tick, so the clock
  // doesn't cause scrolling).
  private readonly _autoscroll = afterRenderEffect(() => {
    this.segments();
    if (!this.followTail) return;
    const el = this.transcriptScroll()?.nativeElement;
    if (el) el.scrollTop = el.scrollHeight;
  });

  // ─── Menu-bar tray state push ───────────────────────────────────────
  // The tray (Electron main) mirrors capture/connection state for its icon
  // and Start/Stop menu-item enablement. State lives here, so we push a
  // snapshot whenever the relevant signals change. window.hark is undefined
  // outside Electron (e.g. bare `ng serve` in a browser), so guard it — the
  // effect simply no-ops there.
  private readonly _trayStatePush = effect(() => {
    const state = {
      capturing: this.isCapturing(),
      ready: this.ready(),
      connected: this.isConnected(),
    };
    window.hark?.setTrayState(state);
  });

  /** Elapsed capture time as HH:MM:SS, derived from capture.startedAt. */
  readonly recCounter = computed(() => this.formatClock(this.elapsedSeconds()));

  ngOnInit(): void {
    this.nowMs.set(Date.now());
    this.timerId = setInterval(() => this.nowMs.set(Date.now()), 1000);
    // Show a transient confirmation when the engine echoes a bookmark back.
    this.bookmarkSub = this.engine.bookmarkCreated$.subscribe((bm) => {
      this.showBookmarkToast(`Bookmark saved at ${this.formatClock(bm.t)}`);
    });
    // Surface the latest engine warning (e.g. rtf_high) in a banner.
    this.warningSub = this.engine.warnings$.subscribe((w) => {
      this.warning.set(w.message);
    });
    // Route tray Start/Stop to the same handlers the top-bar buttons use, so
    // the tray reuses the current source/language selections. No-op when
    // running outside Electron (window.hark undefined). The callback is
    // fire-once registration; the preload whitelists the action strings.
    window.hark?.onTrayAction((action) => {
      if (action === 'start') {
        if (this.canStart()) this.onStart();
      } else if (action === 'stop') {
        this.onStop();
      }
    });
    void this.engine.connect();
  }

  ngOnDestroy(): void {
    if (this.timerId !== null) clearInterval(this.timerId);
    if (this.toastTimer !== null) clearTimeout(this.toastTimer);
    this.bookmarkSub?.unsubscribe();
    this.warningSub?.unsubscribe();
  }

  /** ⌘⇧B — mark the current moment (the design's shortcut). ⌘, — open
   *  Settings (the macOS convention). */
  @HostListener('window:keydown', ['$event'])
  onKeydown(ev: KeyboardEvent): void {
    if (ev.metaKey && ev.shiftKey && ev.key.toLowerCase() === 'b') {
      ev.preventDefault();
      this.onBookmark();
    } else if (ev.metaKey && !ev.shiftKey && ev.key === ',') {
      ev.preventDefault();
      this.openSettings();
    }
  }

  openSettings(): void {
    this.settingsOpen.set(true);
  }

  closeSettings(): void {
    this.settingsOpen.set(false);
  }

  // ─── Template helpers ───────────────────────────────────────────────

  isCapturing(): boolean {
    return this.capture().kind === 'running';
  }

  isConnected(): boolean {
    return this.connection().kind === 'connected';
  }

  /** Start is allowed only when connected, the model is loaded (ready),
   *  idle, and at least one source is selected (capturing nothing makes
   *  no sense). Sending capture.start before ready earns an
   *  ENGINE_WARMING_UP error from the engine, so we gate it client-side. */
  canStart(): boolean {
    return (
      this.isConnected() &&
      this.ready() &&
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

  /** Re-evaluate whether to keep following the tail from the user's scroll
   *  position. Within ~48px of the bottom counts as "at the bottom", so a
   *  user reading back up isn't pulled down by new segments. */
  onTranscriptScroll(): void {
    const el = this.transcriptScroll()?.nativeElement;
    if (!el) return;
    this.followTail = el.scrollHeight - el.scrollTop - el.clientHeight < 48;
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
    this.warning.set(null);
    this.engine.clearSegments();
    this.engine.startCapture({
      mic: this.micEnabled(),
      system: this.systemEnabled(),
      language: this.language(),
    });
  }

  onStop(): void {
    this.warning.set(null);
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
