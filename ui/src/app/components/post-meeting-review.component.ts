// PostMeetingReview — the "verify-by-ear" speaker-tagging screen.
//
// Opened from the meeting-saved surface ONLY when the meeting kept its audio
// (lastMeetingSaved().audio_path is non-null — i.e. *Keep audio* was on,
// ADR-0027/0028). It's a full-window takeover: play the recorded meeting audio,
// see each labeled utterance, click a line to hear that exact moment, and
// assign/correct speaker names now that you can hear who's who.
//
// ── What's real ──────────────────────────────────────────────────────
//   - Audio: main reads vault/.audio/<id>.wav (validated, read-only) →
//     bytes cross the bridge → wrapped in a Blob → object URL → <audio>.
//     The object URL is revoked on teardown (ngOnDestroy) so it doesn't leak.
//   - Player: play/pause, a seek scrubber bound to currentTime/duration, and a
//     mm:ss / mm:ss readout. All driven by native <audio> events (timeupdate,
//     loadedmetadata, play/pause, ended), no polling.
//   - Utterances: one row per EngineService.segments() entry (the clean,
//     labeled, post-stop transcript). Click a row → seek to its tStart + play.
//     The row whose [tStart, nextTStart) window holds currentTime is the
//     "now playing" row — highlighted + scrolled into view.
//   - Assignment: a roster editor mirroring the meeting-saved card. Save
//     dispatches speaker.rename for changed rows via the SAME
//     EngineService.renameSpeakers used everywhere else, which optimistically
//     relabels both the roster and the on-screen utterances.
//
// ── What's deferred (honest) ─────────────────────────────────────────
// No waveform, no per-utterance audio trimming, no playback-rate control — the
// MVP plays the whole file and seeks by utterance start. Those are follow-ups.
//
// Token-only styling, OnPush, signals, @if/@for — and strict-CSP-safe (no
// inline event handlers / onload; the <audio> events bind via Angular
// (event)= which compiles to addEventListener, not inline attributes).

import {
  ChangeDetectionStrategy,
  Component,
  ElementRef,
  HostListener,
  OnDestroy,
  afterRenderEffect,
  computed,
  effect,
  inject,
  input,
  output,
  signal,
  viewChild,
} from '@angular/core';
import { EngineService } from '../services/engine.service';
import { MeetingSavedPayload } from '../services/engine.types';
import { EyebrowComponent } from './eyebrow.component';

/** One editable roster row. `label` is the engine-known CURRENT key (the
 *  speaker.rename map key; advances to the applied name after a successful
 *  rename); `name` is the live text the user edits; `i` keeps the palette
 *  index stable across edits. Mirrors the meeting-saved card's RosterRow. */
interface RosterRow {
  readonly label: string;
  readonly name: string;
  readonly i: number;
}

/** Audio loading lifecycle for the player surface. */
type AudioStatus = 'idle' | 'loading' | 'ready' | 'error';

