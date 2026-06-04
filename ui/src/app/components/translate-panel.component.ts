// TranslatePanel — translate the saved meeting transcript into a chosen
// language, on demand, AFTER the meeting stops (ADR-0029 / ADR-0031 / ADR-0037).
//
// This is the ONLY translation surface now that live (translate-during-capture)
// translation is deferred to the backlog (ADR-0037). A centered modal opened
// from the meeting-saved card. It:
//   1. Lets the user pick a target language from TRANSLATE_TARGETS.
//   2. On "Translate", hands the CLEAN post-stop transcript — one text per saved
//      utterance, in order (EngineService.segments(), the labeled post-stop swap)
//      — plus the applied speaker display-names to TranslationJobService, which
//      translates each line ONE AT A TIME in the BACKGROUND (non-blocking, with a
//      progress %), then persists the result via the ENGINE
//      (EngineService.writeTranslationLines → `translation.write` with `lines`).
//      The engine ZIPS each translated line with its OWN retained utterance
//      (speaker label + wall-clock tStart) and re-renders the blockquote body, so
//      the appended `## Transcript — <lang>` section is a byte-for-byte STRUCTURAL
//      MIRROR of the original — same labels, timestamps, blockquote format.
//   3. Closes immediately; the host's progress banner shows "Translating →
//      <lang> N%" and a "ready" / error state. The user keeps using the app.
//
// PRIVACY (ADR-0031 / ADR-0035): the renderer makes NO network call. Each line
// goes through LlmService.translateSegment → Electron MAIN (the egress
// chokepoint): a LOCAL (loopback) model = ZERO egress; a CLOUD model redacts each
// line and records ONE aggregated, metadata-only entry in the cloud-call log
// (Settings → Privacy). The panel discloses which BEFORE the user commits, using
// the same loopback-baseUrl test main applies.
//
// Token-only styling, OnPush, signals, @if/@for, strict-CSP-safe (no inline
// handlers).

import {
  ChangeDetectionStrategy,
  Component,
  HostListener,
  computed,
  inject,
  input,
  output,
  signal,
} from '@angular/core';
import { EngineService } from '../services/engine.service';
import { LlmService } from '../services/llm.service';
import { TranslationJobService } from '../services/translation-job.service';

/** A target language the user can translate INTO. `label` is the friendly,
 *  native-script display string shown in the picker; `name` is the canonical
 *  ENGLISH language name we send to the model (and that the engine uses for the
 *  `## Transcript — <name>` vault heading). */
export interface TranslateTarget {
  readonly label: string;
  readonly name: string;
}

/** The offered target languages. Send `name` (English); show `label`. */
export const TRANSLATE_TARGETS: readonly TranslateTarget[] = [
  { label: 'English', name: 'English' },
  { label: 'Vietnamese (Tiếng Việt)', name: 'Vietnamese' },
  { label: 'Thai (ไทย)', name: 'Thai' },
  { label: 'Chinese (中文)', name: 'Chinese' },
  { label: 'Japanese (日本語)', name: 'Japanese' },
  { label: 'Korean (한국어)', name: 'Korean' },
  { label: 'Spanish', name: 'Spanish' },
  { label: 'French', name: 'French' },
  { label: 'German', name: 'German' },
];

