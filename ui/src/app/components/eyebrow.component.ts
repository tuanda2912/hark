// Eyebrow — the small mono, uppercase, letter-spaced section label used
// throughout the design (`components/shared.jsx` `Eyebrow`). Appears above
// the Attendees roster, the Ask panel's Answer/Sources sections, etc.
//
// Token-only: mono font + --text-3, no hardcoded values. Content is
// projected so callers stay declarative ("<hark-eyebrow>Attendees · 4</…>").

import { ChangeDetectionStrategy, Component } from '@angular/core';

@Component({
  selector: 'hark-eyebrow',
  standalone: true,
  changeDetection: ChangeDetectionStrategy.OnPush,
  styles: [
    `
      :host {
        display: block;
        font-family: var(--font-mono);
        font-size: 10.5px;
        letter-spacing: 0.12em;
        text-transform: uppercase;
        color: var(--text-3);
      }
    `,
  ],
  template: `<ng-content></ng-content>`,
})
export class EyebrowComponent {}