@Component({
  selector: 'hark-post-meeting-review',
  standalone: true,
  changeDetection: ChangeDetectionStrategy.OnPush,
  imports: [EyebrowComponent],
  styles: [
    `
      :host {
        display: block;
      }

      /* A dedicated screen that sits BELOW the persistent "Hark" titlebar
         strip (row 1 of the app shell) — not a full-window takeover — so the
         app header stays consistent across views. Opaque (not a scrim): it
         replaces the main content, it doesn't float over it. */
      .screen {
        position: fixed;
        top: var(--titlebar-h);
        left: 0;
        right: 0;
        bottom: 0;
        z-index: 40;
        display: flex;
        flex-direction: column;
        background: var(--bg);
        color: var(--text);
        font-family: var(--font-ui);
      }

      /* ── Header ─────────────────────────────────────────────────────── */
      /* Secondary header, BELOW the persistent "Hark" titlebar — so no
         traffic-light inset and no drag region here (the strip above owns
         both). Just a clean section header for this screen. */
      .head {
        display: flex;
        align-items: center;
        gap: var(--s-3);
        padding: var(--s-3) var(--s-4);
        background: var(--bg-2);
        border-bottom: 1px solid var(--border);
        flex-shrink: 0;
      }
      .head-text {
        flex: 1;
        min-width: 0;
      }
      .title {
        font-family: var(--font-display);
        font-size: 15px;
        font-weight: 600;
        letter-spacing: -0.01em;
        color: var(--text);
      }
      .subtitle {
        margin-top: 2px;
        font-size: 12px;
        color: var(--text-2);
      }
      /* Interactive header controls must opt out of the drag region or the
         click gets swallowed by window-dragging. */
      .close {
        -webkit-app-region: no-drag;
        flex-shrink: 0;
        display: inline-flex;
        align-items: center;
        justify-content: center;
        width: 30px;
        height: 30px;
        border: none;
        background: transparent;
        color: var(--text-2);
        border-radius: var(--r-input);
        cursor: pointer;
      }
      .close:hover {
        color: var(--text);
        background: var(--highlight);
      }

      /* ── Body: utterances (left) + roster editor (right) ──────────────── */
      .body {
        flex: 1;
        min-height: 0;
        display: grid;
        grid-template-columns: 1fr 300px;
      }
      @media (max-width: 860px) {
        .body {
          grid-template-columns: 1fr;
        }
        .roster-col {
          display: none;
        }
      }

      .utterances {
        min-height: 0;
        overflow-y: auto;
        padding: var(--s-4) var(--s-6);
      }
      .utterances-inner {
        max-width: 720px;
        margin: 0 auto;
        display: flex;
        flex-direction: column;
        gap: 2px;
      }
      .empty {
        color: var(--text-3);
        font-size: 13px;
        text-align: center;
        padding: var(--s-12) 0;
      }

      /* One utterance row — clickable to seek+play that moment. */
      .row {
        display: flex;
        align-items: flex-start;
        gap: var(--s-3);
        padding: 8px 10px;
        border-radius: var(--r-panel);
        border: 1px solid transparent;
        background: transparent;
        text-align: left;
        width: 100%;
        cursor: pointer;
        color: var(--text);
        font-family: var(--font-ui);
      }
      .row:hover {
        background: var(--highlight);
      }
      .row.now-playing {
        background: var(--accent-soft);
        border-color: color-mix(in oklab, var(--accent) 35%, transparent);
      }
      .row-chip {
        width: 8px;
        height: 8px;
        border-radius: 50%;
        flex-shrink: 0;
        margin-top: 6px;
        background: var(--sp-color, var(--text-3));
      }
      .row-main {
        flex: 1;
        min-width: 0;
      }
      .row-meta {
        display: flex;
        align-items: center;
        gap: var(--s-2);
        margin-bottom: 2px;
      }
      .row-speaker {
        font-size: 11px;
        font-weight: 600;
        letter-spacing: 0.06em;
        text-transform: uppercase;
        color: var(--sp-color, var(--text-2));
      }
      .row-time {
        font-family: var(--font-mono);
        font-size: 10.5px;
        color: var(--text-3);
      }
      .row-text {
        font-size: 14px;
        line-height: 1.5;
        color: var(--text);
      }

      /* ── Roster editor column ─────────────────────────────────────────── */
      .roster-col {
        min-height: 0;
        overflow-y: auto;
        border-left: 1px solid var(--border);
        background: var(--bg-2);
        padding: var(--s-4);
        display: flex;
        flex-direction: column;
        gap: var(--s-3);
      }
      .roster-hint {
        font-size: 12px;
        color: var(--text-2);
        line-height: 1.5;
      }
      .roster {
        display: flex;
        flex-direction: column;
        gap: var(--s-2);
        margin: 0;
        padding: 0;
        list-style: none;
      }
      .roster-row {
        display: flex;
        align-items: center;
        gap: var(--s-2);
      }
      .roster-chip {
        width: 10px;
        height: 10px;
        border-radius: 50%;
        flex-shrink: 0;
        background: var(--sp-color);
      }
      .name-input {
        flex: 1;
        min-width: 0;
        font-family: var(--font-ui);
        font-size: 13px;
        color: var(--text);
        padding: 5px 9px;
        background: var(--surface);
        border: 1px solid var(--border-2);
        border-radius: var(--r-input);
        outline: none;
      }
      .name-input::placeholder {
        color: var(--text-3);
      }
      .name-input:focus {
        border-color: var(--accent);
        box-shadow: 0 0 0 3px var(--accent-soft);
      }
      .roster-foot {
        display: flex;
        align-items: center;
        gap: var(--s-2);
        margin-top: auto;
        padding-top: var(--s-3);
      }
      .saved-note {
        display: inline-flex;
        align-items: center;
        gap: 4px;
        margin-right: auto;
        font-size: 11px;
        color: var(--status-success);
      }
      /* Cancel / Save are icon buttons — labelled via the native title
         tooltip (shown on hover) + an aria-label for assistive tech. Clearly
         button-shaped (bordered) so they don't read as bare glyphs. */
      .icon-btn {
        flex-shrink: 0;
        display: inline-flex;
        align-items: center;
        justify-content: center;
        width: 34px;
        height: 34px;
        border-radius: var(--r-input);
        border: 1px solid var(--border-2);
        background: var(--surface);
        color: var(--text-2);
        cursor: pointer;
      }
      .icon-btn:hover:not(:disabled) {
        color: var(--text);
        background: var(--highlight);
      }
      .icon-btn:disabled {
        opacity: 0.5;
        cursor: not-allowed;
      }
      /* Save is the primary action — accent-tinted to stand out from Cancel. */
      .save-btn {
        border-color: var(--accent);
        background: var(--accent-soft);
        color: var(--accent);
      }
      .save-btn:hover:not(:disabled) {
        background: color-mix(in oklab, var(--accent) 22%, transparent);
        color: var(--accent);
      }

      /* ── Player (footer transport) ────────────────────────────────────── */
      .player {
        display: flex;
        align-items: center;
        gap: var(--s-3);
        padding: var(--s-3) var(--s-4);
        background: var(--bg-2);
        border-top: 1px solid var(--border);
        flex-shrink: 0;
      }
      .play-btn {
        flex-shrink: 0;
        display: inline-flex;
        align-items: center;
        justify-content: center;
        width: 38px;
        height: 38px;
        border-radius: 50%;
        border: 1px solid var(--accent);
        background: var(--accent-soft);
        color: var(--accent);
        cursor: pointer;
      }
      .play-btn:disabled {
        opacity: 0.45;
        cursor: not-allowed;
      }
      .play-btn:hover:not(:disabled) {
        background: color-mix(in oklab, var(--accent) 22%, transparent);
      }
      .scrubber {
        flex: 1;
        min-width: 0;
        appearance: none;
        -webkit-appearance: none;
        height: 4px;
        border-radius: 999px;
        background: var(--border-2);
        cursor: pointer;
        outline: none;
      }
      .scrubber:disabled {
        opacity: 0.5;
        cursor: not-allowed;
      }
      .scrubber::-webkit-slider-thumb {
        -webkit-appearance: none;
        appearance: none;
        width: 13px;
        height: 13px;
        border-radius: 50%;
        background: var(--accent);
        border: 2px solid var(--bg-2);
        cursor: pointer;
      }
      .scrubber::-moz-range-thumb {
        width: 13px;
        height: 13px;
        border: 2px solid var(--bg-2);
        border-radius: 50%;
        background: var(--accent);
        cursor: pointer;
      }
      .readout {
        flex-shrink: 0;
        font-family: var(--font-mono);
        font-size: 11px;
        color: var(--text-2);
        white-space: nowrap;
      }
      .player-status {
        flex-shrink: 0;
        font-size: 12px;
        color: var(--text-3);
      }
      .player-status.error {
        color: var(--status-recording);
      }

      .local-badge {
        display: inline-flex;
        align-items: center;
        gap: 4px;
        font-family: var(--font-mono);
        font-size: 10px;
        letter-spacing: 0.02em;
        color: var(--text-3);
      }
    `,
  ],
  template: `
    <div class="screen" role="dialog" aria-modal="true" aria-label="Review meeting and tag speakers">
      <!-- Header -->
      <div class="head">
        <div class="head-text">
          <div class="title">Review &amp; tag speakers</div>
          <div class="subtitle">
            Play the recording, click a line to jump there, and name each voice
            now that you can hear them.
          </div>
        </div>
        <span class="local-badge" title="The audio was read from your vault on this Mac. Nothing left your device.">
          <svg viewBox="0 0 24 24" width="11" height="11" fill="none"
            stroke="currentColor" stroke-width="1.8" stroke-linecap="round"
            stroke-linejoin="round" aria-hidden="true">
            <rect x="5" y="11" width="14" height="9" rx="2" />
            <path d="M8 11V8a4 4 0 0 1 8 0v3" />
          </svg>
          on this Mac
        </span>
        <button type="button" class="close" (click)="onClose()" title="Close — back to meeting (Esc)" aria-label="Close review">
          <svg viewBox="0 0 24 24" width="16" height="16" fill="none"
            stroke="currentColor" stroke-width="2" stroke-linecap="round" aria-hidden="true">
            <path d="M6 6l12 12M18 6L6 18" />
          </svg>
        </button>
      </div>

      <!-- Body: utterance list + roster editor -->
      <div class="body">
        <div #utterancesScroll class="utterances">
          <div class="utterances-inner">
            @if (segments().length === 0) {
              <div class="empty">No transcript utterances to review.</div>
            } @else {
              @for (s of segments(); track s.utteranceId; let i = $index) {
                <button
                  type="button"
                  class="row"
                  [class.now-playing]="i === nowPlayingIndex()"
                  [attr.data-row-index]="i"
                  [style.--sp-color]="speakerColor(s.speaker)"
                  (click)="onRowClick(s.tStart)"
                  [title]="'Play from ' + formatTime(s.tStart)"
                >
                  <span class="row-chip" aria-hidden="true"></span>
                  <span class="row-main">
                    <span class="row-meta">
                      @if (s.speaker) {
                        <span class="row-speaker">{{ s.speaker }}</span>
                      }
                      <span class="row-time">{{ formatTime(s.tStart) }}</span>
                    </span>
                    <span class="row-text">{{ s.text }}</span>
                  </span>
                </button>
              }
            }
          </div>
        </div>

        <!-- Roster editor (mirrors the meeting-saved card). -->
        <aside class="roster-col">
          <hark-eyebrow>Speakers</hark-eyebrow>
          <p class="roster-hint">
            Name each voice you recognize. Saving renames them across the saved
            transcript.
          </p>
          @if (rows().length > 0) {
            <ul class="roster">
              @for (row of rows(); track row.i; let i = $index) {
                <li class="roster-row">
                  <span class="roster-chip" [style.--sp-color]="speakerColorByIndex(row.i)" aria-hidden="true"></span>
                  <input
                    class="name-input"
                    type="text"
                    [value]="row.name"
                    [placeholder]="row.label"
                    [attr.aria-label]="'Name for ' + row.label"
                    (input)="onNameInput(i, $any($event.target).value)"
                    (keydown.enter)="applyNames()"
                  />
                </li>
              }
            </ul>
          }
          <div class="roster-foot">
            @if (savedConfirmed()) {
              <span class="saved-note" aria-live="polite">
                <svg viewBox="0 0 24 24" width="12" height="12" fill="none"
                  stroke="currentColor" stroke-width="2.4" stroke-linecap="round"
                  stroke-linejoin="round" aria-hidden="true">
                  <path d="M20 6 9 17l-5-5" />
                </svg>
                Saved
              </span>
            }
            @if (rows().length > 0) {
              <button
                type="button"
                class="icon-btn cancel-btn"
                (click)="onClose()"
                title="Cancel — discard name changes and go back"
                aria-label="Cancel and go back"
              >
                <svg viewBox="0 0 24 24" width="16" height="16" fill="none"
                  stroke="currentColor" stroke-width="2" stroke-linecap="round"
                  stroke-linejoin="round" aria-hidden="true">
                  <path d="M19 12H5M12 19l-7-7 7-7" />
                </svg>
              </button>
              <button
                type="button"
                class="icon-btn save-btn"
                [disabled]="!hasChanges()"
                (click)="applyNames()"
                title="Save — rename these speakers across the saved transcript"
                aria-label="Save names"
              >
                <svg viewBox="0 0 24 24" width="16" height="16" fill="none"
                  stroke="currentColor" stroke-width="2.4" stroke-linecap="round"
                  stroke-linejoin="round" aria-hidden="true">
                  <path d="M20 6 9 17l-5-5" />
                </svg>
              </button>
            }
          </div>
        </aside>
      </div>

      <!-- Player transport -->
      <div class="player">
        <button
          type="button"
          class="play-btn"
          [disabled]="audioStatus() !== 'ready'"
          (click)="togglePlay()"
          [title]="playing() ? 'Pause' : 'Play'"
          [attr.aria-label]="playing() ? 'Pause' : 'Play'"
        >
          @if (playing()) {
            <svg viewBox="0 0 24 24" width="16" height="16" fill="currentColor" aria-hidden="true">
              <rect x="6" y="5" width="4" height="14" rx="1" />
              <rect x="14" y="5" width="4" height="14" rx="1" />
            </svg>
          } @else {
            <svg viewBox="0 0 24 24" width="16" height="16" fill="currentColor" aria-hidden="true">
              <path d="M8 5.14v13.72a.6.6 0 0 0 .92.5l10.7-6.86a.6.6 0 0 0 0-1l-10.7-6.86a.6.6 0 0 0-.92.5z" />
            </svg>
          }
        </button>

        <input
          class="scrubber"
          type="range"
          min="0"
          [max]="duration() || 0"
          step="0.1"
          [value]="currentTime()"
          [disabled]="audioStatus() !== 'ready'"
          aria-label="Seek"
          (input)="onScrub($any($event.target).value)"
        />

        <span class="readout">{{ readout() }}</span>

        @if (audioStatus() === 'loading') {
          <span class="player-status">Loading audio…</span>
        } @else if (audioStatus() === 'error') {
          <span class="player-status error" title="The recording couldn't be loaded.">
            Audio unavailable
          </span>
        }
      </div>

      <!-- The actual media element. Hidden (controls live in the transport
           above); its src is set imperatively from the object URL so we never
           put a blob: URL in the template / interpolation. preload metadata so
           duration is known before play. -->
      <audio
        #audio
        preload="metadata"
        (loadedmetadata)="onLoadedMetadata()"
        (timeupdate)="onTimeUpdate()"
        (play)="onPlayEvent()"
        (pause)="onPauseEvent()"
        (ended)="onEnded()"
        (error)="onAudioError()"
        style="display:none"
      ></audio>
    </div>
  `,
})
export class PostMeetingReviewComponent implements OnDestroy {
  private readonly engine = inject(EngineService);

