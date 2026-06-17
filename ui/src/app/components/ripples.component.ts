// Ripples — the "Heard ripples" identity motif, reusable across the shell's
// resting + listening states (transcript / attendees / ask empty states).
//
// Concentric accent rings + a center dot. At rest the rings ripple outward
// SLOWLY and the core breathes — a quiet "I'm here, ready" pulse; with `active`
// (capturing) the same ripple speeds up into the livelier "hearing the room"
// cue. Pure CSS over SVG (no JS animation, no external asset), accent-tinted
// via the design token so it tracks the theme. Honors prefers-reduced-motion:
// all movement stops and only the two static base rings + core remain.

import { ChangeDetectionStrategy, Component, input } from '@angular/core';

@Component({
  selector: 'hark-ripples',
  standalone: true,
  changeDetection: ChangeDetectionStrategy.OnPush,
  host: { '[class.is-active]': 'active()', '[style.color]': 'color()' },
  styles: [
    `
      :host {
        display: inline-flex;
        line-height: 0;
      }
      svg {
        display: block;
      }
      .ring {
        transform-box: fill-box;
        transform-origin: center;
      }
      /* Resting: a slow, calm ripple so the mark is alive the moment you look
       * at it — not waiting on capture. The two staggered echoes keep a ring
       * always on screen. */
      .echo {
        opacity: 0;
        animation: rp-out 4.4s var(--ease-out, ease-out) infinite;
      }
      .echo-2 {
        animation-delay: 2.2s;
      }
      .core {
        animation: rp-core 4.4s ease-in-out infinite;
      }
      /* Active (capturing): same motion, ~2× faster — clearly livelier without
       * being a different animation. */
      :host(.is-active) .echo,
      :host(.is-active) .core {
        animation-duration: 2.4s;
      }
      :host(.is-active) .echo-2 {
        animation-delay: 1.2s;
      }
      @keyframes rp-out {
        0% {
          transform: scale(0.34);
          opacity: 0.45;
        }
        80% {
          opacity: 0;
        }
        100% {
          transform: scale(1);
          opacity: 0;
        }
      }
      @keyframes rp-core {
        0%,
        100% {
          opacity: 1;
        }
        50% {
          opacity: 0.6;
        }
      }
      @media (prefers-reduced-motion: reduce) {
        .echo,
        .core {
          animation: none;
        }
      }
    `,
  ],
  template: `
    <svg
      [attr.width]="size()"
      [attr.height]="size()"
      viewBox="0 0 100 100"
      aria-hidden="true"
    >
      <circle class="ring" cx="50" cy="50" r="47" fill="none"
        stroke="currentColor" stroke-opacity="0.10" stroke-width="1.5" />
      <circle class="ring" cx="50" cy="50" r="30" fill="none"
        stroke="currentColor" stroke-opacity="0.22" stroke-width="1.5" />
      <circle class="ring echo" cx="50" cy="50" r="47" fill="none"
        stroke="currentColor" stroke-opacity="0.6" stroke-width="1.5" />
      <circle class="ring echo echo-2" cx="50" cy="50" r="47" fill="none"
        stroke="currentColor" stroke-opacity="0.6" stroke-width="1.5" />
      <circle class="core" cx="50" cy="50" r="8" fill="currentColor" />
    </svg>
  `,
})
export class RipplesComponent {
  /** Rendered width/height in px (square). */
  readonly size = input<number>(72);
  /** When true (capturing), the rings ripple outward faster — the livelier cue. */
  readonly active = input<boolean>(false);
  /** Tint for the rings + core (any CSS color). Defaults to the brand accent;
   *  override e.g. with the recording red in the tray's capturing state. */
  readonly color = input<string>('var(--accent)');
}
