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
  HostListener,
  OnDestroy,
  OnInit,
  computed,
  inject,
  signal,
  viewChild,
} from '@angular/core';
import {
  CdkVirtualScrollViewport,
  ScrollingModule,
} from '@angular/cdk/scrolling';
// Autosize strategy (variable-height rows) lives in cdk-experimental. Both
// packages are first-party Angular, build-time only, and open no runtime
// network socket — consistent with the loopback-only privacy posture.
import { CdkAutoSizeVirtualScroll } from '@angular/cdk-experimental/scrolling';
import { Subscription } from 'rxjs';
import { EngineService } from './services/engine.service';
import { PreferencesService } from './services/preferences.service';
import { LlmService } from './services/llm.service';
import { RetrievalService } from './services/retrieval.service';
import { ThemeService } from './services/theme.service';
import { TranslationJobService } from './services/translation-job.service';
import {
  LANGUAGE_CHOICES,
  DisplayedSegment,
  MeetingSavedPayload,
  RagResultChunk,
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
import {
  AskPanelComponent,
  AnswerSource,
  AskScope,
} from './components/ask-panel.component';
import { RipplesComponent } from './components/ripples.component';
import { SpeakerTaggingComponent } from './components/speaker-tagging.component';
import { PostMeetingReviewComponent } from './components/post-meeting-review.component';
import { SummaryPanelComponent } from './components/summary-panel.component';
import { TranslatePanelComponent } from './components/translate-panel.component';

/** One rendered transcript row: the segment plus the presentation flags the
 *  virtual `@for` needs. `partial`/`caret` reproduce the old live-tail split
 *  (finalized upright, in-flight italic + a single blinking caret); `animateIn`
 *  is TRUE only for live rows so a finalized row materialized by scrolling
 *  doesn't re-run the entrance; `bookmarked` is resolved once here. */
interface TranscriptRow {
  seg: DisplayedSegment;
  /** Stable trackBy key. Finalized rows key by utterance_id (a locked segment's
   *  id never changes). Live rows key by their cluster's start TIME, not by
   *  utterance_id — a thin idle-flush window makes WhisperKit re-segment the
   *  same audio under fresh ids every ~1.5 s (ADR-0009), so a time anchor keeps
   *  the one evolving live line stable while its text refreshes underneath. */
  key: string;
  partial: boolean;
  caret: boolean;
  animateIn: boolean;
  bookmarked: boolean;
}

@Component({
  selector: 'hark-root',
  standalone: true,
  imports: [
    ScrollingModule,
    CdkAutoSizeVirtualScroll,
    TranscriptLineComponent,
    StatusBannerComponent,
    SettingsPanelComponent,
    MeetingSavedToastComponent,
    ModelLoadingComponent,
    OnboardingComponent,
    AttendeesPanelComponent,
    AskPanelComponent,
    RipplesComponent,
    SpeakerTaggingComponent,
    PostMeetingReviewComponent,
    SummaryPanelComponent,
    TranslatePanelComponent,
  ],
  templateUrl: './app.component.html',
  styleUrl: './app.component.css',
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class AppComponent implements OnInit, OnDestroy {
  private readonly engine = inject(EngineService);
  private readonly prefs = inject(PreferencesService);
  private readonly llm = inject(LlmService);
  private readonly retrieval = inject(RetrievalService);
  private readonly translationJob = inject(TranslationJobService);

  /** Background post-meeting translation progress: drives the persistent
   *  "Translating → <lang> N%" / "ready" banner. Started on demand from the
   *  Translate panel after a meeting is saved. */
  readonly translationJobState = this.translationJob.job;
  readonly translationJobPercent = this.translationJob.percent;
  /** Dismiss the finished/errored translation banner. */
  dismissTranslationJob(): void {
    this.translationJob.dismiss();
  }
  // Injected for its construction side-effect: ThemeService applies the
  // persisted appearance choice to <html data-theme> at app start and keeps it
  // in sync with the pref + the OS Light/Dark setting. Not referenced further.
  private readonly theme = inject(ThemeService);

  /** True when vault Ask is routed to the EXTERNAL retrieval backend (ADR-0033/
   *  0034) — drives the Ask panel's index indicator (external shows a backend
   *  label instead of the engine's build/ready state). */
  readonly retrievalIsExternal = this.retrieval.isExternal;

  /** True once an LLM provider is configured (ADR-0029). Gates the Ask panel:
   *  with no model it shows its honest "set up a model" empty state and the
   *  input stays disabled. */
  readonly modelConfigured = this.llm.configured;

  // ─── Ask / this-meeting Q&A (Phase 6 slice 3, ADR-0031) ─────────────
  //
  // The Ask panel (right column) sends the user's question to main's LLM
  // bridge via LlmService.ask — the renderer makes NO network call; main owns
  // the cloud/local fork, redaction (cloud only), and the cloud-call log. We
  // assemble the transcript TEXT + applied speaker names off EngineService
  // (same as the Summary panel) and hold the latest answer here for display.
  // Nothing is persisted to the vault in this slice; the answer is transient.

  /**
   * Busy flag for the Ask panel's `loading` ("Thinking…") state. Owned by the
   * host (not just `llm.asking`) because a VAULT-scope question runs TWO async
   * steps — `engine.retrieve` (local RAG) THEN `llm.ask` — and the spinner must
   * cover both, not just the LLM leg. Toggled in `onAsk`'s try/finally.
   */
  readonly askInFlight = signal(false);

  /** The latest answer to show in the Ask panel: the model's prose on success,
   *  a short "Couldn't answer: …" line on failure, or null before the first
   *  question. Transient — reset when a new meeting starts / scope changes. */
  readonly askAnswer = signal<string | null>(null);

  /** What the next Ask question is answered from (Phase 6 slice 4c, ADR-0032):
   *  'meeting' = this meeting's transcript (Slice 3); 'vault' = the whole vault
   *  via the engine's local RAG retrieval. */
  readonly askScope = signal<AskScope>('meeting');

  /** Numbered source cards backing the latest VAULT answer — built from the
   *  retrieved chunks' metadata (note path, heading, snippet). Empty for a
   *  meeting-scope answer (Slice 3 surfaces no sources) and before any ask. */
  readonly askSources = signal<readonly AnswerSource[]>([]);

  /** Latest vault RAG index status from the engine (for the panel's index
   *  indicator); null when unknown / RAG unavailable. */
  readonly ragIndexStatus = this.engine.ragIndexStatus;

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

  // Live translation (translate captions as they land — both on-device → English
  // and per-line LLM → arbitrary target) is DEFERRED to the backlog (ADR-0037):
  // it was hard to test, timeout-prone on a small local model, and the bilingual
  // live view rendered messily. Translation now happens ONLY after a meeting
  // stops, on demand, via the Translate panel (the structured background job that
  // writes a `## Transcript — <lang>` mirror into the saved note). The engine's
  // `task: .translate` + per-segment translate plumbing is left dormant for an
  // easy future revival, but nothing in the UI drives it.

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

  // ─── Summary panel (Phase 6 slice 2, ADR-0029/0031) ─────────────────
  //
  // A modal opened from the saved-confirmation card's "Summarize" affordance
  // (available regardless of Keep audio — a summary doesn't need the recording).
  // It assembles the transcript text + applied speaker names from EngineService
  // and calls main's LLM bridge via LlmService (NO direct network), then writes
  // the summary back through the engine (summary.write) on "Save to note". When
  // no model is configured the card routes to Settings instead of opening this.
  readonly summaryOpen = signal(false);

  /** The summary panel's target — the most-recently-saved meeting's session id,
   *  read live so it stays correct if a newer meeting lands while open. */
  readonly summarySessionId = computed(
    () => this.engine.lastMeetingSaved()?.session_id ?? null,
  );

  /** Open the Summary panel for the saved meeting. Guarded: a saved meeting
   *  must exist (the card — hence the trigger — only renders then). */
  openSummary(): void {
    if (this.engine.lastMeetingSaved() === null) return;
    this.summaryOpen.set(true);
  }

  /** Esc / backdrop / × / Close inside the panel — unmount it. */
  closeSummary(): void {
    this.summaryOpen.set(false);
  }

  /** Auto-close the summary panel if its meeting goes away (New meeting / Start
   *  clears lastMeetingSaved()). Belt-and-braces alongside the template guard. */
  private readonly _summaryGuard = effect(() => {
    if (this.summaryOpen() && this.engine.lastMeetingSaved() === null) {
      this.summaryOpen.set(false);
    }
  });

  // ─── Translate panel (end-of-meeting transcript translation) ────────
  //
  // Mirrors the Summary panel: a modal opened from the saved-confirmation
  // card's "Translate" affordance. It assembles the transcript text + applied
  // speaker names from EngineService and calls main's LLM bridge via LlmService
  // (NO direct network), then writes the translation back through the engine
  // (translation.write) on "Save to note". Unlike Summary it does NOT
  // auto-run — the user picks a target language first. With no model configured
  // the card routes to Settings instead of opening this.
  readonly translationOpen = signal(false);

  /** The translate panel's target — the most-recently-saved meeting's session
   *  id (same source as `summarySessionId`), read live so it stays correct if a
   *  newer meeting lands while open. */
  readonly translationSessionId = computed(
    () => this.engine.lastMeetingSaved()?.session_id ?? null,
  );

  /** Open the Translate panel for the saved meeting. Guarded: a saved meeting
   *  must exist (the card — hence the trigger — only renders then). */
  openTranslation(): void {
    if (this.engine.lastMeetingSaved() === null) return;
    this.translationOpen.set(true);
  }

  /** Esc / backdrop / × / Close inside the panel — unmount it. */
  closeTranslation(): void {
    this.translationOpen.set(false);
  }

  /** Auto-close the translate panel if its meeting goes away (New meeting /
   *  Start clears lastMeetingSaved()). Belt-and-braces alongside the template
   *  guard. */
  private readonly _translationGuard = effect(() => {
    if (this.translationOpen() && this.engine.lastMeetingSaved() === null) {
      this.translationOpen.set(false);
    }
  });

  /**
   * The user switched the Ask scope (this meeting | vault). Store it and clear
   * any stale answer/sources from the other scope — a meeting answer's (empty)
   * sources and a vault answer's note-cards don't carry over.
   */
  setAskScope(scope: AskScope): void {
    if (this.askScope() === scope) return;
    this.askScope.set(scope);
    this.askAnswer.set(null);
    this.askSources.set([]);
  }

  /**
   * The Ask panel submitted a question. Routes by the current scope:
   *
   *   - 'meeting' (Slice 3): assemble the transcript TEXT + applied speaker
   *     names and send to main's LlmService.ask — no sources (this slice).
   *   - 'vault' (Slice 4c, ADR-0032): first `engine.retrieve` the top-K vault
   *     chunks (LOCAL — embed + cosine + read-from-vault, nothing leaves the
   *     Mac), then send their TEXTS as context to LlmService.ask. Main redacts
   *     each chunk for a cloud model (ADR-0031) or sends as-is for a local one.
   *     The retrieved chunks' METADATA becomes the numbered source cards.
   *
   * The renderer NEVER makes a network call. `askInFlight` covers BOTH async
   * legs so the panel's "Thinking…" spinner spans retrieval + answering.
   */
  async onAsk(question: string): Promise<void> {
    const q = question.trim();
    if (q.length === 0) return;
    // Clear prior answer + sources so nothing stale sits beneath the spinner.
    this.askAnswer.set(null);
    this.askSources.set([]);
    this.askInFlight.set(true);
    try {
      if (this.askScope() === 'vault') {
        await this.askVault(q);
      } else {
        await this.askMeeting(q);
      }
    } finally {
      this.askInFlight.set(false);
    }
  }

  /** This-meeting Q&A (Slice 3): answer grounded in the meeting transcript. */
  private async askMeeting(q: string): Promise<void> {
    const result = await this.llm.ask({
      question: q,
      scope: 'meeting',
      transcript: this.buildAskTranscript(),
      knownNames: this.buildAskKnownNames(),
    });
    this.askAnswer.set(
      result.ok ? result.answer : `Couldn't answer: ${result.detail}`,
    );
  }

  /**
   * Vault-wide Q&A (Slice 4c): retrieve from the engine's LOCAL RAG index, then
   * answer from the retrieved chunks with numbered source cards. Retrieval and
   * answering fail independently with honest, scoped messages (no global error
   * banner — the panel renders the message inline).
   */
  private async askVault(q: string): Promise<void> {
    let chunks: readonly RagResultChunk[];
    try {
      // RetrievalService routes to the built-in engine index OR the external
      // backend per the user's choice (ADR-0033) — both return the same shape.
      chunks = await this.retrieval.retrieve(q, { scope: 'vault', k: 6 });
    } catch (err) {
      // RAG_UNAVAILABLE (built-in index/embedder not ready), a timeout, a closed
      // socket, or an unreachable/misconfigured external backend — surface it
      // inline rather than as a global banner.
      this.askAnswer.set(
        `Couldn't search your vault: ${
          err instanceof Error ? err.message : 'retrieval failed'
        }`,
      );
      return;
    }
    if (chunks.length === 0) {
      this.askAnswer.set(
        "I couldn't find anything in your vault about that. Try rephrasing, " +
          'or check that your notes are indexed.',
      );
      return;
    }
    const result = await this.llm.ask({
      question: q,
      scope: 'vault',
      context: chunks.map((c) => c.text),
      knownNames: this.buildAskKnownNames(),
    });
    if (!result.ok) {
      this.askAnswer.set(`Couldn't answer: ${result.detail}`);
      return;
    }
    this.askAnswer.set(result.answer);
    // Numbered source cards from the retrieved chunks' metadata — the citation
    // surface the model's inline [n] refs point at (n = 1-based retrieval rank).
    this.askSources.set(chunks.map((c, i) => this.chunkToSource(c, i)));
  }

  /** Map a retrieved vault chunk to a numbered Ask-panel source card. `title`
   *  is the note's filename (no extension); `ref` is the vault-relative path
   *  plus the heading breadcrumb when present; `snippet` is the retrieved text
   *  (whitespace-collapsed, truncated). No `stamp` — a chunk carries no reliable
   *  timestamp, and we never fabricate one. */
  private chunkToSource(c: RagResultChunk, i: number): AnswerSource {
    const heading = (c.heading_path ?? '').trim();
    return {
      n: i + 1,
      title: this.noteName(c.note_path),
      ref: heading ? `${c.note_path} · ${heading}` : c.note_path,
      stamp: '',
      snippet: this.truncate(c.text, 240),
    };
  }

  /** A note's display name: its basename without the `.md` extension. */
  private noteName(notePath: string): string {
    const file = notePath.split('/').pop() ?? notePath;
    return file.replace(/\.md$/i, '');
  }

  /** Collapse whitespace + truncate a snippet to `max` chars with an ellipsis. */
  private truncate(s: string, max: number): string {
    const t = s.trim().replace(/\s+/g, ' ');
    return t.length <= max ? t : `${t.slice(0, max - 1).trimEnd()}…`;
  }

  /**
   * Build the transcript text for an Ask request from the clean, post-stop
   * labeled utterances (EngineService.segments(), already sorted by tStart).
   * Each line is "<speaker> <mm:ss>: <text>", with the speaker omitted when
   * unknown so we never fabricate one. Text only — no audio, no per-line ids.
   * Empty string when there's nothing to ask about (the engine/model answers
   * "no transcript"); mirrors the Summary panel's assembler.
   */
  private buildAskTranscript(): string {
    return this.segments()
      .map((s) => {
        const stamp = this.formatTime(s.tStart);
        const speaker = s.speaker ? `${s.speaker} ` : '';
        return `${speaker}${stamp}: ${s.text}`;
      })
      .join('\n');
  }

  /**
   * The applied speaker display-names from the saved roster — the names main
   * collapses to labels before a CLOUD send (ADR-0031). Each speaker's applied
   * name: `matched_name` when set, else the label only if it isn't the generic
   * "Speaker N" placeholder (a bare placeholder carries no PII). De-duped,
   * non-empty. Mirrors the Summary panel's `buildKnownNames`.
   */
  private buildAskKnownNames(): string[] {
    const saved = this.engine.lastMeetingSaved();
    if (!saved) return [];
    const names = new Set<string>();
    for (const sp of saved.speakers) {
      const applied = (sp.matched_name ?? '').trim();
      if (applied) {
        names.add(applied);
        continue;
      }
      const label = sp.label.trim();
      if (label && !/^Speaker\s+\d+$/i.test(label)) names.add(label);
    }
    return Array.from(names);
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

  // Finalized utterances (history) vs in-flight partials (live tail). Read
  // straight off EngineService, which maintains the two buckets incrementally
  // (no per-frame whole-array filter) — each list's reference changes only when
  // that bucket changes, so under OnPush the finalized history doesn't re-render
  // when only a live partial ticks.
  readonly finalizedSegments = this.engine.finalizedSegments;
  readonly liveSegments = this.engine.liveSegments;

  // ─── Virtualized transcript rows ────────────────────────────────────
  //
  // The transcript is windowed with a CDK virtual-scroll viewport: only the
  // handful of rows in view have a live component + DOM subtree, so an
  // hour-long meeting no longer retains tens of thousands of DOM nodes. We feed
  // the viewport ONE combined, ordered list — finalized history first, then the
  // live tail — so both scroll as a single region and auto-scroll can jump to
  // the true bottom (past history into the newest partial). Each row carries its
  // own presentation flags so the template stays declarative: `partial` styles
  // the live-tail treatment, `caret` marks the single newest live line,
  // `animateIn` is TRUE only for live rows (a finalized row materialized by
  // scrolling isn't "new", so it must not re-run the entrance), and `bookmarked`
  // is resolved here rather than per-render. track = utteranceId (see trackRow),
  // matching the previous @for.
  //
  // Split into two memoized halves so a live partial ticking several times a
  // second does NOT re-allocate a row object for every finalized line — the hot
  // path. `finalizedRows` recomputes only when finalized segments or bookmarks
  // change (bookmarks change on a user action, not per frame); `liveRows` is
  // tiny. A live tick therefore rebuilds only `liveRows` (a handful of objects)
  // and the concat below (an N-length reference copy — cheap, no per-row work).
  private readonly finalizedRows = computed<TranscriptRow[]>(() => {
    const finalized = this.finalizedSegments();
    const isBookmarked = this.bookmarkPredicate();
    return finalized.map((s) => ({
      seg: s,
      key: s.utteranceId,
      partial: false,
      caret: false,
      animateIn: false,
      bookmarked: isBookmarked(s),
    }));
  });
  private readonly liveRows = computed<TranscriptRow[]>(() => {
    const clusters = this.collapseLiveByOverlap(this.liveSegments());
    const isBookmarked = this.bookmarkPredicate();
    // Drop a live cluster a finalized line already shows — the "finalized +
    // lingering live echo" duplicate that survives when an utterance finalized
    // under a different id than the live re-decodes still sitting in the bucket.
    const finalized = this.finalizedSegments();
    const visible = clusters.filter((c) => !this.finalizedCovers(finalized, c));
    const lastLive = visible.length - 1;
    return visible.map((s, i) => ({
      seg: s,
      // Time-anchored key (1 s bucket) so the live line persists across the
      // id churn of thin-window re-decodes; see TranscriptRow.key.
      key: 'live@' + Math.round(s.tStart),
      partial: true,
      caret: i === lastLive,
      // Don't re-fire the entrance animation when a re-decode nudges the anchor;
      // the caret + italic already mark it live. Entrance is for finalized lines.
      animateIn: false,
      bookmarked: isBookmarked(s),
    }));
  });

  /** True when a finalized line already shows this live cluster's words at a
   *  near time — so we never render the finalized line AND a lingering live echo
   *  of the same utterance. Text match (equal or containment) is gated by time
   *  proximity so a legitimately repeated phrase later in the meeting is kept. */
  private finalizedCovers(
    finalized: readonly DisplayedSegment[],
    c: DisplayedSegment,
  ): boolean {
    const cn = this.normLive(c.text);
    if (!cn) return false;
    return finalized.some((f) => {
      const fn = this.normLive(f.text);
      if (!fn) return false;
      const textMatch = fn === cn || fn.includes(cn) || cn.includes(fn);
      const timeNear = c.tStart < f.tEnd + 2.5 && f.tStart < c.tEnd + 2.5;
      return textMatch && timeNear;
    });
  }

  /** Collapse the live (un-finalized) segments into one evolving caption per
   *  spoken utterance. A thin idle-flush window (perf/live-caption-latency) makes
   *  WhisperKit re-segment the same audio into shifting boundaries + fresh
   *  utterance_ids (ADR-0009), so one spoken line arrives as several overlapping
   *  live segments — rendering each as its own row is what stacked the duplicate
   *  lines. We cluster by time-overlap and keep the most-complete (longest-text)
   *  member of each cluster, anchored to the cluster's earliest start. Finalized
   *  history is untouched (the engine commit-watermark already dedups it). */
  private collapseLiveByOverlap(
    live: readonly DisplayedSegment[],
  ): DisplayedSegment[] {
    if (live.length <= 1) return [...live];
    // Each segment joins an EXISTING cluster when it is BOTH text-related and
    // time-near to it — matched against ALL open clusters, not just the previous
    // one, so a re-decode of the same words still merges even when a junk decode
    // got wedged between the two copies (the "What is the status…" ×2 case). The
    // text gate is essential: without it, time-overlap alone chain-merges
    // back-to-back distinct utterances into one blob. Text-related = one
    // normalized text contains the other, or they share a 12-char prefix — true
    // for re-segmentations of the same words, false for "Let's start…" vs
    // "Revenue…". Time-near tolerates a ~2.5 s gap (a re-decode can land just
    // after the prior copy ends); the text gate keeps that from over-merging.
    interface Cluster {
      startT: number;
      endT: number;
      best: DisplayedSegment;
      bestNorm: string;
    }
    const clusters: Cluster[] = [];
    for (const s of live) {
      const sNorm = this.normLive(s.text);
      const match = clusters.find((c) => {
        const textRel =
          !!sNorm &&
          !!c.bestNorm &&
          (sNorm.includes(c.bestNorm) ||
            c.bestNorm.includes(sNorm) ||
            (sNorm.length >= 12 && sNorm.slice(0, 12) === c.bestNorm.slice(0, 12)));
        const timeNear = s.tStart < c.endT + 2.5 && c.startT < s.tEnd + 2.5;
        return textRel && timeNear;
      });
      if (match) {
        match.endT = Math.max(match.endT, s.tEnd);
        match.startT = Math.min(match.startT, s.tStart);
        if ((s.text?.length ?? 0) >= (match.best.text?.length ?? 0)) {
          match.best = s;
          match.bestNorm = sNorm;
        }
      } else {
        clusters.push({ startT: s.tStart, endT: s.tEnd, best: s, bestNorm: sNorm });
      }
    }
    return clusters
      .sort((a, b) => a.startT - b.startT)
      .map((c) => ({ ...c.best, tStart: c.startT, tEnd: c.endT }));
  }

  /** Normalize caption text for the live-collapse similarity test: lowercase,
   *  drop punctuation, collapse whitespace. Keeps letters/digits/spaces so a
   *  re-segmentation ("finished over the weekend." vs "The migration finished
   *  over the weekend") still matches by substring. */
  private normLive(t: string | undefined): string {
    return (t ?? '')
      .toLowerCase()
      .replace(/[^a-z0-9 ]/g, '')
      .replace(/\s+/g, ' ')
      .trim();
  }
  readonly transcriptRows = computed<TranscriptRow[]>(() => [
    ...this.finalizedRows(),
    ...this.liveRows(),
  ]);

  /** A bookmark hit-test bound to the current bookmark set. Extracted so both
   *  row computeds share it and depend on `bookmarks()` uniformly. */
  private bookmarkPredicate(): (s: DisplayedSegment) => boolean {
    const bookmarks = this.bookmarks();
    return (s) => bookmarks.some((b) => b.t >= s.tStart && b.t < s.tEnd);
  }

  // ─── Transcript auto-scroll (follow the tail) ───────────────────────
  /** The CDK virtual-scroll viewport (the scrollable transcript region). */
  private readonly transcriptViewport =
    viewChild<CdkVirtualScrollViewport>('transcriptViewport');
  /** Whether to keep the view pinned to the newest line. Goes false when the
   *  user scrolls up to read history (so we don't yank them back down), and
   *  true again when they return to the bottom. */
  private followTail = true;
  // Pin to the latest line as the transcript grows — but only while the user is
  // at the bottom. afterRenderEffect runs AFTER the DOM updates, so the viewport
  // has already measured the new content; it re-runs only when the row list
  // changes (it never reads the per-second REC tick, so the clock doesn't cause
  // scrolling). With virtualization we can't read scrollHeight directly (most
  // rows aren't in the DOM), so we ask the viewport to scroll to the last row.
  private readonly _autoscroll = afterRenderEffect(() => {
    const rows = this.transcriptRows();
    if (!this.followTail || rows.length === 0) return;
    const vp = this.transcriptViewport();
    if (!vp) return;
    // The autosize scroll strategy does NOT support scrollToIndex (it throws
    // at runtime), so pin to the bottom via the max offset instead. This
    // effect re-runs on every row change, so it self-corrects as the newest
    // row measures — landing at the true bottom even for a tall last row.
    vp.scrollTo({ bottom: 0 });
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
      } else if (action === 'settings') {
        // Tray popover's "Settings…" row — main already brought the window up.
        this.openSettings();
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
   *  user reading back up isn't pulled down by new segments. The viewport's
   *  `measureScrollOffset('bottom')` is the remaining distance to the content
   *  end — the virtualization-safe equivalent of the old
   *  scrollHeight − scrollTop − clientHeight. */
  onTranscriptScroll(): void {
    const vp = this.transcriptViewport();
    if (!vp) return;
    this.followTail = vp.measureScrollOffset('bottom') < 48;
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

  /** `*cdkVirtualFor` trackBy — key rows by `row.key` so the viewport reuses a
   *  row's view across ticks: a finalized line keeps its utterance_id, and a
   *  live line keeps its time anchor while its text refreshes underneath (a
   *  partial updating in place keeps the SAME view — no re-mount, no entrance
   *  re-fire). See TranscriptRow.key for why live rows are time-anchored. */
  trackRow = (_: number, row: TranscriptRow): string => row.key;

  /** Speaker → palette CSS-var, delegated to the EngineService single source of
   *  truth so the transcript line's chip/name color matches the Attendees panel
   *  for the same speaker. Reads the roster + segments signals internally, so a
   *  rename (which advances the roster label + relabels segments) re-colors both
   *  surfaces together under OnPush. */
  speakerColorFor(label: string | null): string {
    return this.engine.speakerColorFor(label);
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
    // A fresh meeting starts with a clean Ask view — drop any prior answer +
    // source cards (the prior one was about a different, now-cleared context).
    this.askAnswer.set(null);
    this.askSources.set([]);
    this.engine.startCapture({
      mic: this.micEnabled(),
      system: this.systemEnabled(),
      language: this.language(),
      // Privacy gates (ADR-0027) from the user's persisted, opt-in-only
      // choices. Off by default ⇒ the engine stores no audio / voiceprints.
      keepAudio: this.prefs.keepAudio(),
      rememberSpeakers: this.prefs.rememberSpeakers(),
      // Live translation is deferred (ADR-0037): we never ask the engine to
      // translate during capture. Transcription stays in the source language;
      // translation is an on-demand, post-stop action (the Translate panel).
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
    // Drop any Q&A answer + source cards — a clean slate for the next meeting.
    this.askAnswer.set(null);
    this.askSources.set([]);
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

  /** "Reveal in Finder" on the saved-meeting card: open the vault folder with
   *  the meeting's OWN note (`vault_path`) selected, so the user lands on the
   *  file and can open it — not dumped in the vault root. main validates the
   *  path is inside the vault. Falls back to the vault root if the meeting (or
   *  its path) is somehow gone. No-op outside Electron. */
  revealMeeting(): void {
    const file = this.engine.lastMeetingSaved()?.vault_path;
    if (file) this.prefs.revealPath(file);
    else this.prefs.revealVault();
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