  /** The saved meeting being reviewed. `audio_path` is guaranteed non-null by
   *  the host (the entry point only mounts this when audio was kept), but we
   *  re-guard defensively before reading. */
  readonly saved = input.required<MeetingSavedPayload>();
  /** The most-recently-saved meeting's session id — the speaker.rename target.
   *  Threaded in so it stays correct (the host reads it live). */
  readonly sessionId = input.required<string>();

  /** Esc / × / Done — host unmounts the screen. */
  readonly close = output<void>();

  /** The labeled, post-stop transcript utterances — the SAME signal the live
   *  view reads (after meeting.transcript these are the clean labeled lines). */
  readonly segments = this.engine.segments;

  private readonly audioRef = viewChild<ElementRef<HTMLAudioElement>>('audio');
  private readonly utterancesScroll =
    viewChild<ElementRef<HTMLElement>>('utterancesScroll');

  // ─── Audio loading ───────────────────────────────────────────────────
  protected readonly audioStatus = signal<AudioStatus>('idle');
  /** The object URL bound to <audio>.src — retained so we can revoke it on
   *  teardown (and before replacing it) to avoid leaking the blob. */
  private objectUrl: string | null = null;
  /** Guards against a late readMeetingAudio resolve after teardown. */
  private destroyed = false;

