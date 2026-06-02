// ModelLoading — the first-run "Preparing Hark" warm-up overlay.
//
// A fresh install has no cached models, so harkd's cold start downloads
// and ANE-compiles the speech + diarizer models before it emits
// `meta.ready`. That can take tens of seconds with no feedback — the app
// looks hung. This full-bleed overlay, driven by `meta.model_progress`,
// turns that dead air into reassuring, honest progress.
//
// Determinate vs indeterminate: the download phases carry a 0..1
// `fraction` (a real byte count) → we render a determinate bar with a %.
// The ANE-compile / optimization phases have no measurable progress →
// `fraction` is null → we render an indeterminate spinner and DO NOT fake
// a percentage. The choice is purely `fraction() == null`.
//
// Token-driven styling only (no hardcoded hex): --bg / --bg-2 for the
// scrim, --accent for the bar/spinner, --status-cloud + the cloud-off
// glyph for the local-only reassurance line — echoing the top bar's trust
// lozenge so the tone is consistent. OnPush + signals; the host fills its
// positioned parent (AppComponent stacks it over the content area).

import { ChangeDetectionStrategy, Component, computed, input } from '@angular/core';

@Component({
  selector: 'hark-model-loading',
  standalone: true,
  changeDetection: ChangeDetectionStrategy.OnPush,
  styles: [
    `
      :host {
        position: absolute;
        inset: 0;
        z-index: 20;
        display: flex;
        align-items: center;
        justify-content: center;
        /* Slightly lifted off pure --bg so it reads as a distinct surface
           even when the content area behind it is also --bg. */
        background: var(--bg);
      }

      .panel {
        display: flex;
        flex-direction: column;
        align-items: center;
        gap: var(--s-6);
        width: 100%;
        max-width: 420px;
        padding: var(--s-8) var(--s-6);
        text-align: center;
      }

      /* Wordmark — display font, matches the brand voice without inventing
         a logo asset (none is bundled; remote assets are disallowed). */
      .wordmark {
        font-family: var(--font-display);
        font-size: 13px;
        font-weight: 600;
        letter-spacing: 0.22em;
        text-transform: uppercase;
        color: var(--text-3);
      }

      .heading {
        font-family: var(--font-display);
        font-size: 22px;
        font-weight: 600;
        letter-spacing: -0.01em;
        color: var(--text);
        margin: 0;
      }

      .detail {
        font-size: 13px;
        color: var(--text-2);
        min-height: 1.2em; /* avoid layout jump as the label changes */
      }

      /* ── Progress block — bar OR spinner, never both ── */
      .progress {
        display: flex;
        flex-direction: column;
        align-items: center;
        gap: var(--s-3);
        width: 100%;
      }

      .bar-row {
        display: flex;
        align-items: center;
        gap: var(--s-3);
        width: 100%;
      }

      .bar-track {
        flex: 1;
        height: 6px;
        border-radius: 999px;
        background: var(--bg-2);
        overflow: hidden;
      }

      .bar-fill {
        height: 100%;
        border-radius: 999px;
        background: var(--accent);
        /* Smooth the bar between progress ticks; transform-free width
           transition is fine here, it's not animated per-frame. */
        transition: width 240ms ease;
      }

      .bar-pct {
        flex-shrink: 0;
        width: 3.5ch;
        text-align: right;
        font-family: var(--font-mono);
        font-size: 12px;
        color: var(--text-2);
        font-variant-numeric: tabular-nums;
      }

      /* Indeterminate spinner for the ANE-compile phase (no byte count). */
      .spinner {
        width: 28px;
        height: 28px;
        border-radius: 50%;
        border: 3px solid var(--bg-2);
        border-top-color: var(--accent);
        animation: hark-model-spin 0.9s linear infinite;
      }

      @keyframes hark-model-spin {
        to {
          transform: rotate(360deg);
        }
      }

      @media (prefers-reduced-motion: reduce) {
        .spinner {
          animation-duration: 2.2s;
        }
        .bar-fill {
          transition: none;
        }
      }

      .reassure {
        font-size: 12px;
        line-height: 1.5;
        color: var(--text-3);
        max-width: 32ch;
        margin: 0;
      }

      /* Local-only line — echoes the top-bar trust lozenge's tone/tokens. */
      .trust {
        display: inline-flex;
        align-items: center;
        gap: var(--s-1);
        font-family: var(--font-mono);
        font-size: 11px;
        color: var(--status-cloud);
      }
      .trust svg {
        flex-shrink: 0;
      }
    `,
  ],
  template: `
    <div class="panel" role="status" aria-live="polite">
      <span class="wordmark">Hark</span>
      <h1 class="heading">Preparing Hark</h1>

      <p class="detail">{{ detailText() }}</p>

      <div class="progress">
        @if (fraction() !== null) {
          <!-- Determinate: real byte progress for the download phases. -->
          <div class="bar-row">
            <div
              class="bar-track"
              role="progressbar"
              aria-label="Model preparation progress"
              aria-valuemin="0"
              aria-valuemax="100"
              [attr.aria-valuenow]="percent()"
            >
              <div class="bar-fill" [style.width.%]="percent()"></div>
            </div>
            <span class="bar-pct">{{ percent() }}%</span>
          </div>
        } @else {
          <!-- Indeterminate: ANE compile has no measurable progress — a
               spinner, never a fake percentage. -->
          <div
            class="spinner"
            role="progressbar"
            aria-label="Optimizing model — this may take a moment"
            aria-busy="true"
          ></div>
        }
      </div>

      <p class="reassure">
        Setting up on-device transcription — this happens once.
      </p>

      <span
        class="trust"
        title="Models are downloaded and prepared on this Mac. No audio leaves your machine."
      >
        <svg
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
          <path
            d="M3 3l18 18M7 17.5A4.5 4.5 0 0 1 7.5 8.5M9.5 5.5A6 6 0 0 1 19 10a3.5 3.5 0 0 1 1.7 6.6"
          />
        </svg>
        all on-device
      </span>
    </div>
  `,
})
export class ModelLoadingComponent {
  /**
   * Human label from the current `meta.model_progress` frame, or null
   * before the first frame arrives. Falls back to "Starting engine…" so
   * the overlay never shows an empty line during the brief window between
   * "warm-up began" and "first progress frame".
   */
  readonly detail = input<string | null>(null);

  /**
   * 0..1 from the engine for determinate (download) phases; null for the
   * indeterminate ANE-compile phases. Drives bar-vs-spinner. The bar shows
   * a clamped, rounded percentage; null shows the spinner with no number.
   */
  readonly fraction = input<number | null>(null);

  protected readonly detailText = computed(
    () => this.detail()?.trim() || 'Starting engine…',
  );

  /** Whole-number percent, clamped to 0..100. Only read when fraction != null. */
  protected readonly percent = computed(() => {
    const f = this.fraction();
    if (f === null) return 0;
    return Math.round(Math.min(1, Math.max(0, f)) * 100);
  });
}
