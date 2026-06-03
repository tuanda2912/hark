// TranslatePanel — translate the meeting transcript into a chosen language
// (Phase 6, ADR-0029 / ADR-0031). A near-clone of SummaryPanel.
//
// A centered modal opened from the meeting-saved card. It:
//   1. Assembles the transcript TEXT from EngineService.segments() (the clean,
//      post-stop labeled utterances) as "<speaker> <mm:ss>: <text>" lines, and
//      the applied speaker display-names as `knownNames` — IDENTICAL to the
//      Summary panel's assembly.
//   2. Unlike Summary it does NOT auto-run on open: translation needs a chosen
//      target language. The user picks a target from TRANSLATE_TARGETS and
//      clicks "Translate"; we send the transcript + the ENGLISH language NAME
//      (the model + vault heading want the canonical name) + knownNames to main
//      via LlmService.translate — the renderer makes NO network call. Main owns
//      the cloud/local fork, the redaction (cloud only), and the provider HTTP.
//   3. Renders the returned translation readably (whitespace-pre body — no
//      markdown dependency) plus the SAME honest egress receipt as Summary:
//        cloud → "Sent to {model} · cloud · redacted N item(s) · text only —
//                 never audio"
//        local → "Ran on {model} · ran locally · nothing left your Mac"
//      and a redaction breakdown by category when there is one. The user can
//      change the language + re-translate; a re-translate replaces the result.
//   4. On "Save to note" sends the translation back through the ENGINE
//      (EngineService.writeTranslation → `translation.write`), which appends a
//      `## Transcript — <lang>` section to the meeting file + git-commits
//      (ADR-0031 — the renderer never writes the vault). Shows a transient
//      "Saved to note ✓"; switching language + re-translating resets it.
//
// Token-only styling, OnPush, signals, @if/@for, strict-CSP-safe (no inline
// handlers). Modal chrome mirrors SummaryPanel exactly.

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
        max-width: 640px;
        max-height: 82vh;
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

      /* ── Body (scrolls) ─────────────────────────────────────────────── */
      .body {
        flex: 1;
        min-height: 0;
        overflow-y: auto;
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
      .lang-select:disabled {
        opacity: 0.5;
        cursor: not-allowed;
      }

      /* Generating state — a small spinner + label, no fake percentage. */
      .generating {
        display: flex;
        align-items: center;
        gap: var(--s-2);
        padding: var(--s-8) 0;
        justify-content: center;
        color: var(--text-2);
        font-size: 13px;
      }
      .spinner {
        width: 16px;
        height: 16px;
        border: 2px solid var(--border-2);
        border-top-color: var(--accent);
        border-radius: 50%;
        animation: translate-spin 700ms linear infinite;
      }
      @keyframes translate-spin {
        to {
          transform: rotate(360deg);
        }
      }

      /* The translated transcript body. We don't pull in a markdown renderer;
         the text is shown with preserved whitespace + wrapping so lines read
         sensibly. */
      .translation-text {
        margin: 0;
        font-family: var(--font-ui);
        font-size: 13.5px;
        line-height: 1.6;
        color: var(--text);
        white-space: pre-wrap;
        overflow-wrap: anywhere;
      }

      /* Idle hint shown before the first translate. */
      .idle-hint {
        padding: var(--s-6) 0;
        text-align: center;
        color: var(--text-3);
        font-size: 12.5px;
        line-height: 1.5;
      }

      /* Error state. */
      .error {
        display: flex;
        align-items: flex-start;
        gap: var(--s-2);
        padding: var(--s-3);
        border-radius: var(--r-panel);
        border: 1px solid
          color-mix(in oklab, var(--status-recording) 40%, transparent);
        background: color-mix(in oklab, var(--status-recording) 8%, transparent);
        color: var(--text);
        font-size: 12.5px;
        line-height: 1.5;
      }
      .error svg {
        flex-shrink: 0;
        margin-top: 1px;
        color: var(--status-recording);
      }

      /* ── Receipt (egress disclosure) ────────────────────────────────── */
      .receipt {
        display: flex;
        flex-direction: column;
        gap: var(--s-2);
        padding: var(--s-3);
        border-radius: var(--r-panel);
        border: 1px solid var(--border);
        background: var(--bg-2);
      }
      .receipt.cloud {
        border-color: color-mix(in oklab, var(--status-cloud) 35%, transparent);
        background: color-mix(in oklab, var(--status-cloud) 8%, transparent);
      }
      .receipt-line {
        display: flex;
        align-items: flex-start;
        gap: var(--s-2);
        font-size: 11.5px;
        line-height: 1.5;
        color: var(--text-2);
      }
      .receipt-line .r-icon {
        flex-shrink: 0;
        margin-top: 1px;
      }
      .receipt.cloud .r-icon {
        color: var(--status-cloud);
      }
      .receipt:not(.cloud) .r-icon {
        color: var(--status-success);
      }
      .receipt-line strong {
        color: var(--text);
        font-weight: 600;
      }
      .redaction-list {
        display: flex;
        flex-wrap: wrap;
        gap: var(--s-1);
        margin: 0;
        padding: 0;
        list-style: none;
      }
      .redaction-chip {
        display: inline-flex;
        align-items: center;
        gap: 4px;
        padding: 2px 7px;
        border-radius: 999px;
        border: 1px solid var(--border-2);
        background: var(--surface);
        font-family: var(--font-mono);
        font-size: 10.5px;
        color: var(--text-2);
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
      .saved-note {
        display: inline-flex;
        align-items: center;
        gap: 4px;
        margin-right: auto;
        font-size: 11.5px;
        color: var(--status-success);
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
              A model translates this meeting's transcript into another
              language. Text only — your audio never leaves the Mac, and a
              local model means zero egress.
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
          <!-- Target-language picker. Always available so the user can change
               the language and re-translate; disabled only while a call is in
               flight. -->
          <div class="lang-row">
            <label class="lang-label" for="translate-target">Translate to</label>
            <select
              id="translate-target"
              class="lang-select"
              [disabled]="translating()"
              [value]="targetName()"
              (change)="onTargetChange($any($event.target).value)"
            >
              @for (t of targets; track t.name) {
                <option [value]="t.name">{{ t.label }}</option>
              }
            </select>
          </div>

          @if (translating()) {
            <div class="generating" aria-live="polite">
              <span class="spinner" aria-hidden="true"></span>
              Translating to {{ targetName() }}…
            </div>
          } @else if (translation(); as result) {
            @if (result.ok) {
              <!-- Receipt — the honest egress disclosure for this call. -->
              <div class="receipt" [class.cloud]="result.egress === 'cloud'">
                <div class="receipt-line">
                  <svg class="r-icon" viewBox="0 0 24 24" width="13" height="13"
                    fill="none" stroke="currentColor" stroke-width="1.7"
                    stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
                    @if (result.egress === 'cloud') {
                      <path d="M7 18a4 4 0 0 1 .5-7.97A6 6 0 0 1 19 11a3.5 3.5 0 0 1-.5 7H7z" />
                    } @else {
                      <rect x="5" y="11" width="14" height="9" rx="2" />
                      <path d="M8 11V8a4 4 0 0 1 8 0v3" />
                    }
                  </svg>
                  <span [innerText]="receiptText()"></span>
                </div>
                @if (result.egress === 'cloud' && redactionChips().length > 0) {
                  <ul class="redaction-list" aria-label="Redaction breakdown">
                    @for (chip of redactionChips(); track chip.category) {
                      <li class="redaction-chip">
                        {{ chip.category }} · {{ chip.count }}
                      </li>
                    }
                  </ul>
                }
              </div>

              <!-- Translated transcript (rendered as preserved-whitespace text). -->
              <pre class="translation-text">{{ result.translation }}</pre>
            } @else {
              <div class="error" role="alert">
                <svg viewBox="0 0 24 24" width="14" height="14" fill="none"
                  stroke="currentColor" stroke-width="1.8" stroke-linecap="round"
                  stroke-linejoin="round" aria-hidden="true">
                  <circle cx="12" cy="12" r="9" />
                  <path d="M12 8v5M12 16.5v.01" />
                </svg>
                <span>{{ result.detail }}</span>
              </div>
            }
          } @else {
            <div class="idle-hint">
              Pick a language and choose Translate to render the whole
              transcript in {{ targetName() }}.
            </div>
          }
        </div>

        <!-- Footer -->
        <div class="footer">
          @if (savedConfirmed()) {
            <span class="saved-note" aria-live="polite">
              <svg viewBox="0 0 24 24" width="12" height="12" fill="none"
                stroke="currentColor" stroke-width="2.4" stroke-linecap="round"
                stroke-linejoin="round" aria-hidden="true">
                <path d="M20 6 9 17l-5-5" />
              </svg>
              Saved to note
            </span>
          }
          <div class="spacer"></div>
          <button
            type="button"
            class="btn"
            [disabled]="translating()"
            (click)="translate()"
            [title]="'Translate the transcript into ' + targetName()"
          >
            {{ hasTranslation() ? 'Re-translate' : 'Translate' }}
          </button>
          <button type="button" class="btn" (click)="onClose()">Close</button>
          @if (hasTranslation()) {
            <button
              type="button"
              class="btn btn-primary"
              [disabled]="savedConfirmed()"
              (click)="saveToNote()"
              title="Append this translation to the saved meeting note"
            >
              Save to note
            </button>
          }
        </div>
      </div>
    </div>
  `,
})
export class TranslatePanelComponent {
  private readonly engine = inject(EngineService);
  private readonly llm = inject(LlmService);

  /** The session id of the meeting being translated — the `translation.write`
   *  target (the most-recently-saved meeting). Threaded from the host. */
  readonly sessionId = input.required<string>();

  /** Host closes the panel (Esc / backdrop / × / Close). */
  readonly close = output<void>();

  /** The offered target languages (for the template @for). */
  protected readonly targets = TRANSLATE_TARGETS;

  /** Currently-selected target language NAME (English). Defaults to the first
   *  offered target. We do NOT auto-translate on open — translation needs a
   *  deliberate choice — so this just seeds the picker. */
  protected readonly targetName = signal<string>(TRANSLATE_TARGETS[0].name);

  /** Projection of the service translate state. */
  protected readonly translating = this.llm.translating;
  protected readonly translation = this.llm.translation;

  /** Transient "Saved to note" confirmation after a successful
   *  translation.write dispatch (the engine acks; failures land on the shared
   *  error channel). Reset on language change / re-translate. */
  protected readonly savedConfirmed = signal(false);

  /** True once a successful translation exists (gates Save to note). */
  protected readonly hasTranslation = computed(() => {
    const r = this.translation();
    return !!r && r.ok;
  });

  /** The egress receipt line. Per ADR-0031: cloud names the model + redaction
   *  count + the text-only-never-audio guarantee; local says nothing left the
   *  Mac. Identical to the Summary panel's receipt. */
  protected readonly receiptText = computed(() => {
    const r = this.translation();
    if (!r || !r.ok) return '';
    if (r.egress === 'local') {
      return `Ran on ${r.model} · ran locally · nothing left your Mac`;
    }
    const n = r.redaction.total;
    const items = `${n} item${n === 1 ? '' : 's'}`;
    return `Sent to ${r.model} · cloud · redacted ${items} · text only — never audio`;
  });

  /** Per-category redaction breakdown for the cloud receipt chips (non-zero
   *  categories only). Empty for local / no redaction. */
  protected readonly redactionChips = computed(() => {
    const r = this.translation();
    if (!r || !r.ok || r.egress !== 'cloud') return [];
    return Object.entries(r.redaction.byCategory)
      .filter(([, count]) => count > 0)
      .map(([category, count]) => ({ category, count }));
  });

  constructor() {
    // Clear any prior meeting's translation so a stale result doesn't flash
    // when the panel mounts. Unlike Summary we do NOT kick off a call here —
    // the user must pick a target and press Translate.
    this.llm.resetTranslation();
  }

  /** The user picked a different target language. Reset the saved note (a
   *  pending translation for a new language hasn't been saved). */
  protected onTargetChange(value: string): void {
    this.targetName.set(value);
    this.savedConfirmed.set(false);
  }

  /** Assemble the transcript + known names and dispatch the translate call.
   *  Re-runnable (the button stays available); a new result replaces the shown
   *  one. Reads the transcript/names off the engine signals at call time. */
  protected async translate(): Promise<void> {
    this.savedConfirmed.set(false);
    const transcript = this.buildTranscript();
    const knownNames = this.buildKnownNames();
    await this.llm.translate({
      transcript,
      targetLang: this.targetName(),
      knownNames,
    });
  }

  /**
   * Build the transcript text from the clean, post-stop labeled utterances
   * (EngineService.segments(), already sorted by tStart). Each line is
   * "<speaker> <mm:ss>: <text>", with the speaker omitted when unknown so we
   * never fabricate one. Text only — no audio, no per-line ids. Identical to
   * the Summary panel's assembler.
   */
  private buildTranscript(): string {
    return this.engine
      .segments()
      .map((s) => {
        const stamp = this.formatTime(s.tStart);
        const speaker = s.speaker ? `${s.speaker} ` : '';
        return `${speaker}${stamp}: ${s.text}`;
      })
      .join('\n');
  }

  /**
   * The applied speaker display-names from the saved roster — the names main
   * collapses to labels before a cloud send (ADR-0031). We take each speaker's
   * applied name: `matched_name` when set, else the label only if it isn't the
   * generic "Speaker N" placeholder (a bare placeholder carries no PII to
   * protect). De-duped, non-empty. Identical to the Summary panel's assembler.
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

  /** Send the generated translation back through the engine to be appended to
   *  the meeting note as a `## Transcript — <lang>` section + git-committed
   *  (ADR-0031). The engine acks; failures land on the shared error channel
   *  (AppComponent's banner). Shows a transient note. */
  protected saveToNote(): void {
    const r = this.translation();
    if (!r || !r.ok) return;
    this.engine.writeTranslation(this.sessionId(), r.targetLang, r.translation);
    this.savedConfirmed.set(true);
  }

  protected onClose(): void {
    this.close.emit();
  }

  @HostListener('document:keydown.escape')
  protected onEscape(): void {
    this.close.emit();
  }

  /** Seconds → mm:ss (or h:mm:ss past an hour). Clamps NaN/negative to 0. */
  private formatTime(seconds: number): string {
    const total =
      Number.isFinite(seconds) && seconds > 0 ? Math.floor(seconds) : 0;
    const s = total % 60;
    const m = Math.floor(total / 60) % 60;
    const h = Math.floor(total / 3600);
    const pad = (n: number) => String(n).padStart(2, '0');
    return h > 0 ? `${h}:${pad(m)}:${pad(s)}` : `${m}:${pad(s)}`;
  }
}
