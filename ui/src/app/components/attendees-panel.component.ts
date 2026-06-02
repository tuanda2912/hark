// AttendeesPanel — the LEFT column of the 3-column MainWindow.
//
// Renders the meeting's speaker roster (the design's "Attendees" sidebar,
// `artboards/MainWindow.jsx`). Each row is a colored chip + the speaker's
// name (matched_name ?? label) + a small meta line; unlabeled "Speaker N"
// rows get a dashed warning-tinted treatment and a "Who is this?" button.
//
// ── Data source ──────────────────────────────────────────────────────
// The roster comes from EngineService.lastMeetingSaved() — the retained
// last `meeting.saved` payload (its `speakers: MeetingSpeaker[]`). That is
// POST-STOP data: diarization runs offline at capture.stop (ADR-0017), so a
// roster only exists AFTER a meeting is saved, and is cleared on
// clearTranscript() ("New meeting").
//
// ── Why no live attendees ────────────────────────────────────────────
// There is intentionally NO live speaker list during recording. Live
// diarization (streaming speaker turns mid-meeting) is a separate engine
// effort, tracked in docs/BACKLOG.md ("3-column layout" + "Speaker /
// diarization"). Faking live attendees here would be dishonest, so during
// capture we show an explicit info state instead.
//
// ── "Who is this?" + re-tag ──────────────────────────────────────────
// Two paths open the speaker-tagging modal (SpeakerTagging.jsx, the
// `22-st-tagging-modal` artboard), both via the `tagSpeaker` output:
//   - the "Who is this?" button on an unlabeled `Speaker N` row, and
//   - a click on an already-named row (to re-tag / correct it).
// The output carries the speaker's CURRENT engine label (the rename key), its
// display name (to prefill / title the modal), and its palette index (so the
// modal chip matches this row's color). The host (AppComponent) owns the
// modal + the session id; inline renaming in the meeting-saved card
// (ADR-0020) coexists, both backed by EngineService.renameSpeakers.

import {
  ChangeDetectionStrategy,
  Component,
  computed,
  inject,
  input,
  output,
} from '@angular/core';
import { EngineService } from '../services/engine.service';
import { MeetingSpeaker } from '../services/engine.types';
import { EyebrowComponent } from './eyebrow.component';

/** A roster row enriched with its display name, palette index, and whether
 *  the engine matched it to a known person (Phase 5.1; null today). */
interface AttendeeRow {
  readonly label: string;
  readonly name: string;
  readonly tagged: boolean;
  readonly meta: string;
  readonly i: number;
}

/** Payload emitted when the user wants to tag/re-tag a speaker. Carries
 *  everything the host needs to open the modal without re-reading the roster:
 *  the engine label (rename KEY), the display name (prefill/title), and the
 *  palette index (chip color). */
export interface TagSpeakerRequest {
  readonly label: string;
  readonly displayName: string;
  readonly index: number;
}

