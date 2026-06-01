// MeetingSavedToast — saved-confirmation card.
//
// Shown after `capture.stop` once the engine has run diarization and
// written the transcript to the vault (the `meeting.saved` frame). Unlike
// the transient bookmark toast, this carries actionable content — the
// speaker roster and the file path — so it stays put until the user
// dismisses it or starts the next capture (AppComponent clears it then).
//
// Token-driven styling to match the StatusBanner / SettingsPanel atoms:
// no hardcoded hex; --accent for the primary glyph, --status-success for
// the confirmation dot, the standard surface/border/text tokens for the
// card. Reveal is delegated upward via the `reveal` output so the IPC call
// stays in AppComponent (same split as settings-panel's revealVault).
//
// Phase 5 v1 speakers are anonymous: each row's matched_name is always
// null, so we render the engine-supplied `label` ("Speaker 1/2/3…").
// Naming UI is Phase 5.1 — deliberately not built here.

import { ChangeDetectionStrategy, Component, computed, input, output } from '@angular/core';
import { MeetingSavedPayload } from '../services/engine.types';

@Component({
  selector: 'hark-meeting-saved-toast',
  standalone: true,
  changeDetection: ChangeDetectionStrategy.OnPush,
  styles: [
    `
      :host {
        display: block;
      }

      .card {
        display: flex;
        flex-direction: column;
        gap: var(--s-3);
        max-width: 360px;
        padding: var(--s-3) var(--s-4);
        background: var(--surface-2);
        border: 1px solid var(--border-2);
        border-radius: var(--r-card);
        box-shadow: var(--shadow-modal);
        color: var(--text);
        font-size: 13px;
      }

      .header {
        display: flex;
        align-items: center;
        gap: var(--s-2);
      }

      .check {
        flex-shrink: 0;
        color: var(--status-success);
      }

      .title {
        font-weight: 600;
        color: var(--text);
      }

      .dismiss {
        margin-left: auto;
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
      .dismiss:hover {
        color: var(--text);
        background: var(--highlight);
      }

      .path {
        display: block;
        font-family: var(--font-mono);
        font-size: 11px;
        color: var(--text-2);
        word-break: break-all;
      }

      .roster {
        display: flex;
        flex-direction: column;
        gap: var(--s-1);
        margin: 0;
        padding: 0;
        list-style: none;
      }

      .roster-row {
        display: flex;
        align-items: center;
        gap: var(--s-2);
        font-size: 12px;
        color: var(--text-2);
      }

      .roster-chip {
        width: 8px;
        height: 8px;
        border-radius: 50%;
        flex-shrink: 0;
        background: var(--sp-color);
      }

      .footer {
        display: flex;
        align-items: center;
        justify-content: flex-end;
      }

      .reveal {
        font-family: var(--font-ui);
        font-size: 12px;
        font-weight: 500;
        padding: 4px 10px;
        border-radius: var(--r-input);
        border: 1px solid var(--border-2);
        background: transparent;
        color: var(--text);
        cursor: pointer;
      }
      .reveal:hover {
        background: var(--highlight);
      }
    `,
  ],
  template: `
    <div class="card" role="status" aria-live="polite">
      <div class="header">
        <svg
          class="check"
          viewBox="0 0 24 24"
          width="15"
          height="15"
          fill="none"
          stroke="currentColor"
          stroke-width="2"
          stroke-linecap="round"
          stroke-linejoin="round"
          aria-hidden="true"
        >
          <path d="M20 6 9 17l-5-5" />
        </svg>
        <span class="title">Meeting saved — {{ speakerCountLabel() }}</span>
        <button type="button" class="dismiss" (click)="dismiss.emit()" aria-label="Dismiss">
          <svg viewBox="0 0 24 24" width="13" height="13" fill="none"
            stroke="currentColor" stroke-width="1.8" stroke-linecap="round"
            aria-hidden="true">
            <path d="M6 6l12 12M18 6 6 18" />
          </svg>
        </button>
      </div>

      <!-- Tail of the vault path for readability; full absolute path on hover. -->
      <code class="path" [title]="saved().vault_path">{{ pathTail() }}</code>

      @if (saved().speakers.length > 0) {
        <ul class="roster">
          @for (sp of saved().speakers; track sp.label; let i = $index) {
            <li class="roster-row">
              <span class="roster-chip" [style.--sp-color]="speakerColor(i)" aria-hidden="true"></span>
              <!-- Phase 5 v1: matched_name is always null, so the label shows. -->
              <span>{{ sp.matched_name ?? sp.label }}</span>
            </li>
          }
        </ul>
      }

      <div class="footer">
        <button type="button" class="reveal" (click)="reveal.emit()" title="Open the vault folder in Finder">
          Reveal in Finder
        </button>
      </div>
    </div>
  `,
})
export class MeetingSavedToastComponent {
  readonly saved = input.required<MeetingSavedPayload>();

  /** User dismissed the card (the × button). */
  readonly dismiss = output<void>();
  /** User asked to reveal the vault in Finder. AppComponent owns the IPC. */
  readonly reveal = output<void>();

  /** "1 speaker" / "N speakers" — singular/plural for the header. */
  protected readonly speakerCountLabel = computed(() => {
    const n = this.saved().speakers.length;
    return `${n} ${n === 1 ? 'speaker' : 'speakers'}`;
  });

  /** Show the path relative to the vault tail (last two segments, e.g.
   *  `meetings/2026-06-01-1432.md`) for readability; the full absolute
   *  path remains available via the title attribute. */
  protected readonly pathTail = computed(() => {
    const parts = this.saved().vault_path.split('/').filter(Boolean);
    return parts.slice(-2).join('/') || this.saved().vault_path;
  });

  /** Cycle the six muted speaker palette tokens (sp-1..sp-6). */
  protected speakerColor(index: number): string {
    return `var(--sp-${(index % 6) + 1})`;
  }
}