  // ─── Player state (mirrors the <audio> element via its events) ────────
  protected readonly playing = signal(false);
  protected readonly currentTime = signal(0);
  protected readonly duration = signal(0);

  /** mm:ss / mm:ss readout. */
  protected readonly readout = computed(
    () => `${this.formatTime(this.currentTime())} / ${this.formatTime(this.duration())}`,
  );

  /**
   * Index of the utterance whose [tStart, nextTStart) window contains the
   * current playhead, or -1 when before the first line / no segments. Segments
   * are already sorted by tStart (EngineService.segments()), so the last line
   * whose tStart <= currentTime is the active one.
   */
  protected readonly nowPlayingIndex = computed(() => {
    const t = this.currentTime();
    const segs = this.segments();
    let idx = -1;
    for (let i = 0; i < segs.length; i++) {
      if (segs[i].tStart <= t) idx = i;
      else break;
    }
    return idx;
  });

  // ─── Roster editor (mirrors MeetingSavedToast) ────────────────────────
  protected readonly rows = signal<RosterRow[]>([]);
  protected readonly savedConfirmed = signal(false);
  private seededSession: string | null = null;

  /** Re-seed the editable roster whenever the saved payload changes — a new
   *  meeting OR an optimistic rename of the same one (which mutates speakers).
   *  The confirmation note resets ONLY on a genuinely different meeting. */
  private readonly _seedRoster = effect(() => {
    const saved = this.saved();
    this.rows.set(
      saved.speakers.map((sp, i) => ({
        label: sp.label,
        name: sp.matched_name ?? sp.label,
        i,
      })),
    );
    if (saved.session_id !== this.seededSession) {
      this.savedConfirmed.set(false);
      this.seededSession = saved.session_id;
    }
  });

