// SummaryPanel — generate + review a meeting summary (Phase 6 slice 2,
// ADR-0029 / ADR-0031).
//
// A centered modal opened from the meeting-saved card. It:
//   1. Assembles the transcript TEXT from EngineService.segments() (the clean,
//      post-stop labeled utterances) as "<speaker> <mm:ss>: <text>" lines, and
//      the applied speaker display-names as `knownNames`.
//   2. Sends both to main via LlmService.summarize — the renderer makes NO
//      network call. Main owns the cloud/local fork, the redaction (cloud
//      only), and the provider HTTP. We only consume the result.
//   3. Renders the returned summary markdown readably (whitespace-pre body —
//      no markdown dependency) plus an honest egress receipt:
//        cloud → "Sent to {model} · cloud · redacted N item(s) · text only —
//                 never audio"
//        local → "Ran on {model} · ran locally · nothing left your Mac"
//      and a redaction breakdown by category when there is one.
//   4. On "Save to note" sends the summary back through the ENGINE
//      (EngineService.writeSummary → `summary.write`), which appends a
//      `## Summary` section to the meeting file + git-commits (ADR-0031 — the
//      renderer never writes the vault, main never writes it behind the
//      engine's back). Shows a transient "Saved ✓".
//
// Token-only styling, OnPush, signals, @if/@for, strict-CSP-safe (no inline
// handlers). Modal chrome mirrors the speaker-tagging / post-meeting-review
// modals: a token-dimmed backdrop + a risen card; Esc / backdrop / × close.

import {
  ChangeDetectionStrategy,
  Component,
  HostListener,
  computed,
  effect,
  inject,
  input,
  output,
  signal,
} from '@angular/core';
import { EngineService } from '../services/engine.service';
import { LlmService } from '../services/llm.service';

@Component({
  selector: 'hark-summary-panel',
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
        animation: summary-fade 120ms ease-out;
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
        animation: summary-rise 140ms cubic-bezier(0.2, 0.8, 0.2, 1);
      }

      @keyframes summary-fade {
        from {
          opacity: 0;
        }
        to {
          opacity: 1;
        }
      }
      @keyframes summary-rise {
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
        animation: summary-spin 700ms linear infinite;
      }
      @keyframes summary-spin {
        to {
          transform: rotate(360deg);
        }
      }

      /* The summary markdown body. We don't pull in a markdown renderer; the
         text is shown with preserved whitespace + wrapping so headings / bullet
         lines / paragraphs read sensibly. */
      .summary-text {
        margin: 0;
        font-family: var(--font-ui);
        font-size: 13.5px;
        line-height: 1.6;
        color: var(--text);
        white-space: pre-wrap;
        overflow-wrap: anywhere;
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
        aria-label="Meeting summary"
        (click)="$event.stopPropagation()"
      >
        <!-- Header -->
        <div class="head">
          <div class="head-text">
            <div class="title">Summary</div>
            <div class="subtitle">
              A model condenses this meeting's transcript. Text only — your
              audio never leaves the Mac.
            </div>
          </div>
          <button
            type="button"
            class="close"
            (click)="onClose()"
            title="Close (Esc)"
            aria-label="Close summary"
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
          @if (summarizing()) {
            <div class="generating" aria-live="polite">
              <span class="spinner" aria-hidden="true"></span>
              Summarizing…
            </div>
          } @else if (summary(); as result) {
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

              <!-- Summary markdown (rendered as preserved-whitespace text). -->
              <pre class="summary-text">{{ result.summary }}</pre>
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
          @if (canRetry()) {
            <button type="button" class="btn" (click)="generate()">
              Try again
            </button>
          }
          <button type="button" class="btn" (click)="onClose()">Close</button>
          @if (hasSummary()) {
            <button
              type="button"
              class="btn btn-primary"
              [disabled]="savedConfirmed()"
              (click)="saveToNote()"
              title="Append this summary to the saved meeting note"
            >
              Save to note
            </button>
          }
        </div>
      </div>
    </div>
  `,
})
export class SummaryPanelComponent {
  private readonly engine = inject(EngineService);
  private readonly llm = inject(LlmService);

  /** The session id of the meeting being summarized — the `summary.write`
   *  target (the most-recently-saved meeting). Threaded from the host. */
  readonly sessionId = input.required<string>();

  /** Host closes the panel (Esc / backdrop / × / Close). */
  readonly close = output<void>();

  /** Projection of the service summarize state. */
  protected readonly summarizing = this.llm.summarizing;
  protected readonly summary = this.llm.summary;

  /** Transient "Saved to note" confirmation after a successful summary.write
   *  dispatch (the engine acks; failures land on the shared error channel). */
  protected readonly savedConfirmed = signal(false);

  /** True once a successful summary exists (gates Save to note). */
  protected readonly hasSummary = computed(() => {
    const r = this.summary();
    return !!r && r.ok;
  });

  /** Show "Try again" once a call has finished (success OR error) so the user
   *  can regenerate — e.g. after a transient cloud error. */
  protected readonly canRetry = computed(
    () => !this.summarizing() && this.summary() !== null,
  );

  /** The egress receipt line. Per ADR-0031: cloud names the model + redaction
   *  count + the text-only-never-audio guarantee; local says nothing left the
   *  Mac. */
  protected readonly receiptText = computed(() => {
    const r = this.summary();
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
    const r = this.summary();
    if (!r || !r.ok || r.egress !== 'cloud') return [];
    return Object.entries(r.redaction.byCategory)
      .filter(([, count]) => count > 0)
      .map(([category, count]) => ({ category, count }));
  });

  /**
   * Kick off generation when the panel mounts (or the target meeting changes).
   * Reads the transcript + known names off the engine signals at call time and
   * sends them to main via LlmService.summarize. Clearing the prior summary
   * happens inside summarize() so the spinner shows immediately.
   */
  private readonly _autoGenerate = effect(() => {
    // Register the session-id dependency so a different meeting re-generates.
    const session = this.sessionId();
    if (!session) return;
    // Run the async kick-off outside the reactive read so signal writes inside
    // summarize() don't loop.
    queueMicrotask(() => void this.generate());
  });

  /** Assemble the transcript + known names and dispatch the summarize call.
   *  Re-runnable from "Try again". */
  protected async generate(): Promise<void> {
    this.savedConfirmed.set(false);
    const transcript = this.buildTranscript();
    const knownNames = this.buildKnownNames();
    await this.llm.summarize({ transcript, knownNames });
  }

  /**
   * Build the transcript text from the clean, post-stop labeled utterances
   * (EngineService.segments(), already sorted by tStart). Each line is
   * "<speaker> <mm:ss>: <text>", with the speaker omitted when unknown so we
   * never fabricate one. Text only — no audio, no per-line ids.
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
      // The label is an applied name once a rename advanced it past the generic
      // "Speaker N" placeholder; include it then so it's collapsed on a cloud
      // send too.
      const label = sp.label.trim();
      if (label && !/^Speaker\s+\d+$/i.test(label)) names.add(label);
    }
    return Array.from(names);
  }

  /** Send the generated summary back through the engine to be appended to the
   *  meeting note + git-committed (ADR-0031). The engine acks; failures land on
   *  the shared error channel (AppComponent's banner). Shows a transient note. */
  protected saveToNote(): void {
    const r = this.summary();
    if (!r || !r.ok) return;
    this.engine.writeSummary(this.sessionId(), r.summary);
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
