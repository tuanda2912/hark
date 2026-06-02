// AskPanel — the RIGHT column of the 3-column MainWindow.
//
// SHELL ONLY. Mirrors the structure of the design's Q&A panel
// (`artboards/QAPanel.jsx` / the right column of `MainWindow.jsx`): an
// "ASK" eyebrow header, a question input, an answer area, and a numbered
// Sources area. It is NOT wired to any model.
//
// ── Why a shell ──────────────────────────────────────────────────────
// The provider layer (cloud AND local models) is Phase 6, tracked in
// docs/BACKLOG.md ("LLM / model providers"). The product is provider-
// agnostic by directive — so NO Claude-specific copy here. Until a model is
// connected we show an honest empty state and a disabled input rather than
// faking answers/sources.
//
// The input is rendered (so the layout reads true) but disabled and
// non-submitting; submit is a no-op guarded by `enabled` (false in Slice 1).
// When the provider layer lands, flip `enabled`, wire (submit) to the
// provider service, and replace the empty state with streaming answer +
// real Sources cards.

import { ChangeDetectionStrategy, Component, input, output } from '@angular/core';
import { EyebrowComponent } from './eyebrow.component';

@Component({
  selector: 'hark-ask-panel',
  standalone: true,
  changeDetection: ChangeDetectionStrategy.OnPush,
  imports: [EyebrowComponent],
  styles: [
    `
      :host {
        display: flex;
        flex-direction: column;
        min-height: 0;
        height: 100%;
        border-left: 1px solid var(--border);
        background: var(--bg-2);
      }

      .head {
        display: flex;
        align-items: center;
        gap: 8px;
        padding: 12px 14px;
        border-bottom: 1px solid var(--border);
      }
      .head .spacer {
        flex: 1;
      }
      .close {
        display: inline-flex;
        align-items: center;
        justify-content: center;
        width: 22px;
        height: 22px;
        border: none;
        background: transparent;
        color: var(--text-3);
        border-radius: var(--r-input);
        cursor: pointer;
      }
      .close:hover {
        color: var(--text);
        background: var(--highlight);
      }

      .input-wrap {
        padding: 10px 12px;
      }
      .ask-input {
        display: flex;
        align-items: center;
        gap: 8px;
        background: var(--surface);
        border: 1px solid var(--border-2);
        border-radius: var(--r-panel);
        padding: 8px 10px;
        opacity: 0.6;
      }
      .ask-input .icon {
        color: var(--text-3);
        flex-shrink: 0;
      }
      .ask-input input {
        flex: 1;
        min-width: 0;
        font-family: var(--font-ui);
        font-size: 13px;
        color: var(--text);
        background: transparent;
        border: none;
        outline: none;
      }
      .ask-input input::placeholder {
        color: var(--text-3);
      }
      .ask-input input:disabled {
        cursor: not-allowed;
      }

      .body {
        flex: 1;
        min-height: 0;
        padding: 4px 14px 14px;
      }

      /* Honest empty state — no model connected. */
      .empty {
        margin-top: 6px;
        padding: 16px;
        border-radius: var(--r-panel);
        border: 1px dashed var(--border-2);
        background: var(--surface);
        color: var(--text-2);
        font-size: 12.5px;
        line-height: 1.55;
      }
      .empty .empty-title {
        display: flex;
        align-items: center;
        gap: 8px;
        margin-bottom: 8px;
        color: var(--text);
        font-weight: 500;
        font-size: 13px;
      }
      .empty .glyph {
        display: inline-flex;
        align-items: center;
        justify-content: center;
        width: 24px;
        height: 24px;
        border-radius: var(--r-panel);
        background: var(--accent-soft);
        color: var(--accent);
        flex-shrink: 0;
      }
      .empty .hint {
        margin-top: 10px;
        font-size: 11.5px;
        color: var(--text-3);
      }

      .soon {
        margin-top: 12px;
        display: inline-flex;
        align-items: center;
        gap: 6px;
        padding: 3px 8px;
        border-radius: 999px;
        border: 1px solid var(--border);
        background: var(--bg-2);
        font-family: var(--font-mono);
        font-size: 10.5px;
        letter-spacing: 0.04em;
        color: var(--text-3);
      }
    `,
  ],
  template: `
    <div class="head">
      <hark-eyebrow>Ask</hark-eyebrow>
      <div class="spacer"></div>
      <button
        type="button"
        class="close"
        (click)="dismiss.emit()"
        aria-label="Hide the Ask panel"
        title="Hide panel"
      >
        <svg
          viewBox="0 0 24 24"
          width="13"
          height="13"
          fill="none"
          stroke="currentColor"
          stroke-width="1.8"
          stroke-linecap="round"
          aria-hidden="true"
        >
          <path d="M6 6l12 12M18 6 6 18" />
        </svg>
      </button>
    </div>

    <!-- Input is present for layout fidelity but disabled until a model is
         connected. Submit is a no-op while not enabled. -->
    <div class="input-wrap">
      <div class="ask-input">
        <svg
          class="icon"
          viewBox="0 0 24 24"
          width="14"
          height="14"
          fill="none"
          stroke="currentColor"
          stroke-width="1.8"
          stroke-linecap="round"
          stroke-linejoin="round"
          aria-hidden="true"
        >
          <circle cx="11" cy="11" r="7" />
          <path d="M21 21l-4.3-4.3" />
        </svg>
        <input
          type="text"
          [disabled]="!enabled()"
          placeholder="Ask about this meeting…"
          aria-label="Ask a question about this meeting"
          (keydown.enter)="onSubmit($any($event.target).value)"
        />
      </div>
    </div>

    <div class="body scroll-y">
      <!-- No model connected → honest empty state. Provider-agnostic copy:
           the product supports cloud AND local models (docs/BACKLOG.md). -->
      <div class="empty">
        <div class="empty-title">
          <span class="glyph" aria-hidden="true">
            <svg
              viewBox="0 0 24 24"
              width="13"
              height="13"
              fill="none"
              stroke="currentColor"
              stroke-width="1.8"
              stroke-linecap="round"
              stroke-linejoin="round"
            >
              <path d="M7.5 8.5h9M7.5 12h6" />
              <path d="M4 5h16v11H8l-4 3z" />
            </svg>
          </span>
          Ask about this meeting
        </div>
        Connect a model to ask questions and get answers grounded in your
        transcript and vault — with numbered sources you can verify.
        <div class="hint">
          Bring your own model — cloud or fully local. Set one up in Settings.
        </div>
        <span class="soon" aria-hidden="true">coming soon</span>
      </div>
    </div>
  `,
})
export class AskPanelComponent {
  /** When true, the input accepts submissions. False for Slice 1 (no model
   *  layer yet). Flip this when the provider layer lands. */
  readonly enabled = input<boolean>(false);

  /** A submitted question (only fires when `enabled`). Host wires this to the
   *  provider service in a later slice. */
  readonly ask = output<string>();

  /** User hid the panel (the × button). Host collapses the column. */
  readonly dismiss = output<void>();

  protected onSubmit(value: string): void {
    if (!this.enabled()) return;
    const q = value.trim();
    if (q.length > 0) this.ask.emit(q);
  }
}