  /** Load the audio once the path is known. Reads the bytes via the validated
   *  main IPC, wraps them in a Blob, and binds an object URL to <audio>. Runs
   *  when `saved()` changes (a new meeting) — revoking any prior URL first. */
  private readonly _loadAudio = effect(() => {
    const path = this.saved().audio_path;
    // Reading saved() above registers the dependency; do the async load
    // outside the reactive read so signal writes here don't loop.
    queueMicrotask(() => void this.loadAudioFor(path));
  });

  /** True when at least one row's typed name differs from its current label. */
  protected readonly hasChanges = computed(() =>
    this.rows().some((r) => {
      const typed = r.name.trim();
      return typed.length > 0 && typed !== r.label;
    }),
  );

  /** Keep the now-playing row scrolled into view as playback advances. Runs
   *  after render so the row element exists; only scrolls when the active row
   *  actually changes (reading nowPlayingIndex registers the dependency). */
  private lastScrolledIndex = -1;
  private readonly _followPlayhead = afterRenderEffect(() => {
    const idx = this.nowPlayingIndex();
    if (idx < 0 || idx === this.lastScrolledIndex) return;
    this.lastScrolledIndex = idx;
    const container = this.utterancesScroll()?.nativeElement;
    const row = container?.querySelector<HTMLElement>(`[data-row-index="${idx}"]`);
    if (row) row.scrollIntoView({ block: 'nearest', behavior: 'smooth' });
  });

