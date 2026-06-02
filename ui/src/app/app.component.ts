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
import {
  AttendeesPanelComponent,
  TagSpeakerRequest,
} from './components/attendees-panel.component';
import { AskPanelComponent } from './components/ask-panel.component';
import { EyebrowComponent } from './components/eyebrow.component';
import { SpeakerTaggingComponent } from './components/speaker-tagging.component';
import { PostMeetingReviewComponent } from './components/post-meeting-review.component';

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
    SpeakerTaggingComponent,
    PostMeetingReviewComponent,
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

  // ─── Speaker-tagging modal (Slice 3) ────────────────────────────────
  //
  // Opened from the left Attendees column — either the "Who is this?" button
  // on an unlabeled row or a click on an already-named row (re-tag). Holds the
  // speaker being tagged; the modal renames the MOST-RECENTLY-SAVED meeting
  // (ADR-0020 MVP), whose session id we read off EngineService at open time.
  // The optimistic roster update lives in EngineService.renameSpeakers, so
  // both the Attendees panel and the saved card reflect the new name at once.
  readonly taggingTarget = signal<TagSpeakerRequest | null>(null);

  /** The session id the modal renames — the most-recently-saved meeting.
   *  Read live so it stays correct if a newer meeting lands while open. */
  readonly taggingSessionId = computed(
    () => this.engine.lastMeetingSaved()?.session_id ?? null,
  );

  /** Chip color token for the modal, matching this speaker's roster color. */
  readonly taggingChipColor = computed(() => {
    const t = this.taggingTarget();
    return t ? `var(--sp-${(t.index % 6) + 1})` : 'var(--text-3)';
  });

  /** Open the modal for a speaker. No-op if there's no saved meeting to rename
   *  (the roster — hence the modal trigger — only exists when one is saved). */
  onTagSpeaker(req: TagSpeakerRequest): void {
    if (this.taggingSessionId() === null) return;
    this.taggingTarget.set(req);
  }

  /** Esc / backdrop / Cancel / × — close the modal. */
  closeTagging(): void {
    this.taggingTarget.set(null);
  }

  /** Modal reported a successful save. The service already applied the
   *  optimistic roster update (so the panels refreshed); we just close. */
  onSpeakerTagged(): void {
    this.taggingTarget.set(null);
  }

  // ─── Post-Meeting Review screen (verify-by-ear speaker tagging) ──────
  //
  // A full-window takeover opened from the saved-confirmation card's
  // "Review & tag" affordance, which the card shows ONLY when the meeting
  // kept its audio (audio_path non-null, ADR-0027/0028). The screen plays the
  // recorded audio (read by main from the validated vault path), lets the user
  // click an utterance to hear that moment, and tag speakers by ear via the
  // SAME EngineService.renameSpeakers path the modal/card use. When audio
  // wasn't kept the affordance is absent and the existing inline-roster /
  // tagging-modal path stays the fallback (unchanged).
  readonly reviewOpen = signal(false);

  /** The meeting the review screen is reviewing — the live retained payload,
   *  so an optimistic rename made inside the review flows back here and the
   *  roster/utterances re-derive. Null once cleared (New meeting / Start). */
  readonly reviewMeeting = computed<MeetingSavedPayload | null>(
    () => this.engine.lastMeetingSaved(),
  );

  /** The review screen's rename target — the reviewed meeting's session id. */
  readonly reviewSessionId = computed(
    () => this.engine.lastMeetingSaved()?.session_id ?? null,
  );

  /** Open the review screen. Guarded: a meeting must be saved AND have kept
   *  its audio (the card only shows the trigger then, but we re-check so a
   *  stray call can't mount a screen with nothing to play). */
  openReview(): void {
    const saved = this.engine.lastMeetingSaved();
    if (!saved || !saved.audio_path) return;
    this.reviewOpen.set(true);
  }

  /** Esc / × / Done inside the review — return to the main view. Renames
   *  already persisted via the service; nothing else to clean up here (the
   *  component revokes its own object URL on destroy). */
  closeReview(): void {
    this.reviewOpen.set(false);
  }

  /** Auto-close the review if its meeting goes away (New meeting / Start clears
   *  lastMeetingSaved()) so we never leave the takeover mounted with nothing to
   *  review. The template also guards with `@if (reviewMeeting())`, so this is
   *  belt-and-braces — it keeps `reviewOpen` honest. */
  private readonly _reviewGuard = effect(() => {
    if (this.reviewOpen() && this.reviewMeeting() === null) {
      this.reviewOpen.set(false);
    }
  });

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

  // ─── Saved-confirmation card (path + speaker roster) ────────────────
  //
  // The card carries actionable content (vault path + the editable roster) so,
  // unlike the bookmark toast, it's retained until the user dismisses it or
  // starts the next capture.
  //
  // SOURCE OF TRUTH: EngineService.lastMeetingSaved(). The card and the left
  // Attendees panel BOTH read this one signal, so an optimistic rename applied
  // in EngineService.renameSpeakers() reflects in both surfaces at once — no
  // divergent local copies. We derive the card's payload directly from the
  // service rather than snapshotting it on the `meeting.saved$` event.
  //
  // Dismissal (× button) is local-only: hiding the card must NOT wipe the
  // shared roster (the Attendees column keeps showing it). We track the
  // session id the user explicitly dismissed; a later `meeting.saved` with a
  // different session id re-reveals the card. onStart / onNewMeeting clear the
  // service signal (via clearTranscript), so the card naturally disappears.
  private readonly dismissedSavedSession = signal<string | null>(null);
  readonly meetingSaved = computed<MeetingSavedPayload | null>(() => {
    const saved = this.engine.lastMeetingSaved();
    if (!saved) return null;
    return saved.session_id === this.dismissedSavedSession() ? null : saved;
  });

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
    // The saved-confirmation card is derived from EngineService
    // .lastMeetingSaved() (see `meetingSaved` computed) — no subscription
    // needed. A fresh `meeting.saved` repopulates that signal, and since its
    // session id differs from any previously-dismissed one, the card reappears.
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

  /** Speaker → palette CSS-var, delegated to the EngineService single source of
   *  truth so the transcript line's chip/name color matches the Attendees panel
   *  for the same speaker. Reads the roster + segments signals internally, so a
   *  rename (which advances the roster label + relabels segments) re-colors both
   *  surfaces together under OnPush. */
  speakerColorFor(label: string | null): string {
    return this.engine.speakerColorFor(label);
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
    // signals it can't reach (the warning banner + the dismiss latch — a new
    // meeting must not stay hidden because a prior one was dismissed).
    this.warning.set(null);
    this.dismissedSavedSession.set(null);
    this.engine.startCapture({
      mic: this.micEnabled(),
      system: this.systemEnabled(),
      language: this.language(),
      // Privacy gates (ADR-0027) from the user's persisted, opt-in-only
      // choices. Off by default ⇒ the engine stores no audio / voiceprints.
      keepAudio: this.prefs.keepAudio(),
      rememberSpeakers: this.prefs.rememberSpeakers(),
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
    this.dismissedSavedSession.set(null);
    // clearTranscript() nulls EngineService.lastMeetingSaved(), so both the
    // card (derived) and the Attendees roster clear together.
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

  /** Dismiss the saved-confirmation card (its × button). Local-only: we latch
   *  the dismissed session id so the card hides WITHOUT clearing the shared
   *  roster (the Attendees panel keeps showing it). A later meeting (different
   *  session id) reappears; "New meeting" / Start reset the latch. */
  dismissMeetingSaved(): void {
    const saved = this.engine.lastMeetingSaved();
    if (saved) this.dismissedSavedSession.set(saved.session_id);
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
