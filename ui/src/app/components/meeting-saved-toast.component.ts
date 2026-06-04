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
// and we still send { "Speaker 1": "Alice" }. The engine acks (no inbound
// frame); failures arrive on EngineService's existing error channel (rendered
// by AppComponent), so we don't subscribe to or invent an error surface here.
//
// SOURCE OF TRUTH for the optimistic rename is EngineService.renameSpeakers,
// which updates the retained `meeting.saved` roster (label→name,
// matched_name→name) so EVERY consumer of lastMeetingSaved() — this card AND
// the left Attendees panel — reflects the new name at once. This card's
// `saved` input is derived from that same signal, so after apply() the input
// changes and `_seed` re-derives `rows` from the renamed speakers. We
// therefore do NOT keep a second local optimistic relabel here (it would
// duplicate the service's). The only thing `_seed` must be careful about: only
// reset the "Names saved" note when the payload is a genuinely DIFFERENT
// meeting (new session_id), not on an in-place rename of the same one.
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
import { LlmService } from '../services/llm.service';

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

      /* Up to five actions live here (Apply names · Summarize · Translate ·
         Review & tag · Reveal). They must WRAP instead of forcing the card past
         its max-width — otherwise the non-shrinking buttons balloon the whole
         toast and stretch the name inputs. (gap covers both row + column gaps.) */
      .footer {
        display: flex;
        flex-wrap: wrap;
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

      /* Review & tag — accent-tinted, icon + label. Distinct from the bare
         Reveal button so the verify-by-ear path reads as the richer action. */
      .btn-review {
        display: inline-flex;
        align-items: center;
        gap: 5px;
        border-color: color-mix(in oklab, var(--accent) 45%, transparent);
        color: var(--accent);
      }
      .btn-review:hover {
        background: var(--accent-soft);
      }
      .btn-review svg {
        flex-shrink: 0;
      }

      /* Summarize — icon + label, like Review & tag. When a model IS
         configured it's accent-tinted (the rich action); when none is, it
         reads as a quieter CTA that routes to Settings. */
      .btn-summarize {
        display: inline-flex;
        align-items: center;
        gap: 5px;
      }
      .btn-summarize.is-ready {
        border-color: color-mix(in oklab, var(--accent) 45%, transparent);
        color: var(--accent);
      }
      .btn-summarize.is-ready:hover {
        background: var(--accent-soft);
      }
      .btn-summarize svg {
        flex-shrink: 0;
      }

      /* Translate — sibling of Summarize, same icon + label treatment and
         model-config accent state. */
      .btn-translate {
        display: inline-flex;
        align-items: center;
        gap: 5px;
      }
      .btn-translate.is-ready {
        border-color: color-mix(in oklab, var(--accent) 45%, transparent);
        color: var(--accent);
      }
      .btn-translate.is-ready:hover {
        background: var(--accent-soft);
      }
      .btn-translate svg {
        flex-shrink: 0;
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
        <!-- Summarize — sends the transcript TEXT to the configured model
             (cloud or local) via main; never needs audio (works regardless of
             Keep audio). When a model is configured this opens the Summary
             panel; with none it routes to Settings to set one up. -->
        <button
          type="button"
          class="btn btn-summarize"
          [class.is-ready]="modelConfigured()"
          (click)="onSummarize()"
          [title]="modelConfigured()
            ? 'Summarize this meeting with your model'
            : 'Set up a model in Settings to summarize'"
        >
          <svg viewBox="0 0 24 24" width="12" height="12" fill="none"
            stroke="currentColor" stroke-width="1.8" stroke-linecap="round"
            stroke-linejoin="round" aria-hidden="true">
            <path d="M4 6h16M4 11h16M4 16h9" />
          </svg>
          @if (modelConfigured()) {
            Summarize
          } @else {
            Summarize…
          }
        </button>
        <!-- Translate — sends the transcript TEXT to the configured model
             (cloud or local) via main to translate into a chosen language;
             never needs audio. When a model is configured this opens the
             Translate panel; with none it routes to Settings. -->
        <button
          type="button"
          class="btn btn-translate"
          [class.is-ready]="modelConfigured()"
          (click)="onTranslate()"
          [title]="modelConfigured()
            ? 'Translate this meeting with your model'
            : 'Set up a model in Settings to translate'"
        >
          <svg viewBox="0 0 24 24" width="12" height="12" fill="none"
            stroke="currentColor" stroke-width="1.8" stroke-linecap="round"
            stroke-linejoin="round" aria-hidden="true">
            <path d="M4 5h7M9 3v2c0 4-2.5 7-5 8M5 9c0 2 2.5 4 6 4" />
            <path d="M13 19l4-9 4 9M14.5 16h5" />
          </svg>
          @if (modelConfigured()) {
            Translate
          } @else {
            Translate…
          }
        </button>
        <!-- Verify-by-ear path — only when the meeting kept its audio
             (audio_path non-null). Opens the Post-Meeting Review screen to
             play the recording and tag speakers by listening. When audio
             wasn't kept this affordance is absent and the inline roster
             editor above remains the naming path. -->
        @if (hasAudio()) {
          <button
            type="button"
            class="btn btn-review"
            (click)="review.emit()"
            title="Play the recording and tag speakers by ear"
          >
            <svg viewBox="0 0 24 24" width="12" height="12" fill="none"
              stroke="currentColor" stroke-width="1.8" stroke-linecap="round"
              stroke-linejoin="round" aria-hidden="true">
              <path d="M8 5.14v13.72a.6.6 0 0 0 .92.5l10.7-6.86a.6.6 0 0 0 0-1l-10.7-6.86a.6.6 0 0 0-.92.5z" />
            </svg>
            Review &amp; tag
          </button>
        }
        <button type="button" class="btn" (click)="reveal.emit()" title="Show this meeting's note in Finder">
          Reveal in Finder
        </button>
      </div>
    </div>
  `,
})
export class MeetingSavedToastComponent {
  private readonly engine = inject(EngineService);
  private readonly llm = inject(LlmService);

  readonly saved = input.required<MeetingSavedPayload>();

  /** True once an LLM provider is configured (ADR-0029). Drives the Summarize
   *  button: configured → opens the Summary panel; not → routes to Settings. */
  protected readonly modelConfigured = this.llm.configured;

  /** User dismissed the card (the × button). */
  readonly dismiss = output<void>();
  /** User asked to reveal this meeting's note in Finder. AppComponent owns the
   *  IPC and reads the saved meeting's `vault_path` to select it. */
  readonly reveal = output<void>();
  /** User asked to open the Post-Meeting Review screen (verify-by-ear speaker
   *  tagging). Emitted ONLY from the affordance shown when audio was kept
   *  (audio_path non-null); the host mounts the review takeover. */
  readonly review = output<void>();
  /** User asked to summarize this meeting AND a model is configured — host
   *  opens the Summary panel for this session. */
  readonly summarize = output<void>();
  /** User asked to translate this meeting AND a model is configured — host
   *  opens the Translate panel for this session. */
  readonly translate = output<void>();
  /** User asked to summarize/translate but no model is configured — host opens
   *  Settings (mirrors the Ask panel's "set up a model" routing). */
  readonly openSettings = output<void>();

  /**
   * Editable roster model. Seeded from `saved().speakers`: `name` is the
   * editable display value (matched_name or the label), `label` is the
   * engine-known map key. Kept as a local signal — distinct from the input —
   * so edits and post-apply relabeling don't fight the read-only input.
   */
  protected readonly rows = signal<RosterRow[]>([]);

  /** Tracks which meeting the local model is currently seeded from, so we can
   *  tell a NEW meeting (reset the note) from an in-place rename of the same
   *  one (keep the "Names saved" note the user just earned). */
  private seededSession: string | null = null;

  /** Re-seed the editable model whenever the saved payload changes — both when
   *  the component instance is reused for a new meeting AND when the service
   *  applies an optimistic rename to the same meeting (which mutates
   *  speakers → label/matched_name). Rows are always re-derived from the
   *  current payload (the single source of truth). The confirmation note is
   *  reset ONLY on a genuinely different meeting. */
  private readonly _seed = effect(() => {
    const saved = this.saved();
    this.rows.set(
      saved.speakers.map((sp, i) => ({
        label: sp.label,
        name: sp.matched_name ?? sp.label,
        i,
      })),
    );
    if (saved.session_id !== this.seededSession) {
      this.savedConfirmed.set(false);
      this.seededSession = saved.session_id;
    }
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

  /** True when this meeting kept its audio (ADR-0027/0028) — i.e. the
   *  recording is on disk and the verify-by-ear Review screen can play it.
   *  Gates the "Review & tag speakers" affordance; when false the inline
   *  roster editor above stays the only naming path. */
  protected readonly hasAudio = computed(
    () => typeof this.saved().audio_path === 'string' && this.saved().audio_path !== '',
  );

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

  /** Build the changed-only `names` map and send it. EngineService applies the
   *  optimistic roster update (advancing each changed label→name and setting
   *  matched_name), which flows back through `saved()` → `_seed` and re-derives
   *  `rows` — so a follow-up edit already maps from the new key. We don't
   *  relabel locally here (that would duplicate the service's update). The
   *  engine no-ops an empty map; failures land on the shared engine error
   *  channel (AppComponent's banner). */
  protected apply(): void {
    const names: Record<string, string> = {};
    for (const r of this.rows()) {
      const typed = r.name.trim();
      if (typed.length > 0 && typed !== r.label) names[r.label] = typed;
    }
    if (Object.keys(names).length === 0) return;

    this.engine.renameSpeakers(this.saved().session_id, names);
    this.savedConfirmed.set(true);
  }

  /** Summarize affordance. With a model configured, ask the host to open the
   *  Summary panel; without one, route to Settings to set a model up (the same
   *  pattern as the Ask panel's empty-state CTA). */
  protected onSummarize(): void {
    if (this.modelConfigured()) this.summarize.emit();
    else this.openSettings.emit();
  }

  /** Translate affordance. Same model-config routing as Summarize: with a model
   *  open the Translate panel; without one route to Settings. */
  protected onTranslate(): void {
    if (this.modelConfigured()) this.translate.emit();
    else this.openSettings.emit();
  }

  /** Cycle the six muted speaker palette tokens (sp-1..sp-6). */
  protected speakerColor(index: number): string {
    return `var(--sp-${(index % 6) + 1})`;
  }
}
