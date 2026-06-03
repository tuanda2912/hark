// AskPanel — the RIGHT column of the 3-column MainWindow.
//
// STRUCTURE COMPLETE, NON-FUNCTIONAL (Slice 2). Mirrors the full structure of
// the design's Q&A panel (`artboards/QAPanel.jsx` / `screenshots/09-qa-dark`,
// `10-qa-light`): an "ASK" header with a keyboard hint, a question input, a
// model picker, an answer area with inline numbered citations, a "Sources · N"
// section, and a privacy footer. It builds the SHAPE of all of these — it is
// NOT wired to any model.
//
// ── Why a shell ──────────────────────────────────────────────────────
// The provider layer (cloud AND local models) is Phase 6, tracked in
// docs/BACKLOG.md ("LLM / model providers"). The product is provider-
// agnostic by directive — so NO Claude-specific copy here; the picker and the
// empty states talk about "a cloud or local model", never one vendor.
//
// ── How the honest empty states stay honest ──────────────────────────
//   • No model is configured today (`modelConfigured()` is false), so the
//     input is disabled, submit is a guarded no-op, the model picker shows
//     "No model — set up in Settings", and the answer empty state leads with
//     "Connect a model first."
//   • We NEVER render a fake answer or fake source cards. The answer area and
//     Sources section render only their empty states until the answer layer
//     lands; there is no seeded sample content.
//   • The privacy footer is a static, informational note about HOW egress
//     will be itemized for a cloud model — it is explicitly NOT a "this answer
//     used <provider>" log line, because no call has happened and we're
//     provider-agnostic. A local model has no egress and wouldn't show it at
//     all; the note says as much.
//
// ── Wiring when the provider layer lands ─────────────────────────────
// Pass `modelConfigured` from the host (derived from configured providers),
// flip the input to live, wire (ask) to the provider service, and replace the
// `answer`/`sources` empty blocks with the streamed answer (using
// `hark-citation-chip` for inline refs) + real Source cards. The privacy
// footer becomes a real per-answer egress receipt for cloud calls only.

import {
  ChangeDetectionStrategy,
  Component,
  computed,
  input,
  output,
} from '@angular/core';
import { EyebrowComponent } from './eyebrow.component';
import { CitationChipComponent } from './citation-chip.component';
import type { RagIndexStatusPayload } from '../services/engine.types';

/** What an Ask question is answered from (Phase 6 slice 4c, ADR-0032):
 *  'meeting' = THIS meeting's transcript (Slice 3); 'vault' = the whole vault
 *  via local RAG retrieval. The host owns the value + does the retrieval. */
export type AskScope = 'meeting' | 'vault';

/** A resolved source backing an answer (the design's Source card). The host
 *  will populate these from the provider layer; today the list is always
 *  empty, so the Sources section renders only its honest empty state. The
 *  shape is defined now so the card markup is wired (not faked) ahead of the
 *  answer layer. `n` is the 1-based citation number the inline `[n]` refs
 *  point at. */
export interface AnswerSource {
  readonly n: number;
  readonly title: string;
  /** vault-relative path or transcript ref, shown mono accent. */
  readonly ref: string;
  /** A terse date/time stamp, e.g. "Nov 2025" or "00:02:11". */
  readonly stamp: string;
  /** A short verbatim snippet from the source. */
  readonly snippet: string;
}