  ngOnDestroy(): void {
    this.destroyed = true;
    this.revokeObjectUrl();
  }

  // ─── Audio loading ─────────────────────────────────────────────────────

  private async loadAudioFor(audioPath: string | null): Promise<void> {
    // A new load supersedes any prior URL.
    this.revokeObjectUrl();
    if (!audioPath || !window.hark?.readMeetingAudio) {
      this.audioStatus.set('error');
      return;
    }
    this.audioStatus.set('loading');
    try {
      const bytes = await window.hark.readMeetingAudio(audioPath);
      if (this.destroyed) return;
      // Copy into a freshly-allocated ArrayBuffer so the Blob owns a clean,
      // tightly-bounded, non-shared buffer (the IPC result is a Uint8Array that
      // may be a view into a larger structured-clone buffer; a plain
      // `new ArrayBuffer` also satisfies the strict `BlobPart` type, which
      // rejects the `ArrayBufferLike` union).
      const ab = new ArrayBuffer(bytes.byteLength);
      new Uint8Array(ab).set(bytes);
      const blob = new Blob([ab], { type: 'audio/wav' });
      this.objectUrl = URL.createObjectURL(blob);
      const el = this.audioRef()?.nativeElement;
      if (el) {
        el.src = this.objectUrl;
        el.load();
      }
      // 'ready' is confirmed on loadedmetadata; until then the controls stay
      // disabled. We optimistically flip to ready here so the transport
      // enables; loadedmetadata fills in duration. If decode fails, onAudioError
      // flips to 'error'.
      this.audioStatus.set('ready');
    } catch {
      if (this.destroyed) return;
      this.audioStatus.set('error');
    }
  }