@Component({
  selector: 'hark-translate-panel',
  standalone: true,
  changeDetection: ChangeDetectionStrategy.OnPush,
  styles: [
    `
      :host {
        display: contents;
      }

      .backdrop {
        position: fixed;
        inset: 0;
        z-index: 60;
        display: flex;
        align-items: center;
        justify-content: center;
        padding: var(--s-6);
        background: color-mix(in oklab, var(--bg) 55%, transparent);
        -webkit-backdrop-filter: blur(2px);
        backdrop-filter: blur(2px);
        animation: translate-fade 120ms ease-out;
      }

      .card {
        display: flex;
        flex-direction: column;
        width: 100%;
        max-width: 520px;
        background: var(--surface);
        border: 1px solid var(--border-2);
        border-radius: var(--r-card);
        box-shadow: var(--shadow-modal);
        color: var(--text);
        font-family: var(--font-ui);
        animation: translate-rise 140ms cubic-bezier(0.2, 0.8, 0.2, 1);
      }

      @keyframes translate-fade {
        from {
          opacity: 0;
        }
        to {
          opacity: 1;
        }
      }
      @keyframes translate-rise {
        from {
          opacity: 0;
          transform: translateY(8px) scale(0.98);
        }
        to {
          opacity: 1;
          transform: translateY(0) scale(1);
        }
      }

      /* ── Header ─────────────────────────────────────────────────────── */
      .head {
        display: flex;
        align-items: center;
        gap: var(--s-3);
        padding: var(--s-3) var(--s-4);
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
      .close {
        flex-shrink: 0;
        display: inline-flex;
        align-items: center;
        justify-content: center;
        width: 28px;
        height: 28px;
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

      /* ── Body ───────────────────────────────────────────────────────── */
      .body {
        padding: var(--s-4);
        display: flex;
        flex-direction: column;
        gap: var(--s-3);
      }

      /* ── Target-language picker ─────────────────────────────────────── */
      .lang-row {
        display: flex;
        align-items: center;
        gap: var(--s-2);
        flex-shrink: 0;
      }
      .lang-label {
        font-size: 12px;
        color: var(--text-2);
        white-space: nowrap;
      }
      .lang-select {
        flex: 1;
        min-width: 0;
        font-family: var(--font-ui);
        font-size: 12.5px;
        color: var(--text);
        padding: 5px 10px;
        background: var(--surface);
        border: 1px solid var(--border-2);
        border-radius: var(--r-input);
        outline: none;
        cursor: pointer;
      }
      .lang-select:focus {
        border-color: var(--accent);
        box-shadow: 0 0 0 3px var(--accent-soft);
      }

      /* ── Egress disclosure (local vs cloud) ─────────────────────────── */
      .disclosure {
        display: flex;
        align-items: flex-start;
        gap: var(--s-2);
        padding: var(--s-3);
        border-radius: var(--r-panel);
        border: 1px solid var(--border);
        background: var(--bg-2);
        font-size: 11.5px;
        line-height: 1.5;
        color: var(--text-2);
      }
      .disclosure.cloud {
        border-color: color-mix(in oklab, var(--status-cloud) 35%, transparent);
        background: color-mix(in oklab, var(--status-cloud) 8%, transparent);
      }
      .disclosure .d-icon {
        flex-shrink: 0;
        margin-top: 1px;
      }
      .disclosure.cloud .d-icon {
        color: var(--status-cloud);
      }
      .disclosure:not(.cloud) .d-icon {
        color: var(--status-success);
      }
      .disclosure strong {
        color: var(--text);
        font-weight: 600;
      }

      .idle-hint {
        text-align: center;
        color: var(--text-3);
        font-size: 12px;
        line-height: 1.5;
      }

      /* ── Footer ─────────────────────────────────────────────────────── */
      .footer {
        display: flex;
        align-items: center;
        gap: var(--s-2);
        padding: var(--s-3) var(--s-4);
        border-top: 1px solid var(--border);
        flex-shrink: 0;
      }
      .spacer {
        flex: 1;
      }
      .btn {
        font-family: var(--font-ui);
        font-size: 12.5px;
        font-weight: 500;
        padding: 5px 12px;
        border-radius: var(--r-input);
        border: 1px solid var(--border-2);
        background: var(--surface);
        color: var(--text);
        cursor: pointer;
      }
      .btn:hover:not(:disabled) {
        background: var(--highlight);
      }
      .btn:disabled {
        opacity: 0.5;
        cursor: not-allowed;
      }
      .btn-primary {
        border-color: var(--accent);
        background: var(--accent-soft);
        color: var(--accent);
      }
      .btn-primary:hover:not(:disabled) {
        background: color-mix(in oklab, var(--accent) 22%, transparent);
      }
    `,
  ],
  template: `
    <!-- Backdrop click closes; the card stops propagation. -->
    <div class="backdrop" (click)="onClose()">
      <div
        class="card"
        role="dialog"
        aria-modal="true"
        aria-label="Translate transcript"
        (click)="$event.stopPropagation()"
      >
        <!-- Header -->
        <div class="head">
          <div class="head-text">
            <div class="title">Translate</div>
            <div class="subtitle">
              A model translates this meeting's transcript into another language
              and saves it into the note. Text only — your audio never leaves the
              Mac.
            </div>
          </div>
          <button
            type="button"
            class="close"
            (click)="onClose()"
            title="Close (Esc)"
            aria-label="Close translate"
          >
            <svg viewBox="0 0 24 24" width="15" height="15" fill="none"
              stroke="currentColor" stroke-width="2" stroke-linecap="round"
              aria-hidden="true">
              <path d="M6 6l12 12M18 6L6 18" />
            </svg>
          </button>
        </div>

        <!-- Body -->
        <div class="body">
          <!-- Target-language picker. -->
          <div class="lang-row">
            <label class="lang-label" for="translate-target">Translate to</label>
            <select
              id="translate-target"
              class="lang-select"
              [value]="targetName()"
              (change)="onTargetChange($any($event.target).value)"
            >
              @for (t of targets; track t.name) {
                <option [value]="t.name">{{ t.label }}</option>
              }
            </select>
          </div>

          <!-- Egress disclosure — honest about where the text goes. -->
          <div class="disclosure" [class.cloud]="usesCloud()">
            <svg class="d-icon" viewBox="0 0 24 24" width="13" height="13"
              fill="none" stroke="currentColor" stroke-width="1.7"
              stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
              @if (usesCloud()) {
                <path d="M7 18a4 4 0 0 1 .5-7.97A6 6 0 0 1 19 11a3.5 3.5 0 0 1-.5 7H7z" />
              } @else {
                <rect x="5" y="11" width="14" height="9" rx="2" />
                <path d="M8 11V8a4 4 0 0 1 8 0v3" />
              }
            </svg>
            <span>
              @if (usesCloud()) {
                Each line is sent to your <strong>cloud</strong> model (redacted)
                and recorded in Settings → Privacy. Switch to a local model to
                keep everything on your Mac.
              } @else {
                Runs on your <strong>local</strong> model — nothing leaves your
                Mac.
              }
            </span>
          </div>

          <div class="idle-hint">
            Translation runs in the background; a progress indicator appears once
            you start. You can keep using the app.
          </div>
        </div>

        <!-- Footer -->
        <div class="footer">
          <div class="spacer"></div>
          <button type="button" class="btn" (click)="onClose()">Close</button>
          <button
            type="button"
            class="btn btn-primary"
            [disabled]="!hasTranscript()"
            (click)="translate()"
            [title]="'Translate the transcript into ' + targetName()"
          >
            Translate
          </button>
        </div>
      </div>
    </div>
  `,
})
export class TranslatePanelComponent {
  private readonly engine = inject(EngineService);
  private readonly llm = inject(LlmService);
  private readonly translationJob = inject(TranslationJobService);