@Component({
  selector: 'hark-attendees-panel',
  standalone: true,
  changeDetection: ChangeDetectionStrategy.OnPush,
  imports: [EyebrowComponent],
  styles: [
    `
      :host {
        display: flex;
        flex-direction: column;
        min-height: 0;
        height: 100%;
        border-right: 1px solid var(--border);
        background: var(--bg-2);
      }

      .head {
        display: flex;
        align-items: center;
        justify-content: space-between;
        padding: 14px 16px 8px;
      }

      .list {
        display: flex;
        flex-direction: column;
        gap: 2px;
        padding: 0 8px;
      }

      .row {
        display: flex;
        align-items: flex-start;
        /* Chip→body gap kept tight (8px) so the name/meta body keeps as much
         * of the ~176px-min column as possible. */
        gap: 8px;
        padding: 10px 8px;
        border-radius: var(--r-panel);
        border: 1px solid transparent;
      }
      .row.untagged {
        background: color-mix(in oklab, var(--status-warning) 8%, transparent);
        border: 1px dashed color-mix(in oklab, var(--status-warning) 35%, transparent);
      }
      /* A named row is a button (click to re-tag): strip native chrome, left-
       * align, full-width, show it's interactive on hover. */
      .row-btn {
        width: 100%;
        text-align: left;
        font: inherit;
        color: inherit;
        background: transparent;
        cursor: pointer;
      }
      .row-btn:hover {
        background: var(--highlight);
        border-color: var(--border-2);
      }
      .row-btn:focus-visible {
        outline: none;
        border-color: var(--accent);
        box-shadow: 0 0 0 3px var(--accent-soft);
      }

      .chip {
        width: 10px;
        height: 10px;
        border-radius: 50%;
        flex-shrink: 0;
        margin-top: 5px;
        background: var(--chip-color, var(--text-3));
      }

      .body {
        flex: 1;
        min-width: 0;
      }
      .name {
        font-size: 13px;
        font-weight: 500;
        color: var(--text);
        /* At the column's clamped minimum (~176px) the body track is narrow;
         * a long matched name must ellipsize rather than clip mid-glyph
         * against the column's overflow:hidden. .body already has min-width:0
         * so this can actually take effect. */
        overflow: hidden;
        text-overflow: ellipsis;
        white-space: nowrap;
      }
      .name.untagged {
        color: var(--text-2);
        font-style: italic;
      }
      .meta {
        margin-top: 2px;
        font-size: 11px;
        color: var(--text-3);
      }

      .who {
        margin-top: 6px;
        font-family: var(--font-ui);
        font-size: 11px;
        padding: 3px 8px;
        border-radius: var(--r-input);
        border: 1px solid var(--border-2);
        background: transparent;
        color: var(--text);
        cursor: pointer;
      }
      .who:hover {
        background: var(--highlight);
      }

      /* Honest empty / info state (no roster yet). */
      .empty {
        padding: 16px;
        margin: 4px 8px;
        border-radius: var(--r-panel);
        border: 1px dashed var(--border-2);
        background: var(--surface);
        color: var(--text-2);
        font-size: 12px;
        line-height: 1.5;
      }
      .empty .empty-title {
        display: flex;
        align-items: center;
        gap: 6px;
        margin-bottom: 6px;
        color: var(--text);
        font-weight: 500;
      }
      .empty .dot {
        width: 8px;
        height: 8px;
        border-radius: 50%;
        flex-shrink: 0;
      }
      .empty .dot.live {
        background: var(--status-recording);
      }
      .empty .dot.idle {
        background: var(--text-3);
      }

      .spacer {
        flex: 1;
      }

      .foot {
        padding: 10px 14px;
        border-top: 1px solid var(--border);
        font-family: var(--font-mono);
        font-size: 10.5px;
        color: var(--text-3);
        display: flex;
        justify-content: space-between;
        gap: 8px;
      }
    `,
  ],
  template: `
    <div class="head">
      <hark-eyebrow>{{ headerLabel() }}</hark-eyebrow>
    </div>

    @if (rows().length > 0) {
      <div class="list" role="list">
        @for (row of rows(); track row.label) {
          <!-- A named row is itself a button (re-tag); an unlabeled row keeps
               its inline "Who is this?" button so the affordance is explicit
               and the dashed warning treatment stays. -->
          @if (row.tagged) {
            <button
              type="button"
              class="row row-btn"
              role="listitem"
              (click)="emitTag(row)"
              [title]="'Rename ' + row.name"
            >
              <span
                class="chip"
                [style.--chip-color]="speakerColor(row.i)"
                aria-hidden="true"
              ></span>
              <div class="body">
                <div class="name">{{ row.name }}</div>
                <div class="meta">{{ row.meta }}</div>
              </div>
            </button>
          } @else {
            <div class="row untagged" role="listitem">
              <span
                class="chip"
                [style.--chip-color]="speakerColor(row.i)"
                aria-hidden="true"
              ></span>
              <div class="body">
                <div class="name untagged">{{ row.name }}</div>
                <div class="meta">{{ row.meta }}</div>
                <button
                  type="button"
                  class="who"
                  (click)="emitTag(row)"
                  [title]="'Identify ' + row.label"
                >
                  Who is this?
                </button>
              </div>
            </div>
          }
        }
      </div>
    } @else {
      <!-- No roster: distinguish live capture (diarization pending) from idle. -->
      <div class="empty">
        @if (capturing()) {
          <div class="empty-title">
            <span class="dot live" aria-hidden="true"></span>
            Listening…
          </div>
          Speakers are identified when the meeting is saved — diarization runs
          offline after you press Stop.
        } @else {
          <div class="empty-title">
            <span class="dot idle" aria-hidden="true"></span>
            No attendees yet
          </div>
          Speakers appear here once a meeting is recorded and saved.
        }
      </div>
    }

    <div class="spacer"></div>

    <!-- Diarization provenance, matching the design's footer. Honest about
         the offline (post-stop) pipeline rather than a live "● 0.94" score. -->
    <div class="foot">
      <span>diarization · FluidAudio</span>
      <span>{{ rows().length > 0 ? 'offline · saved' : 'offline' }}</span>
    </div>
  `,
})
export class AttendeesPanelComponent {
  private readonly engine = inject(EngineService);

  /** True while a capture is running — selects the "listening" info state. */
  readonly capturing = input<boolean>(false);

  /** User asked to tag/re-tag a speaker — via the "Who is this?" button on an
   *  unlabeled row, or a click on an already-named row. The host opens the
   *  speaker-tagging modal with this payload. */
  readonly tagSpeaker = output<TagSpeakerRequest>();

  /** The retained last `meeting.saved` roster. Null until a meeting is saved
   *  (and after "New meeting" clears it). */
  private readonly lastMeeting = this.engine.lastMeetingSaved;

  protected readonly rows = computed<readonly AttendeeRow[]>(() => {
    const saved = this.lastMeeting();
    if (!saved) return [];
    return saved.speakers.map((sp, i) => this.toRow(sp, i));
  });

  protected readonly headerLabel = computed(() => {
    const n = this.rows().length;
    return n > 0 ? `Attendees · ${n}` : 'Attendees';
  });

  /** Build the tag request from a row and emit it. The host opens the modal;
   *  the rename KEY is the row's current `label`, the prefill is its display
   *  `name`, and `i` keeps the chip color stable across surfaces. */
  protected emitTag(row: AttendeeRow): void {
    this.tagSpeaker.emit({
      label: row.label,
      displayName: row.name,
      index: row.i,
    });
  }

  private toRow(sp: MeetingSpeaker, i: number): AttendeeRow {
    const tagged = sp.matched_name !== null;
    const name = sp.matched_name ?? sp.label;
    const meta = tagged
      ? confidenceMeta(sp.confidence)
      : 'Unlabeled — tap to identify';
    return { label: sp.label, name, tagged, meta, i };
  }

  /** Cycle the six muted speaker palette tokens (sp-1..sp-6) — the same
   *  cycling the transcript + meeting-saved card use, keyed by roster order
   *  so a speaker's color is stable across surfaces within a meeting. */
  protected speakerColor(index: number): string {
    return `var(--sp-${(index % 6) + 1})`;
  }
}

/** Meta line for a matched speaker — shows match confidence when present. */
function confidenceMeta(confidence: number | null): string {
  if (confidence === null) return 'Identified';
  return `Match · ${Math.round(confidence * 100)}%`;
}