  private revokeObjectUrl(): void {
    if (this.objectUrl) {
      URL.revokeObjectURL(this.objectUrl);
      this.objectUrl = null;
    }
  }

  // ─── Player controls ───────────────────────────────────────────────────

  protected togglePlay(): void {
    const el = this.audioRef()?.nativeElement;
    if (!el || this.audioStatus() !== 'ready') return;
    if (el.paused) void el.play().catch(() => this.audioStatus.set('error'));
    else el.pause();
  }

  /** Click an utterance → seek to its start and play that moment. */
  protected onRowClick(tStart: number): void {
    const el = this.audioRef()?.nativeElement;
    if (!el || this.audioStatus() !== 'ready') return;
    el.currentTime = tStart;
    this.currentTime.set(tStart);
    void el.play().catch(() => this.audioStatus.set('error'));
  }

  /** Drag/click the scrubber → seek. The native input gives us a string. */
  protected onScrub(value: string): void {
    const t = Number(value);
    if (!Number.isFinite(t)) return;
    const el = this.audioRef()?.nativeElement;
    if (el) el.currentTime = t;
    this.currentTime.set(t);
  }

  // ─── <audio> event handlers (the element is the source of truth) ───────

  protected onLoadedMetadata(): void {
    const el = this.audioRef()?.nativeElement;
    if (!el) return;
    this.duration.set(Number.isFinite(el.duration) ? el.duration : 0);
    this.audioStatus.set('ready');
  }

  protected onTimeUpdate(): void {
    const el = this.audioRef()?.nativeElement;
    if (el) this.currentTime.set(el.currentTime);
  }

  protected onPlayEvent(): void {
    this.playing.set(true);
  }

  protected onPauseEvent(): void {
    this.playing.set(false);
  }

  protected onEnded(): void {
    this.playing.set(false);
  }

  protected onAudioError(): void {
    // Only treat as a hard error if we actually tried to load something —
    // a fresh <audio> with no src also fires error in some engines.
    if (this.objectUrl) this.audioStatus.set('error');
  }

  // ─── Roster editing (reuses EngineService.renameSpeakers) ──────────────

  protected onNameInput(index: number, value: string): void {
    this.rows.update((rows) =>
      rows.map((r, i) => (i === index ? { ...r, name: value } : r)),
    );
    if (this.savedConfirmed()) this.savedConfirmed.set(false);
  }

  /** Build the changed-only names map and dispatch via the SAME service method
   *  the tagging modal + saved card use. EngineService.renameSpeakers sends
   *  speaker.rename AND applies the optimistic relabel (roster + utterance
   *  rows), which flows back through saved() → _seedRoster. */
  protected applyNames(): void {
    const names: Record<string, string> = {};
    for (const r of this.rows()) {
      const typed = r.name.trim();
      if (typed.length > 0 && typed !== r.label) names[r.label] = typed;
    }
    if (Object.keys(names).length === 0) return;
    this.engine.renameSpeakers(this.sessionId(), names);
    this.savedConfirmed.set(true);
  }

  // ─── Helpers ───────────────────────────────────────────────────────────

  protected onClose(): void {
    this.close.emit();
  }

  @HostListener('document:keydown.escape')
  protected onEscape(): void {
    this.close.emit();
  }

  /** Speaker label → palette token, via the EngineService single source of
   *  truth so colors match the transcript / attendees / saved card. */
  protected speakerColor(label: string | null): string {
    return this.engine.speakerColorFor(label);
  }

  /** Roster row palette token by its stable index (mirrors the saved card). */
  protected speakerColorByIndex(index: number): string {
    return `var(--sp-${(index % 6) + 1})`;
  }

  /** Seconds → mm:ss (or hh:mm:ss past an hour). Clamps NaN/negative to 0. */
  protected formatTime(seconds: number): string {
    const total = Number.isFinite(seconds) && seconds > 0 ? Math.floor(seconds) : 0;
    const s = total % 60;
    const m = Math.floor(total / 60) % 60;
    const h = Math.floor(total / 3600);
    const pad = (n: number) => String(n).padStart(2, '0');
    return h > 0 ? `${h}:${pad(m)}:${pad(s)}` : `${m}:${pad(s)}`;
  }
}
