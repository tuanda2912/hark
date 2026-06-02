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
import {
  LANGUAGE_CHOICES,
  DisplayedSegment,
  MeetingSavedPayload,
} from './services/engine.types';
import { TranscriptLineComponent } from './components/transcript-line.component';
import { StatusBannerComponent } from './components/status-banner.component';
import { SettingsPanelComponent } from './components/settings-panel.component';
import { MeetingSavedToastComponent } from './components/meeting-saved-toast.component';
import { ModelLoadingComponent } from './components/model-loading.component';
import { OnboardingComponent } from './components/onboarding.component';
import { AttendeesPanelComponent } from './components/attendees-panel.component';
import { AskPanelComponent } from './components/ask-panel.component';
import { EyebrowComponent } from './components/eyebrow.component';

@Component({
  selector: 'hark-root',
  standalone: true,
  imports: [
    TranscriptLineComponent,
    StatusBannerComponent,
    SettingsPanelComponent,
    MeetingSavedToastComponent,
    ModelLoadingComponent,
    OnboardingComponent,
    AttendeesPanelComponent,
    AskPanelComponent,
    EyebrowComponent,
  ],
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
  readonly modelProgress = this.engine.modelProgress;

  readonly bookmarks = this.engine.bookmarks;

  /** Connected but the model is still loading — show the warming-up banner
   *  and keep Start disabled until `meta.ready` arrives. */
  readonly warmingUp = computed(() => this.isConnected() && !this.ready());

  // ─── First-run onboarding overlay (Slice 2) ─────────────────────────
  //
  // Shown as a full-window takeover ABOVE everything (including the
  // model-loading overlay) on a fresh install. We wait for prefs to finish
  // loading before deciding, so a returning user (flag already true) never
  // sees a flash of onboarding during the async disk read; while loading we
  // show nothing here (the normal shell / model-loading handles that window).
  // After "Start using Hark", PreferencesService.completeOnboarding() flips
  // the persisted flag, this computed goes false, and the overlay unmounts
  // for good. Re-trigger for testing by deleting prefs.json (or its
  // hasCompletedOnboarding key) under ~/Library/Application Support/Hark/.
  readonly showOnboarding = computed(
    () => this.prefs.loaded() && !this.prefs.hasCompletedOnboarding(),
  );

  // ─── First-run "Preparing Hark" overlay + anti-flash gate ───────────
  //
  // A cold start (no cached models) downloads + ANE-compiles for tens of
  // seconds — we show the full-screen ModelLoading overlay for that. But a
  // WARM start (models cached) reaches meta.ready in ~1–2s, and flashing a
  // full-screen loader for a second looks broken. So we gate the overlay:
  //
  //   - As soon as a `meta.model_progress` frame arrives, we're clearly in a
  //     real (cold) warm-up → show immediately, no wait.
  //   - Otherwise, only show once warm-up has lasted longer than the
  //     ANTI_FLASH_MS grace period (a setTimeout armed when warming begins).
  //   - Hide the moment ready() flips true (or warm-up otherwise ends): the
  //     timer is cleared and the flag reset so the next reconnect re-gates.
  //
  // `showLoadingOverlay` is the single gating signal the template reads.
  private static readonly ANTI_FLASH_MS = 800;
  readonly showLoadingOverlay = signal(false);
  private antiFlashTimer: ReturnType<typeof setTimeout> | null = null;

  /** Drives the gate from the two relevant signals. Whenever warm-up state
   *  or progress changes: arm the grace timer on entering warm-up, reveal
   *  immediately once a progress frame lands, and tear everything down on
   *  ready / disconnect. */
  private readonly _overlayGate = effect(() => {
    const warming = this.warmingUp();
    const hasProgress = this.modelProgress() !== null;

    if (!warming) {
      // Ready (or disconnected/idle) — hide and disarm.
      if (this.antiFlashTimer !== null) {
        clearTimeout(this.antiFlashTimer);
        this.antiFlashTimer = null;
      }
      this.showLoadingOverlay.set(false);
      return;
    }

    // A real progress frame means a genuine (cold) warm-up — reveal now,
    // skipping the grace period.
    if (hasProgress) {
      if (this.antiFlashTimer !== null) {
        clearTimeout(this.antiFlashTimer);
        this.antiFlashTimer = null;
      }
      this.showLoadingOverlay.set(true);
      return;
    }

    // Warming with no progress frame yet — arm the grace timer once so a
    // fast warm start doesn't flash. Don't re-arm if it's already running.
    if (this.antiFlashTimer === null) {
      this.antiFlashTimer = setTimeout(() => {
        this.antiFlashTimer = null;
        // Only reveal if we're still warming up when the grace period ends.
        if (this.warmingUp()) this.showLoadingOverlay.set(true);
      }, AppComponent.ANTI_FLASH_MS);
    }
  });

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

  // ─── Side-panel collapse (3-column layout) ──────────────────────────
  //
  // The MainWindow is a 3-column grid: Attendees (left) | Transcript
  // (center) | Ask (right). These flags let the user collapse either side
  // column via the top-bar toggles, keeping the transcript usable. They are
  // ALSO the manual escape hatch on top of the CSS breakpoints in
  // app.component.css, which auto-hide the side columns at narrow widths so
  // the layout never breaks (see 03-mw-compact.png).
  readonly leftPanelOpen = signal(true);
  readonly rightPanelOpen = signal(true);

  toggleLeftPanel(): void {
    this.leftPanelOpen.update((v) => !v);
  }

  toggleRightPanel(): void {
    this.rightPanelOpen.update((v) => !v);
  }

  /**
   * "Who is this?" on an unlabeled attendee — SHELL for Slice 1. The full
   * speaker-tagging modal + auto-recognition is a later slice
   * (SpeakerTagging.jsx; docs/BACKLOG.md). Inline renaming already exists in
   * the meeting-saved card (ADR-0020), so for now we point the user there
   * via a transient hint rather than faking a modal.
   */
  onTagSpeaker(_label: string): void {
    this.showBookmarkToast(
      'Name speakers from the "Meeting saved" card after recording.',
    );
  }

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

  /** Saved-confirmation card (path + speaker roster). Unlike the bookmark
   *  toast it's retained — it carries actionable content the user reads, so
   *  it stays until they dismiss it or start the next capture. */
  readonly meetingSaved = signal<MeetingSavedPayload | null>(null);
  private meetingSavedSub: Subscription | null = null;

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
    // Surface the vault-write confirmation (fired at capture.stop, after
    // diarization). Retained until dismissed or the next capture start.
    this.meetingSavedSub = this.engine.meetingSaved$.subscribe((saved) => {
      this.meetingSaved.set(saved);
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
    if (this.antiFlashTimer !== null) clearTimeout(this.antiFlashTimer);
    this.bookmarkSub?.unsubscribe();
    this.warningSub?.unsubscribe();
    this.meetingSavedSub?.unsubscribe();
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
    // The service-side view (segments, saved card, bookmarks, lastError) is
    // reset inside startCapture(); here we only clear the component-local
    // signals it can't reach (the warning banner + the locally-mirrored
    // meeting-saved card).
    this.warning.set(null);
    this.meetingSaved.set(null);
    this.engine.startCapture({
      mic: this.micEnabled(),
      system: this.systemEnabled(),
      language: this.language(),
    });
  }

  /**
   * "New meeting" — explicit clear of the on-screen transcript between
   * meetings, without starting a capture. Resets the service-side view and
   * the component-local card/banner. Gated by `canClear()` so it can't fire
   * mid-capture. View-only: the saved vault files are untouched.
   */
  onNewMeeting(): void {
    if (!this.canClear()) return;
    this.warning.set(null);
    this.meetingSaved.set(null);
    this.engine.clearTranscript();
  }

  /**
   * The "New meeting" button is allowed only when NOT capturing and there's
   * actually something on screen to clear — either live segments or the
   * retained saved-meeting card. We never let the user wipe a transcript
   * mid-capture.
   */
  canClear(): boolean {
    return (
      !this.isCapturing() &&
      (this.segments().length > 0 || this.meetingSaved() !== null)
    );
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

  /** Dismiss the saved-confirmation card (its × button). */
  dismissMeetingSaved(): void {
    this.meetingSaved.set(null);
  }

  /** Open the vault folder in Finder. Reuses the existing revealVault bridge
   *  (opens the vault root, not the specific file). A reveal-specific-file
   *  IPC is a possible Phase 5.x follow-up. No-op outside Electron. */
  revealVault(): void {
    this.prefs.revealVault();
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
