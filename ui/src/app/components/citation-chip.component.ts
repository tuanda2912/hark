// CitationChip — the inline numbered citation pill atom
// (`components/shared.jsx` `CitationChip`). An accent-soft rounded chip with a
// small numbered box on the left and a label on the right. Used for the
// inline source references in a Q&A answer and the compact source refs.
//
// Token-only: accent / accent-soft + a color-mix border, mono label. The
// numeral box is a slightly denser accent tint than the chip body, matching
// the design. Content is short by construction (a number + a terse label like
// "playbook" or "meeting · 00:02:11"), so the label stays on one line and
// ellipsizes if a caller passes something long inside a narrow column.
//
// Introduced for Slice 2 (the Ask/Q&A panel). It is a presentational atom —
// it renders whatever number + label it's given and emits a click; it does
// NOT know about the (deferred) provider/answer layer. Consistent with the
// other atoms (`eyebrow`, `speaker-tag`): inputs in, no service coupling.

import { ChangeDetectionStrategy, Component, input, output } from '@angular/core';

@Component({
  selector: 'hark-citation-chip',
  standalone: true,
  changeDetection: ChangeDetectionStrategy.OnPush,
  styles: [
    `
      :host {
        display: inline-flex;
        max-width: 100%;
      }
      .chip {
        display: inline-flex;
        align-items: center;
        gap: 4px;
        max-width: 100%;
        padding: 2px 7px 2px 4px;
        border-radius: var(--r-input);
        background: var(--accent-soft);
        border: 1px solid color-mix(in oklab, var(--accent) 30%, transparent);
        font-family: var(--font-mono);
        font-size: 11px;
        line-height: 1.4;
        color: var(--accent);
        cursor: pointer;
      }
      /* When it's purely decorative (e.g. an inline answer ref with no
       * handler), drop the affordance so it doesn't read as clickable. */
      .chip.static {
        cursor: default;
      }
      .num {
        display: inline-flex;
        align-items: center;
        justify-content: center;
        width: 14px;
        height: 14px;
        flex-shrink: 0;
        border-radius: 3px;
        background: color-mix(in oklab, var(--accent) 22%, transparent);
        font-size: 10px;
        font-weight: 600;
      }
      .label {
        min-width: 0;
        overflow: hidden;
        text-overflow: ellipsis;
        white-space: nowrap;
      }
    `,
  ],
  template: `
    <span
      class="chip"
      [class.static]="!interactive()"
      [attr.role]="interactive() ? 'button' : null"
      [attr.tabindex]="interactive() ? 0 : null"
      (click)="interactive() && select.emit()"
      (keydown.enter)="interactive() && select.emit()"
    >
      <span class="num" aria-hidden="true">{{ n() }}</span>
      <span class="label">{{ label() }}</span>
    </span>
  `,
})
export class CitationChipComponent {
  /** The citation number shown in the numeral box (1-based). */
  readonly n = input.required<number>();
  /** The chip label (e.g. "playbook" or "meeting · 00:02:11"). */
  readonly label = input.required<string>();
  /** When true the chip is a button (cursor + role + keyboard) and emits
   *  `select`. Default false — purely decorative until the answer layer wires
   *  a "jump to source" handler. */
  readonly interactive = input<boolean>(false);
  /** Fired on click/Enter when `interactive`. Host scrolls to the source. */
  readonly select = output<void>();
}
