// SpeakerTag — the chip + name pill atom from the design
// (`components/shared.jsx` `SpeakerTag`). A colored speaker dot, the
// speaker's name, and a chevron hinting it's selectable/relabelable.
//
// `tagged=false` renders an "unlabeled" speaker (a bare "Speaker N") in
// italic + secondary text, matching the design's untagged treatment.
//
// Token-only styling (--surface / --border-2 / --text*). The chip color is
// passed in as a CSS var reference (e.g. "var(--sp-1)") so palette cycling
// stays the caller's job and theme-flipping is free. Introduced for Slice 1
// (3-column layout); reused by the Attendees panel.

import { ChangeDetectionStrategy, Component, input } from '@angular/core';

@Component({
  selector: 'hark-speaker-tag',
  standalone: true,
  changeDetection: ChangeDetectionStrategy.OnPush,
  styles: [
    `
      :host {
        display: inline-flex;
      }
      .tag {
        display: inline-flex;
        align-items: center;
        gap: 6px;
        padding: 3px 8px;
        border-radius: 999px;
        border: 1px solid var(--border-2);
        background: var(--surface);
        font-size: 12px;
        color: var(--text);
      }
      .tag.untagged {
        color: var(--text-2);
        font-style: italic;
      }
      .chip {
        width: 8px;
        height: 8px;
        border-radius: 50%;
        flex-shrink: 0;
        background: var(--chip-color, var(--text-3));
      }
      .chevron {
        color: var(--text-3);
        flex-shrink: 0;
      }
    `,
  ],
  template: `
    <span class="tag" [class.untagged]="!tagged()">
      <span class="chip" [style.--chip-color]="color()" aria-hidden="true"></span>
      <span>{{ name() }}</span>
      <svg
        class="chevron"
        viewBox="0 0 24 24"
        width="10"
        height="10"
        fill="none"
        stroke="currentColor"
        stroke-width="2.2"
        stroke-linecap="round"
        stroke-linejoin="round"
        aria-hidden="true"
      >
        <path d="M6 9l6 6 6-6" />
      </svg>
    </span>
  `,
})
export class SpeakerTagComponent {
  /** Display name (e.g. "Alice Chen" or "Speaker 2"). */
  readonly name = input.required<string>();
  /** Chip color as a CSS var reference, e.g. "var(--sp-1)". */
  readonly color = input<string>('var(--text-3)');
  /** False = an unlabeled speaker → italic + secondary text. */
  readonly tagged = input<boolean>(true);
}
