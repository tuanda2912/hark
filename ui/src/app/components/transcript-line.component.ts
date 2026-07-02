// TranscriptLine — the transcript feed's centerpiece atom.
//
// Recreated from the design pass (vault/hark/docs/design/ui/components/
// shared.jsx `TranscriptLine`). Renders an optional speaker chip + name,
// a mono timestamp, and the body text. The `partial` flag styles the
// row as a live, not-yet-finalized utterance: italic + secondary color
// + a blinking caret (the design's "live partial at bottom" treatment).
//
// Speaker is optional because diarization is Phase 5 — until then the
// engine sends `speaker: null` and we render timestamp + body only.
// The shape is forward-compatible: pass speaker + speakerColor once
// diarization lands and the chip appears with zero further changes.
//
// Wikilink ([[term]]) parsing from the design is deliberately NOT ported
// yet — that's a vault-linking feature for a later phase. Plain text now.

import { ChangeDetectionStrategy, Component, input } from '@angular/core';

@Component({
  selector: 'hark-transcript-line',
  standalone: true,
  changeDetection: ChangeDetectionStrategy.OnPush,
  styleUrl: './transcript-line.component.css',
  template: `
    <div
      class="tx-line"
      [class.tx-partial]="partial()"
      [class.tx-no-anim]="!animateIn()"
    >
      <div class="tx-line-meta">
        @if (speaker()) {
          <span
            class="sp-chip tx-speaker-chip"
            [style.background]="speakerColor() || 'var(--text-3)'"
          ></span>
          <span
            class="tx-speaker tx-speaker-default"
            [style.--sp-color]="speakerColor() || 'var(--text-2)'"
            >{{ speaker() }}</span
          >
        }
        <span class="tx-time">{{ time() }}</span>
        @if (bookmarked()) {
          <span class="tx-pin" title="Bookmarked moment">
            <svg viewBox="0 0 24 24" width="11" height="11" fill="currentColor" aria-hidden="true">
              <path d="M12 2v6l3 4v3H9v-3l3-4V2M9 15h6M12 18v4" />
            </svg>
            pinned
          </span>
        }
        @if (partial()) {
          <span class="tx-partial-tag">partial</span>
        }
      </div>
      <div class="tx-line-body"
        >{{ text() }}@if (caret()) {<span class="live-caret"></span>}</div
      >
      @if (translation()) {
        <div class="tx-translation">{{ translation() }}</div>
      }
    </div>
  `,
})
export class TranscriptLineComponent {
  readonly time = input<string>('');
  readonly text = input<string>('');
  readonly speaker = input<string | null>(null);
  readonly speakerColor = input<string | null>(null);
  readonly translation = input<string | null>(null);
  /** True while the utterance is still a `segment.partial` (→ italic). */
  readonly partial = input<boolean>(false);
  /** Show the blinking live caret. Only the single newest live line
   *  sets this, so we don't get a row of blinking carets. */
  readonly caret = input<boolean>(false);
  /** Pin glyph — this line's time range contains a bookmark. */
  readonly bookmarked = input<boolean>(false);
  /**
   * Play the `tx-line-in` entrance animation. Default true (a freshly-mounted
   * line rises in). Set FALSE for rows inside the virtual-scroll viewport that
   * are materialized by scrolling through history — those aren't "new", so
   * re-running the entrance on every recycle/materialization would be wrong.
   * The live tail keeps it true so an arriving utterance still settles in.
   */
  readonly animateIn = input<boolean>(true);
}
