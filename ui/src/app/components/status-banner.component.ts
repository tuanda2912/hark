// StatusBanner — a compact inline banner atom.
//
// A single-line strip with a colored left-border + a small dot + the
// message text. Used for ephemeral, non-blocking status: the engine
// "warming up" notice (info) and runtime warnings like rtf_high
// (warning). Visually consistent with the engine-error banner already
// in app.component and with transcript-line's token-based styling.
//
// Colors map to the project's status tokens (see tailwind.config.js /
// tokens.css): there is no dedicated "danger" token, so `error` reuses
// --status-recording (the red the error banner already uses), `warning`
// uses --status-warning (amber), and `info` uses --accent (the blue
// used elsewhere for primary affordances).

import { ChangeDetectionStrategy, Component, computed, input } from '@angular/core';

type Severity = 'info' | 'warning' | 'error';

@Component({
  selector: 'app-status-banner',
  standalone: true,
  changeDetection: ChangeDetectionStrategy.OnPush,
  styles: [
    `
      :host {
        display: block;
      }

      .banner {
        display: flex;
        align-items: center;
        gap: var(--s-2);
        padding: var(--s-2) var(--s-4);
        font-size: 12px;
        line-height: 1.4;
        background: var(--bg-2);
        border-bottom: 1px solid var(--border);
        border-left: 3px solid var(--sb-color);
        color: var(--text-2);
      }

      .banner-dot {
        width: 8px;
        height: 8px;
        border-radius: 50%;
        flex-shrink: 0;
        background: var(--sb-color);
      }

      /* Info banners gently pulse to read as "in progress" rather than
         a static error — reuses the recording-dot keyframe in tokens.css
         only for the info severity. */
      .banner-info .banner-dot {
        animation: hark-caret 1.4s steps(2) infinite;
      }

      .banner-message {
        color: var(--text);
      }
    `,
  ],
  template: `
    <div class="banner" [class]="severityClass()" [style.--sb-color]="color()">
      <span class="banner-dot" aria-hidden="true"></span>
      <span class="banner-message">{{ message() }}</span>
    </div>
  `,
})
export class StatusBannerComponent {
  readonly message = input.required<string>();
  readonly severity = input<Severity>('info');

  /** Map severity → the matching status CSS-var (see tokens.css). */
  protected readonly color = computed(() => {
    switch (this.severity()) {
      case 'warning':
        return 'var(--status-warning)';
      case 'error':
        return 'var(--status-recording)';
      case 'info':
      default:
        return 'var(--accent)';
    }
  });

  protected readonly severityClass = computed(() => `banner-${this.severity()}`);
}
