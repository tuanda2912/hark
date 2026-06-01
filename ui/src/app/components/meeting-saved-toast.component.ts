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
// Phase 5.1 — speaker naming: the roster is editable. Each row carries the
// engine-known CURRENT label (the `speaker.rename` map key) separately from
// the editable display value, so a user can type "Alice" over "Speaker 1"
// and we still send { "Speaker 1": "Alice" }. After a successful apply the
// row's current label is advanced to the typed name, so a second edit maps
// "Alice" → "Alicia" correctly. The engine acks (no inbound frame); failures
// arrive on EngineService's existing error channel (rendered by AppComponent),
// so we don't subscribe to or invent an error surface here.
//
// Auto-dismiss: this card has NO auto-hide timer (only the bookmark toast in
// AppComponent does). It is dismissed only explicitly — the × button, or the
// next capture start. So there is no editing-vs-timer race to guard against.

import {
  ChangeDetectionStrategy,
  Component,
  computed,
  effect,
  inject,
  input,
  output,
  signal,
} from '@angular/core';
import { MeetingSavedPayload } from '../services/engine.types';
import { EngineService } from '../services/engine.service';

/** One editable roster row. `label` is the engine-known CURRENT key (advanced
 *  to the applied name after a successful rename); `name` is the live text the
 *  user edits. `i` keeps the original palette index stable across edits. */
interface RosterRow {
  readonly label: string;
  readonly name: string;
  readonly i: number;
}

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

      /* Inline name editor — mirrors the SettingsPanel .input atom. */
      .name-input {
        flex: 1;
        min-width: 0;
        font-family: var(--font-ui);
        font-size: 12px;
        color: var(--text);
        padding: 3px 8px;
        background: var(--surface);
        border: 1px solid var(--border-2);
        border-radius: var(--r-input);
        outline: none;
      }
      .name-input::placeholder {
        color: var(--text-3);
      }
      .name-input:focus {
        border-color: var(--accent);
        box-shadow: 0 0 0 3px var(--accent-soft);
      }

      .footer {
        display: flex;
        align-items: center;
        gap: var(--s-2);
        justify-content: flex-end;
      }

      .saved-note {
        display: inline-flex;
        align-items: center;
        gap: 4px;
        margin-right: auto;
        font-size: 11px;
        color: var(--status-success);
      }

      .btn {
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
      .btn:hover:not(:disabled) {
        background: var(--highlight);
      }
      .btn:disabled {
        opacity: 0.5;
        cursor: not-allowed;
      }

      .btn-primary {
        border-color: var(--accent);
        background: var(--accent-soft);
        color: var(--accent);
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

      @if (rows().length > 0) {
        <ul class="roster">
          @for (row of rows(); track row.i; let i = $index) {
            <li class="roster-row">
              <span class="roster-chip" [style.--sp-color]="speakerColor(row.i)" aria-hidden="true"></span>
              <input
                class="name-input"
                type="text"
                [value]="row.name"
                [placeholder]="row.label"
                [attr.aria-label]="'Name for ' + row.label"
                (input)="onNameInput(i, $any($event.target).value)"
                (keydown.enter)="apply()"
              />
            </li>
          }
        </ul>
      }

      <div class="footer">
        @if (savedConfirmed()) {
          <span class="saved-note" aria-live="polite">
            <svg viewBox="0 0 24 24" width="12" height="12" fill="none"
              stroke="currentColor" stroke-width="2.4" stroke-linecap="round"
              stroke-linejoin="round" aria-hidden="true">
              <path d="M20 6 9 17l-5-5" />
            </svg>
            Names saved
          </span>
        }
        @if (rows().length > 0) {
          <button
            type="button"
            class="btn btn-primary"
            [disabled]="!hasChanges()"
            (click)="apply()"
            title="Rename these speakers in the saved transcript"
          >
            Apply names
          </button>
        }
        <button type="button" class="btn" (click)="reveal.emit()" title="Open the vault folder in Finder">
          Reveal in Finder
        </button>
      </div>
    </div>
  `,
})
export class MeetingSavedToastComponent {
  private readonly engine = inject(EngineService);

  readonly saved = input.required<MeetingSavedPayload>();

  /** User dismissed the card (the × button). */
  readonly dismiss = output<void>();
  /** User asked to reveal the vault in Finder. AppComponent owns the IPC. */
  readonly reveal = output<void>();

  /**
   * Editable roster model. Seeded from `saved().speakers`: `name` is the
   * editable display value (matched_name or the label), `label` is the
   * engine-known map key. Kept as a local signal — distinct from the input —
   * so edits and post-apply relabeling don't fight the read-only input.
   */
  protected readonly rows = signal<RosterRow[]>([]);

  /** Re-seed the local model whenever the saved payload changes (e.g. the
   *  same component instance is reused for a new meeting). Resets the
   *  confirmation note too. */
  private readonly _seed = effect(() => {
    const speakers = this.saved().speakers;
    this.rows.set(
      speakers.map((sp, i) => ({
        label: sp.label,
        name: sp.matched_name ?? sp.label,
        i,
      })),
    );
    this.savedConfirmed.set(false);
  });

  /** Shows a subtle "Names saved" note after a successful apply. */
  protected readonly savedConfirmed = signal(false);

  /** True when at least one row's typed name is non-empty and differs from
   *  its current label — i.e. there's something worth sending. Drives the
   *  Apply button's enablement. */
  protected readonly hasChanges = computed(() =>
    this.rows().some((r) => {
      const typed = r.name.trim();
      return typed.length > 0 && typed !== r.label;
    }),
  );

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

  /** Update a single row's editable name. Any keystroke clears the prior
   *  "Names saved" note so it doesn't claim the current edits are persisted. */
  protected onNameInput(index: number, value: string): void {
    this.rows.update((rows) =>
      rows.map((r, i) => (i === index ? { ...r, name: value } : r)),
    );
    if (this.savedConfirmed()) this.savedConfirmed.set(false);
  }

  /** Build the changed-only `names` map, send it, then optimistically advance
   *  each changed row's current label to the applied name so a second edit
   *  maps from the new key. EngineService no-ops an empty map; failures land
   *  on the shared engine error channel (AppComponent's banner). */
  protected apply(): void {
    const names: Record<string, string> = {};
    for (const r of this.rows()) {
      const typed = r.name.trim();
      if (typed.length > 0 && typed !== r.label) names[r.label] = typed;
    }
    if (Object.keys(names).length === 0) return;

    this.engine.renameSpeakers(this.saved().session_id, names);

    // Optimistic: reflect the trimmed names and advance the current label so
    // the key for a follow-up edit is the new name, not the old "Speaker N".
    this.rows.update((rows) =>
      rows.map((r) => {
        const typed = r.name.trim();
        return typed.length > 0 && typed !== r.label
          ? { ...r, name: typed, label: typed }
          : r;
      }),
    );
    this.savedConfirmed.set(true);
  }

  /** Cycle the six muted speaker palette tokens (sp-1..sp-6). */
  protected speakerColor(index: number): string {
    return `var(--sp-${(index % 6) + 1})`;
  }
}