  /** The session id of the meeting being translated — the `translation.write`
   *  target (the most-recently-saved meeting). Threaded from the host. */
  readonly sessionId = input.required<string>();

  /** Host closes the panel (Esc / backdrop / × / Close / on launch). */
  readonly close = output<void>();

  /** The offered target languages (for the template @for). */
  protected readonly targets = TRANSLATE_TARGETS;

  /** Currently-selected target language NAME (English). Defaults to the first
   *  offered target. */
  protected readonly targetName = signal<string>(TRANSLATE_TARGETS[0].name);

  /** True once there's a transcript to translate (gates the Translate button). */
  protected readonly hasTranscript = computed(
    () => this.engine.segments().length > 0,
  );

  /**
   * Whether the configured model would send each line to the CLOUD (vs a LOCAL
   * loopback model = zero egress). Mirrors main's `isLocalEgress` so the panel
   * discloses honestly BEFORE the user commits. Anthropic (no baseUrl) and any
   * non-loopback baseUrl ⇒ cloud; a loopback OpenAI-compatible baseUrl ⇒ local.
   * Null config ⇒ treat as cloud (the safe assumption).
   */
  protected readonly usesCloud = computed(() => {
    const cfg = this.llm.config();
    if (!cfg || cfg.provider !== 'openai-compatible') return true;
    const base = cfg.baseUrl;
    if (typeof base !== 'string' || base.length === 0) return true;
    try {
      const h = new URL(base).hostname.replace(/^\[|\]$/g, '').toLowerCase();
      return !(h === 'localhost' || h === '127.0.0.1' || h === '::1');
    } catch {
      return true;
    }
  });

  /** The user picked a different target language. */
  protected onTargetChange(value: string): void {
    this.targetName.set(value);
  }

  /**
   * Hand the transcript to the background translation job and close. The job
   * translates each line via main (LOCAL = zero egress; CLOUD redacts + logs)
   * and persists a structural mirror via the engine; the host's banner shows
   * progress. Re-running for the same meeting replaces that language's section.
   */
  protected translate(): void {
    const texts = this.buildTexts();
    if (texts.length === 0) return;
    this.translationJob.start(
      this.sessionId(),
      this.targetName(),
      texts,
      this.buildKnownNames(),
    );
    this.close.emit();
  }

  /**
   * The clean post-stop transcript as one text per utterance, in the SAME ORDER
   * the engine saved them (EngineService.segments() == the `meeting.transcript`
   * swap == the engine's saved utterances). The engine zips translated[i] back
   * onto its retained utterance[i] (speaker label + wall-clock tStart).
   */
  private buildTexts(): string[] {
    return this.engine.segments().map((s) => s.text);
  }

  /**
   * The applied speaker display-names from the saved roster — the names main
   * collapses to labels before a cloud send (ADR-0031). We take each speaker's
   * applied name: `matched_name` when set, else the label only if it isn't the
   * generic "Speaker N" placeholder (a bare placeholder carries no PII to
   * protect). De-duped, non-empty.
   */
  private buildKnownNames(): string[] {
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

  protected onClose(): void {
    this.close.emit();
  }

  @HostListener('document:keydown.escape')
  protected onEscape(): void {
    this.close.emit();
  }
}