@Component({
  selector: 'hark-ask-panel',
  standalone: true,
  changeDetection: ChangeDetectionStrategy.OnPush,
  imports: [EyebrowComponent, CitationChipComponent],
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

      /* ─── Header ─────────────────────────────────────────────────── */
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
      /* The ⌘? keyboard hint, mono in a bordered key cap. aria-hidden — it's a
       * visual affordance; the input's own label carries the real semantics. */
      .kbd {
        font-family: var(--font-mono);
        font-size: 10px;
        color: var(--text-3);
        padding: 1px 5px;
        border: 1px solid var(--border);
        border-radius: 3px;
        white-space: nowrap;
        flex-shrink: 0;
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
        flex-shrink: 0;
      }
      .close:hover {
        color: var(--text);
        background: var(--highlight);
      }

      /* ─── Scope toggle (this meeting | vault) ────────────────────────
       * A compact segmented control selecting WHAT a question is answered
       * from. 'vault' routes through local RAG retrieval (slice 4c); the
       * index indicator beside it tells the user the vault is searchable. */
      .scope {
        display: flex;
        align-items: center;
        gap: 8px;
        padding: 10px 14px 2px;
      }
      .scope-seg {
        display: inline-flex;
        padding: 2px;
        gap: 2px;
        border-radius: var(--r-input);
        border: 1px solid var(--border-2);
        background: var(--surface);
      }
      .seg-btn {
        appearance: none;
        border: none;
        background: transparent;
        color: var(--text-3);
        font-family: var(--font-ui);
        font-size: 11.5px;
        font-weight: 500;
        padding: 3px 9px;
        border-radius: calc(var(--r-input) - 2px);
        cursor: pointer;
        white-space: nowrap;
      }
      .seg-btn:hover {
        color: var(--text-2);
      }
      .seg-btn.active {
        color: var(--text);
        background: var(--highlight);
      }
      /* Index indicator — a state dot + terse label, shown only for the vault
       * scope. Truthful: "building" while a cold index runs, "ready" once it
       * can be searched. No fake percentage. */
      .idx {
        display: inline-flex;
        align-items: center;
        gap: 6px;
        min-width: 0;
        font-size: 11px;
        color: var(--text-3);
        overflow: hidden;
      }
      .idx .dot {
        width: 7px;
        height: 7px;
        flex-shrink: 0;
        border-radius: 50%;
        background: var(--text-3);
      }
      .idx.ready .dot {
        background: var(--status-ok, #3fb950);
      }
      .idx.building .dot {
        background: var(--status-cloud, #d29922);
        animation: idx-pulse 1100ms ease-in-out infinite;
      }
      .idx .idx-label {
        min-width: 0;
        overflow: hidden;
        text-overflow: ellipsis;
        white-space: nowrap;
      }
      @keyframes idx-pulse {
        0%,
        100% {
          opacity: 1;
        }
        50% {
          opacity: 0.35;
        }
      }

      /* ─── Question input ─────────────────────────────────────────── */
      .input-wrap {
        padding: 12px 14px 8px;
      }
      .ask-input {
        display: flex;
        align-items: center;
        gap: 8px;
        background: var(--surface);
        border: 1px solid var(--border-2);
        border-radius: var(--r-panel);
        padding: 8px 10px;
      }
      /* Disabled (no model) — dim it so the picker below reads as the next
       * step. When live, this gets the design's accent ring. */
      .ask-input.disabled {
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
      .enter-key {
        font-family: var(--font-mono);
        font-size: 10px;
        color: var(--text-3);
        padding: 1px 4px;
        border: 1px solid var(--border);
        border-radius: 3px;
        flex-shrink: 0;
      }

      /* ─── Model picker ───────────────────────────────────────────── */
      .picker-wrap {
        padding: 0 14px 10px;
      }
      /* The compact "which model answers" selector. Provider-agnostic: it's
       * the hook for the future cloud/local provider layer, NOT a place to
       * configure keys (that's a later Settings slice). With nothing
       * configured it's a CTA that opens Settings. */
      .picker {
        display: flex;
        align-items: center;
        gap: 8px;
        width: 100%;
        padding: 7px 10px;
        border-radius: var(--r-panel);
        border: 1px dashed var(--border-2);
        background: var(--surface);
        color: var(--text-2);
        font-family: var(--font-ui);
        font-size: 12px;
        text-align: left;
        cursor: pointer;
      }
      .picker:hover {
        border-color: var(--accent);
        color: var(--text);
      }
      .picker .pk-icon {
        color: var(--text-3);
        flex-shrink: 0;
      }
      .picker .pk-text {
        flex: 1;
        min-width: 0;
        overflow: hidden;
        text-overflow: ellipsis;
        white-space: nowrap;
      }
      .picker .pk-cta {
        color: var(--accent);
        font-size: 11.5px;
        flex-shrink: 0;
        white-space: nowrap;
      }

      /* ─── Scrolling body (answer + sources) ──────────────────────── */
      .body {
        flex: 1;
        min-height: 0;
        padding: 4px 14px 14px;
      }
      .section-gap {
        margin-top: 18px;
      }

      /* In-flight answer — a small spinner + label while ask() runs. No fake
       * content; mirrors the summary panel's "generating" treatment. */
      .thinking {
        display: flex;
        align-items: center;
        gap: 8px;
        margin-top: 8px;
        padding: 16px;
        border-radius: var(--r-panel);
        border: 1px dashed var(--border-2);
        background: var(--surface);
        color: var(--text-2);
        font-size: 12.5px;
      }
      .spinner {
        width: 14px;
        height: 14px;
        flex-shrink: 0;
        border: 2px solid var(--border-2);
        border-top-color: var(--accent);
        border-radius: 50%;
        animation: ask-spin 700ms linear infinite;
      }
      @keyframes ask-spin {
        to {
          transform: rotate(360deg);
        }
      }

      /* Honest empty state — no answer yet (no model, or not asked). */
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
        /* At the column's clamped minimum (~248px) the title can wrap to two
         * lines; top-align the glyph so it stays beside the first line
         * instead of centering against the taller wrapped block. */
        align-items: flex-start;
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

      /* Sources — empty placeholder beneath the eyebrow. A terse line, not a
       * dashed card, so it doesn't masquerade as a (missing) source card. */
      .sources-empty {
        margin-top: 8px;
        font-size: 12px;
        line-height: 1.5;
        color: var(--text-3);
      }

      /* Source cards — the design's numbered "title · date — snippet" card.
       * Rendered only from real sources(); empty today (no fake cards). */
      .sources {
        margin-top: 8px;
        display: flex;
        flex-direction: column;
        gap: 8px;
      }
      .source-card {
        padding: 10px;
        border-radius: var(--r-panel);
        border: 1px solid var(--border);
        background: var(--surface);
      }
      .source-card .sc-head {
        display: flex;
        align-items: center;
        gap: 6px;
        margin-bottom: 4px;
      }
      .source-card .sc-num {
        display: inline-flex;
        align-items: center;
        justify-content: center;
        width: 16px;
        height: 16px;
        flex-shrink: 0;
        border-radius: 3px;
        background: var(--accent-soft);
        color: var(--accent);
        font-family: var(--font-mono);
        font-size: 10px;
        font-weight: 600;
      }
      .source-card .sc-title {
        flex: 1;
        min-width: 0;
        font-size: 12.5px;
        font-weight: 500;
        color: var(--text);
        overflow: hidden;
        text-overflow: ellipsis;
        white-space: nowrap;
      }
      .source-card .sc-stamp {
        flex-shrink: 0;
        font-family: var(--font-mono);
        font-size: 10px;
        color: var(--text-3);
      }
      .source-card .sc-ref {
        margin-bottom: 4px;
        font-family: var(--font-mono);
        font-size: 10.5px;
        color: var(--accent);
        overflow-wrap: anywhere;
      }
      .source-card .sc-snippet {
        font-size: 12px;
        line-height: 1.5;
        font-style: italic;
        color: var(--text-2);
        overflow-wrap: anywhere;
      }

      /* Answer prose + inline citation treatment. The body is empty until the
       * provider layer fills answer(); the citation refs render via the
       * hark-citation-chip atom. No content today. */
      .answer-prose {
        margin-top: 8px;
        font-size: 13px;
        line-height: 1.6;
        color: var(--text);
        overflow-wrap: anywhere;
      }
      .answer-prose .cite {
        margin-left: 3px;
        vertical-align: baseline;
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

      /* ─── Privacy footer ─────────────────────────────────────────── */
      /* Static, informational. NOT a fake "used <provider>" receipt — see the
       * file header. Cloud-tinted to teach the future affordance: a cloud
       * answer will itemize its egress + redaction here; a local one won't. */
      .privacy {
        display: flex;
        align-items: flex-start;
        gap: 8px;
        padding: 10px 14px;
        border-top: 1px solid var(--border);
        background: color-mix(in oklab, var(--status-cloud) 8%, transparent);
        font-size: 11px;
        line-height: 1.45;
        color: var(--text-2);
      }
      .privacy .cloud-icon {
        color: var(--status-cloud);
        flex-shrink: 0;
        margin-top: 1px;
      }
    `,
  ],
  template: `
    <!-- ─── Header: ASK eyebrow · ⌘? hint · hide ─────────────────────── -->
    <div class="head">
      <hark-eyebrow>Ask</hark-eyebrow>
      <div class="spacer"></div>
      <span class="kbd" aria-hidden="true">⌘?</span>
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

    <!-- ─── Scope toggle: answer from THIS meeting or the whole VAULT ──
         The host owns the value (and does the RAG retrieval for 'vault'); we
         only emit the choice + reflect the index state. -->
    <div class="scope">
      <div class="scope-seg" role="tablist" aria-label="What to answer from">
        <button
          type="button"
          role="tab"
          class="seg-btn"
          [class.active]="scope() === 'meeting'"
          [attr.aria-selected]="scope() === 'meeting'"
          (click)="scopeChange.emit('meeting')"
          title="Answer from this meeting's transcript"
        >
          This meeting
        </button>
        <button
          type="button"
          role="tab"
          class="seg-btn"
          [class.active]="scope() === 'vault'"
          [attr.aria-selected]="scope() === 'vault'"
          (click)="scopeChange.emit('vault')"
          title="Answer from across your whole vault (local search)"
        >
          Vault
        </button>
      </div>
      @if (scope() === 'vault') {
        <div class="idx" [class.ready]="indexState() === 'ready'" [class.building]="indexState() === 'building'">
          <span class="dot" aria-hidden="true"></span>
          <span class="idx-label" [title]="indexLabel()">{{ indexLabel() }}</span>
        </div>
      }
    </div>

    <!-- ─── Question input ───────────────────────────────────────────
         Present for layout fidelity but disabled until a model is connected.
         Submit is a guarded no-op while not enabled. -->
    <div class="input-wrap">
      <div class="ask-input" [class.disabled]="!enabled()">
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
          [disabled]="!enabled() || loading()"
          [placeholder]="inputPlaceholder()"
          [attr.aria-label]="inputPlaceholder()"
          (keydown.enter)="onSubmit($any($event.target))"
        />
        @if (enabled()) {
          <span class="enter-key" aria-hidden="true">↵</span>
        }
      </div>
    </div>

    <!-- ─── Model picker ─────────────────────────────────────────────
         Compact, provider-agnostic selector for WHICH model answers. Today no
         provider is configured, so it's a CTA into Settings. We deliberately
         do NOT render a provider/key form here — that's a later Settings
         slice; this is only the hook. -->
    <div class="picker-wrap">
      @if (!modelConfigured()) {
        <button
          type="button"
          class="picker"
          (click)="openSettings.emit()"
          title="Set up a model in Settings"
          aria-label="No model configured — set one up in Settings"
        >
          <svg
            class="pk-icon"
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
            <rect x="4" y="5" width="16" height="14" rx="2" />
            <path d="M8 9h8M8 13h5" />
          </svg>
          <span class="pk-text">No model</span>
          <span class="pk-cta">Set up in Settings</span>
        </button>
      }
    </div>

    <!-- ─── Body: answer + sources ───────────────────────────────────
         The answer prose and Source cards render ONLY from real answer() /
         sources() inputs — both empty today, so only the honest empty
         states show. No seeded sample content anywhere. -->
    <div class="body scroll-y">
      <hark-eyebrow>Answer</hark-eyebrow>

      @if (loading()) {
        <!-- In-flight answer. A small spinner + label, no fake content — the
             real answer (or an error) replaces this when ask() resolves. -->
        <div class="thinking" aria-live="polite">
          <span class="spinner" aria-hidden="true"></span>
          Thinking…
        </div>
      } @else if (answer(); as text) {
        <!-- Streamed answer prose. Inline numbered citation refs render with
             the citation-chip atom; the host interleaves text + [n] refs
             when the answer layer lands. Empty today. -->
        <div class="answer-prose">
          {{ text }}
          @for (c of answerCitations(); track c) {
            <sup class="cite"
              ><hark-citation-chip [n]="c" [label]="'[' + c + ']'" /></sup>
          }
        </div>
      } @else {
        <!-- Honest empty state. Provider-agnostic copy: the product supports
             cloud AND local models (docs/BACKLOG.md). When no model is
             configured we lead with "Connect a model first." -->
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
            @if (modelConfigured()) {
              @if (scope() === 'vault') {
                Ask across your vault
              } @else {
                Ask about this meeting
              }
            } @else {
              Connect a model first
            }
          </div>
          @if (modelConfigured()) {
            @if (scope() === 'vault') {
              Ask a question and get an answer grounded in your whole vault —
              found by local search, with numbered sources you can verify.
              Nothing is indexed or searched in the cloud.
            } @else {
              Ask a question to get an answer grounded in this meeting's
              transcript — with numbered sources you can verify.
            }
          } @else {
            Connect a model to ask questions and get answers grounded in this
            meeting's transcript and your vault — with numbered sources you can
            verify.
            <div class="hint">
              Bring your own model — cloud or fully local. Set one up in
              Settings.
            </div>
            <span class="soon" aria-hidden="true">coming soon</span>
          }
        </div>
      }

      <!-- Sources · N. Real cards from sources(); empty today → honest
           placeholder line (not a fake card). -->
      <hark-eyebrow class="section-gap">{{ sourcesLabel() }}</hark-eyebrow>
      @if (sources().length > 0) {
        <div class="sources">
          @for (s of sources(); track s.n) {
            <div class="source-card">
              <div class="sc-head">
                <span class="sc-num" aria-hidden="true">{{ s.n }}</span>
                <span class="sc-title" [title]="s.title">{{ s.title }}</span>
                <span class="sc-stamp">{{ s.stamp }}</span>
              </div>
              <div class="sc-ref">{{ s.ref }}</div>
              <div class="sc-snippet">"{{ s.snippet }}"</div>
            </div>
          }
        </div>
      } @else {
        <div class="sources-empty">
          Sources appear here once you ask a question — each numbered source
          links back to the transcript moment or vault note it came from, so
          you can verify every claim.
        </div>
      }
    </div>

    <!-- ─── Privacy footer (informational, NOT a real receipt) ────────
         Explains the future cloud-egress receipt without faking one. No call
         has happened and the product is provider-agnostic, so there's no
         "used <provider>" line. A local model has no egress and wouldn't show
         this at all. -->
    <div class="privacy">
      <svg
        class="cloud-icon"
        viewBox="0 0 24 24"
        width="12"
        height="12"
        fill="none"
        stroke="currentColor"
        stroke-width="1.6"
        stroke-linecap="round"
        stroke-linejoin="round"
        aria-hidden="true"
      >
        <path d="M7 18a4 4 0 0 1 .5-7.97A6 6 0 0 1 19 11a3.5 3.5 0 0 1-.5 7H7z" />
      </svg>
      <span>
        If you choose a cloud model, this footer will itemize exactly what left
        your Mac and what was redacted, per answer. A local model sends nothing.
      </span>
    </div>
  `,
})
export class AskPanelComponent {
  /** True once at least one model provider is configured (cloud or local).
   *  False today — the provider layer is Phase 6. Drives the input enabled
   *  state, the picker CTA, and the answer empty-state copy. */
  readonly modelConfigured = input<boolean>(false);

  /** When true, the input accepts submissions. Derived from
   *  `modelConfigured` for now; kept separate so a future state (e.g. an
   *  in-flight answer) can disable input without un-configuring the model. */
  readonly enabled = input<boolean>(false);

  /** True while an answer is being generated. Takes precedence over `answer`
   *  in the answer area: shows a small spinner + "Thinking…" instead of the
   *  empty state or a stale prior answer while the call is in flight. */
  readonly loading = input<boolean>(false);

  /** The current answer prose, or null when there's no answer (the case
   *  today). Drives the answer-area empty state vs. rendered prose. The host
   *  fills this from the provider layer in a later slice. */
  readonly answer = input<string | null>(null);

  /** The inline citation numbers to render after the answer prose. Empty
   *  today; the host supplies them alongside `answer`. */
  readonly answerCitations = input<readonly number[]>([]);

  /** Resolved Source cards backing the answer. Empty today → the Sources
   *  section shows its honest placeholder rather than any fake card. */
  readonly sources = input<readonly AnswerSource[]>([]);

  /** What a question is answered from (Phase 6 slice 4c). The host owns the
   *  value + does the retrieval for 'vault'; the panel reflects it in the
   *  toggle, the placeholder, and the empty-state copy. */
  readonly scope = input<AskScope>('meeting');

  /** Latest vault RAG index status from the engine, or null (unknown / RAG
   *  unavailable). Drives the index indicator shown beside the toggle when
   *  `scope === 'vault'`. */
  readonly indexStatus = input<RagIndexStatusPayload | null>(null);

  /** A submitted question (only fires when `enabled`). The host reads the
   *  current `scope` to decide meeting- vs vault-grounded answering. */
  readonly ask = output<string>();

  /** The user toggled the answer scope. Host stores it + clears any stale
   *  answer/sources from the other scope. */
  readonly scopeChange = output<AskScope>();

  /** User clicked the "set up a model" CTA. Host opens the Settings modal. */
  readonly openSettings = output<void>();

  /** User hid the panel (the × button). Host collapses the column. */
  readonly dismiss = output<void>();

  /** "Sources" eyebrow with a count once cards exist (the design's
   *  "SOURCES · N"); bare "Sources" while empty. */
  protected readonly sourcesLabel = computed(() => {
    const n = this.sources().length;
    return n > 0 ? `Sources · ${n}` : 'Sources';
  });

  /** Placeholder + aria-label for the question input, scope-aware so the user
   *  knows what they're querying before they type. */
  protected readonly inputPlaceholder = computed(() =>
    this.scope() === 'vault'
      ? 'Ask across your vault…'
      : 'Ask about this meeting…',
  );

  /** The index `state` (or 'unknown' when no status frame has arrived / RAG is
   *  unavailable) — drives the indicator dot's color class. */
  protected readonly indexState = computed(
    () => this.indexStatus()?.state ?? 'unknown',
  );

  /** Terse, honest index-state label. No fake percentage: a building index
   *  shows its count (and total when known); "ready" once searchable. */
  protected readonly indexLabel = computed(() => {
    const s = this.indexStatus();
    if (!s) return 'Vault index status unknown';
    switch (s.state) {
      case 'building':
        return s.total != null
          ? `Indexing your vault… ${s.indexed_count}/${s.total}`
          : `Indexing your vault… (${s.indexed_count})`;
      case 'ready':
        return 'Vault indexed — ready to search';
      case 'idle':
      default:
        return 'Vault index idle';
    }
  });

  protected onSubmit(el: HTMLInputElement): void {
    // Guard: ignore submits while disabled or an answer is already in flight.
    if (!this.enabled() || this.loading()) return;
    const q = el.value.trim();
    if (q.length === 0) return;
    this.ask.emit(q);
    // Clear the field so the next question starts empty; the question is
    // already captured in the emitted event.
    el.value = '';
  }
}
