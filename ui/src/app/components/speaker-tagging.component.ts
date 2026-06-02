// SpeakerTaggingModal — the design-faithful, persistent path for naming a
// speaker in the most-recently-saved meeting (SpeakerTagging.jsx → the
// `22-st-tagging-modal` artboard). Opened from the left Attendees column: a
// "Who is this?" button on an unlabeled `Speaker N`, OR a click on an
// already-named row to re-tag it.
//
// ── Scope (honest about what's wired) ────────────────────────────────
// This modal does exactly one real thing: assign/edit a display name and
// send it via EngineService.renameSpeakers(sessionId, { [label]: newName }).
// That maps the speaker's CURRENT engine label (the rename key) to the
// chosen name; the engine rewrites the vault file for `session_id` and acks
// (failures land on the shared error channel, rendered by AppComponent).
//
// ── Enrollment is opt-in now (ADR-0026 + ADR-0027) ───────────────────
// Naming a speaker stores a LOCAL voiceprint keyed to that name (the offline
// diarizer's per-speaker centroid, under vault/.speakers/) so FUTURE meetings
// auto-recognize the same voice — but ONLY when the user has enabled "Remember
// speakers" in Settings → Privacy (default OFF, ADR-0027). The engine gates
// every `.speakers/` read/write on that flag, sent in capture.start.
//
// So the informational copy is now CONDITIONAL on the actual setting (read
// from PreferencesService.rememberSpeakers), never a stale "coming soon":
//   - ON  → naming remembers this voice locally; future meetings recognize
//           them (leading with the privacy guarantee — voiceprints never
//           leave the Mac, CLAUDE.md #5).
//   - OFF → naming applies to THIS meeting only; we point the user at
//           Settings → Privacy to enable remembering.
// No extra toggle/control/wire frame lives here — enrollment is a side effect
// of the SAME `speaker.rename` we already send, gated engine-side.
//
// When this modal is opened on a speaker the engine ALREADY auto-recognized
// from a prior meeting (matched_name + a non-null confidence, threaded in via
// the `recognized` input), we surface a subtle "Recognized from a past
// meeting" affordance so the user understands the name was filled in by the
// voiceprint match, not typed by them. The artboard's audio-snippet preview
// and sub-threshold "might be…" suggestion list remain out of scope (no
// snippet/suggestion wire frames yet) — those stay deferred, not faked.
//
// The artboard's "Save & remember voice" wording is folded into the single
// "Save name" button + the informational copy: every save remembers the
// voice, so a second button would be redundant.
//
// ── Modal chrome ─────────────────────────────────────────────────────
// Matches the SettingsPanel atom: a fixed backdrop scrim (z-50) + a centered
// card. role="dialog" + aria-modal, aria-label naming the speaker. The name
// input autofocuses; Enter saves (when valid); Esc / backdrop / Cancel / ×
// all close. A minimal focus trap keeps Tab within the card (only the input,
// Cancel, Save, and × are focusable, so the trap is small but real).
//
// Token-only, light-theme-ready (no hardcoded hex). The speaker chip color is
// passed in as a token var so it matches the same speaker's color in the
// Attendees roster / transcript / meeting-saved card.

import {
  ChangeDetectionStrategy,
  Component,
  ElementRef,
  HostListener,
  computed,
  effect,
  inject,
  input,
  output,
  signal,
  viewChild,
} from '@angular/core';
import { EngineService } from '../services/engine.service';
import { PreferencesService } from '../services/preferences.service';
import { EyebrowComponent } from './eyebrow.component';

/** Payload emitted on a successful save, so the host can dismiss + (if it
 *  wants) react. The optimistic roster update itself lives in the service
 *  (EngineService.renameSpeakers), so the host doesn't have to. */
export interface SpeakerTagSaved {
  /** The engine-known CURRENT label that was renamed (the rename map key). */
  readonly label: string;
  /** The trimmed name the user assigned. */
  readonly name: string;
}

@Component({
  selector: 'hark-speaker-tagging',
  standalone: true,
  changeDetection: ChangeDetectionStrategy.OnPush,
  imports: [EyebrowComponent],
  styles: [
    `
      :host {
        display: block;
      }

      /* Backdrop scrim — same dim+blur treatment the design's modal uses
         over the paused transcript. */
      .backdrop {
        position: fixed;
        inset: 0;
        z-index: 50;
        display: flex;
        align-items: center;
        justify-content: center;
        padding: var(--s-6);
        background: color-mix(in oklab, var(--bg) 55%, transparent);
        backdrop-filter: blur(4px);
      }

      .card {
        width: 100%;
        max-width: 560px;
        max-height: 84vh;
        overflow-y: auto;
        background: var(--surface);
        border: 1px solid var(--border-2);
        border-radius: var(--r-card);
        box-shadow: var(--shadow-modal);
        color: var(--text);
      }

      /* Header — chip + "Who is <Speaker>?" + meta + close. */
      .header {
        display: flex;
        align-items: center;
        gap: var(--s-3);
        padding: var(--s-4) var(--s-4) var(--s-3);
        border-bottom: 1px solid var(--border);
      }
      .chip {
        width: 14px;
        height: 14px;
        border-radius: 50%;
        flex-shrink: 0;
        background: var(--chip-color, var(--text-3));
      }
      .head-text {
        flex: 1;
        min-width: 0;
      }
      .title {
        font-family: var(--font-display);
        font-size: 15px;
        font-weight: 600;
        letter-spacing: -0.01em;
        color: var(--text);
      }
      .title .who {
        color: var(--chip-color, var(--accent));
      }
      .subtitle {
        margin-top: 2px;
        font-size: 12px;
        color: var(--text-2);
      }
      .close {
        flex-shrink: 0;
        display: inline-flex;
        align-items: center;
        justify-content: center;
        width: 28px;
        height: 28px;
        border: none;
        background: transparent;
        color: var(--text-3);
        border-radius: var(--r-input);
        cursor: pointer;
      }
      .close:hover {
        color: var(--text);
        background: var(--highlight);
      }

      .body {
        padding: var(--s-4);
        display: flex;
        flex-direction: column;
        gap: var(--s-4);
      }

      /* Name input section. */
      .field {
        display: flex;
        flex-direction: column;
        gap: var(--s-2);
      }
      .input-wrap {
        position: relative;
      }
      .name-input {
        width: 100%;
        font-family: var(--font-ui);
        font-size: 14px;
        color: var(--text);
        padding: 10px 12px;
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
      .clear {
        position: absolute;
        right: 6px;
        top: 50%;
        transform: translateY(-50%);
        width: 22px;
        height: 22px;
        border-radius: 50%;
        border: none;
        background: transparent;
        color: var(--text-3);
        cursor: pointer;
        display: inline-flex;
        align-items: center;
        justify-content: center;
      }
      .clear:hover {
        color: var(--text);
        background: var(--highlight);
      }
      .hint {
        font-family: var(--font-mono);
        font-size: 10.5px;
        color: var(--text-3);
      }

      /* "Recognized from a past meeting" affordance — shown only when the
         engine auto-matched this voice (matched_name + confidence). Subtle,
         success-tinted: this name was filled in for you by the voiceprint. */
      .recognized {
        display: inline-flex;
        align-items: center;
        gap: 6px;
        align-self: flex-start;
        padding: 3px 8px;
        border-radius: 999px;
        background: color-mix(in oklab, var(--status-success) 14%, transparent);
        border: 1px solid color-mix(in oklab, var(--status-success) 35%, transparent);
        color: var(--status-success);
        font-family: var(--font-mono);
        font-size: 10px;
        letter-spacing: 0.02em;
      }
      .recognized svg {
        flex-shrink: 0;
      }

      /* Informational "how enrollment works" section — active, not disabled.
         Naming this speaker now remembers their voice locally; this explains
         that and leads with the on-this-Mac privacy guarantee. */
      .note {
        display: flex;
        align-items: flex-start;
        gap: var(--s-2);
        padding: 10px 12px;
        border-radius: var(--r-panel);
        background: var(--bg-2);
        border: 1px solid var(--border);
      }
      .note svg {
        flex-shrink: 0;
        margin-top: 1px;
        color: var(--accent);
      }
      .note-text {
        font-size: 12px;
        color: var(--text-2);
        line-height: 1.5;
      }
      .note-text strong {
        color: var(--text);
        font-weight: 600;
      }
      .note-local {
        display: inline-flex;
        align-items: center;
        gap: 4px;
        margin-top: 6px;
        color: var(--text-3);
        font-family: var(--font-mono);
        font-size: 10px;
        letter-spacing: 0.02em;
      }

      /* Footer actions. */
      .footer {
        display: flex;
        align-items: center;
        gap: var(--s-2);
        padding: var(--s-3) var(--s-4);
        border-top: 1px solid var(--border);
        background: var(--bg-2);
      }
      .kbd {
        font-family: var(--font-mono);
        font-size: 11px;
        color: var(--text-3);
      }
      .spacer {
        flex: 1;
      }
      .btn {
        font-family: var(--font-ui);
        font-size: 13px;
        font-weight: 500;
        padding: 6px 12px;
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
    <div class="backdrop" (click)="onBackdrop()">
      <div
        #card
        class="card"
        role="dialog"
        aria-modal="true"
        [attr.aria-label]="'Identify ' + label()"
        [style.--chip-color]="chipColor()"
        (click)="$event.stopPropagation()"
      >
        <!-- Header -->
        <div class="header">
          <span class="chip" aria-hidden="true"></span>
          <div class="head-text">
            <div class="title">
              @if (isRetag()) {
                Rename <span class="who">{{ displayName() }}</span>
              } @else {
                Who is <span class="who">{{ label() }}</span>?
              }
            </div>
            <div class="subtitle">{{ subtitle() }}</div>
          </div>
          <button
            type="button"
            class="close"
            (click)="onClose()"
            title="Close (Esc)"
            aria-label="Close"
          >
            <svg viewBox="0 0 24 24" width="14" height="14" fill="none"
              stroke="currentColor" stroke-width="2" stroke-linecap="round"
              aria-hidden="true">
              <path d="M6 6l12 12M18 6L6 18" />
            </svg>
          </button>
        </div>

        <!-- Body -->
        <div class="body">
          <!-- Name input -->
          <div class="field">
            <hark-eyebrow>Name</hark-eyebrow>
            <div class="input-wrap">
              <input
                #nameInput
                class="name-input"
                type="text"
                [value]="name()"
                placeholder="Type a name…"
                [attr.aria-label]="'Name for ' + label()"
                (input)="onInput($any($event.target).value)"
                (keydown.enter)="save()"
              />
              @if (name().length > 0) {
                <button
                  type="button"
                  class="clear"
                  (click)="clear()"
                  title="Clear"
                  aria-label="Clear name"
                >
                  <svg viewBox="0 0 24 24" width="10" height="10" fill="none"
                    stroke="currentColor" stroke-width="2.2" stroke-linecap="round"
                    aria-hidden="true">
                    <path d="M6 6l12 12M18 6L6 18" />
                  </svg>
                </button>
              }
            </div>
            <span class="hint">
              @if (rememberSpeakers()) {
                renames this speaker + remembers their voice · stays on this Mac
              } @else {
                renames this speaker in the saved transcript · stays on this Mac
              }
            </span>
          </div>

          <!-- Auto-recognized from a prior meeting: this name was filled in by
               the local voiceprint match, not typed. Shown only when the engine
               supplied a matched_name + confidence. -->
          @if (recognized(); as r) {
            <span
              class="recognized"
              [title]="'Matched a voiceprint from a past meeting (' + r + ' confidence)'"
            >
              <svg viewBox="0 0 24 24" width="11" height="11" fill="none"
                stroke="currentColor" stroke-width="2.2" stroke-linecap="round"
                stroke-linejoin="round" aria-hidden="true">
                <path d="M20 6 9 17l-5-5" />
              </svg>
              Recognized from a past meeting · {{ r }}
            </span>
          }

          <!-- How naming behaves — CONDITIONAL on "Remember speakers"
               (Settings → Privacy, ADR-0027). On: enrollment is real and
               local. Off: this rename is meeting-scoped, and we point at the
               setting. Honest either way; no "coming soon" placeholder. -->
          <div class="note">
            <svg viewBox="0 0 24 24" width="14" height="14" fill="none"
              stroke="currentColor" stroke-width="1.8" stroke-linecap="round"
              stroke-linejoin="round" aria-hidden="true">
              <path d="M12 2a4 4 0 0 0-4 4v5a4 4 0 0 0 8 0V6a4 4 0 0 0-4-4z" />
              <path d="M5 11a7 7 0 0 0 14 0M12 18v3" />
            </svg>
            @if (rememberSpeakers()) {
              <span class="note-text">
                Naming this speaker <strong>remembers their voice on this Mac</strong>,
                so Hark recognizes them automatically in future meetings.
                <span class="note-local">
                  <svg viewBox="0 0 24 24" width="11" height="11" fill="none"
                    stroke="currentColor" stroke-width="1.8" stroke-linecap="round"
                    stroke-linejoin="round" aria-hidden="true">
                    <rect x="5" y="11" width="14" height="9" rx="2" />
                    <path d="M8 11V8a4 4 0 0 1 8 0v3" />
                  </svg>
                  The voiceprint stays on this Mac — it never leaves your device.
                </span>
              </span>
            } @else {
              <span class="note-text">
                This name applies to <strong>this meeting only</strong>. Hark
                won't recognize this voice in future meetings.
                <span class="note-local">
                  <svg viewBox="0 0 24 24" width="11" height="11" fill="none"
                    stroke="currentColor" stroke-width="1.8" stroke-linecap="round"
                    stroke-linejoin="round" aria-hidden="true">
                    <path d="M12 2 4 6v6c0 5 3.5 8 8 10 4.5-2 8-5 8-10V6l-8-4z" />
                  </svg>
                  Enable “Remember speakers” in Settings → Privacy to recognize
                  people across meetings.
                </span>
              </span>
            }
          </div>
        </div>

        <!-- Footer -->
        <div class="footer">
          <span class="kbd">⏎ save · esc cancel</span>
          <span class="spacer"></span>
          <button type="button" class="btn" (click)="onClose()">Cancel</button>
          <button
            type="button"
            class="btn btn-primary"
            [disabled]="!canSave()"
            (click)="save()"
            title="Rename this speaker in the saved transcript"
          >
            Save name
          </button>
        </div>
      </div>
    </div>
  `,
})
export class SpeakerTaggingComponent {
  private readonly engine = inject(EngineService);
  private readonly prefs = inject(PreferencesService);

  /** Whether "Remember speakers" is enabled (Settings → Privacy, ADR-0027).
   *  Drives the informational copy: enrollment only happens when this is on. */
  protected readonly rememberSpeakers = this.prefs.rememberSpeakers;

  /** The speaker's CURRENT engine label — the rename map KEY. */
  readonly label = input.required<string>();
  /** Current display name (matched_name ?? label). Seeds the input and tells
   *  us whether this is a first tag or a re-tag. */
  readonly displayName = input.required<string>();
  /** The most-recently-saved meeting's session id (the rename target). */
  readonly sessionId = input.required<string>();
  /** A token var like `var(--sp-4)` so the chip matches the roster color. */
  readonly chipColor = input<string>('var(--text-3)');
  /** The engine's voiceprint-match confidence (0..1) when THIS speaker was
   *  auto-recognized from a prior meeting, or `null` when the name was typed
   *  this session / the speaker is still unlabeled. Drives the subtle
   *  "Recognized from a past meeting" affordance. Mirrors
   *  MeetingSpeaker.confidence (ADR-0026). */
  readonly confidence = input<number | null>(null);

  /** Esc / backdrop / Cancel / × — host unmounts the modal. */
  readonly close = output<void>();
  /** Emitted after a successful save (the service already applied the
   *  optimistic roster update; this lets the host dismiss + react). */
  readonly saved = output<SpeakerTagSaved>();

  private readonly nameInput =
    viewChild<ElementRef<HTMLInputElement>>('nameInput');
  private readonly cardEl = viewChild<ElementRef<HTMLElement>>('card');

  /** The live editable name. Seeded from displayName when it differs from the
   *  bare label — i.e. a re-tag prefills the existing name; a first tag starts
   *  empty so the placeholder shows (we don't prefill "Speaker 4" as a name). */
  protected readonly name = signal<string>('');

  /** True when the speaker already has a real name (re-tag), vs an unlabeled
   *  `Speaker N` (first tag). Changes the title + subtitle copy. */
  protected readonly isRetag = computed(
    () => this.displayName() !== this.label(),
  );

  protected readonly subtitle = computed(() =>
    this.isRetag()
      ? 'Update this speaker’s name across the saved transcript'
      : 'Clustered by voice only · give this speaker a name',
  );

  /** Formatted confidence label for the "Recognized from a past meeting"
   *  affordance, or null when this speaker wasn't auto-matched (no
   *  confidence). Derived from the `confidence` input (0..1 → "NN%"). The
   *  template renders it as `@if (recognized(); as r)`. */
  protected readonly recognized = computed<string | null>(() => {
    const c = this.confidence();
    if (c === null || !Number.isFinite(c)) return null;
    return `${Math.round(Math.max(0, Math.min(1, c)) * 100)}%`;
  });

  /** Save is allowed when the trimmed name is non-empty and actually differs
   *  from the current label (so we never send a no-op rename). */
  protected readonly canSave = computed(() => {
    const typed = this.name().trim();
    return typed.length > 0 && typed !== this.label();
  });

  /** Seed (and re-seed if the modal is re-targeted at a different speaker
   *  without unmounting) the input from the current display name. */
  private readonly _seed = effect(() => {
    const display = this.displayName();
    const label = this.label();
    this.name.set(display !== label ? display : '');
    // Autofocus the input on (re)seed. The viewChild may not exist on the
    // very first synchronous effect run; queueMicrotask defers to after the
    // template has rendered the input.
    queueMicrotask(() => {
      const el = this.nameInput()?.nativeElement;
      if (el) {
        el.focus();
        el.select();
      }
    });
  });

  protected onInput(value: string): void {
    this.name.set(value);
  }

  protected clear(): void {
    this.name.set('');
    this.nameInput()?.nativeElement.focus();
  }

  /** Send the rename for the changed row, then notify the host. The service
   *  no-ops an empty/unchanged map; canSave already gates that, but we trim
   *  again defensively. */
  protected save(): void {
    if (!this.canSave()) return;
    const typed = this.name().trim();
    const label = this.label();
    this.engine.renameSpeakers(this.sessionId(), { [label]: typed });
    this.saved.emit({ label, name: typed });
  }

  protected onBackdrop(): void {
    this.close.emit();
  }

  protected onClose(): void {
    this.close.emit();
  }

  @HostListener('document:keydown.escape')
  protected onEscape(): void {
    this.close.emit();
  }

  /** Minimal focus trap: keep Tab/Shift+Tab cycling within the card's
   *  focusable controls so focus can't escape to the dimmed page behind.
   *  Bound to the generic keydown (strict templates type `$event` as `Event`),
   *  so we narrow to KeyboardEvent + filter to Tab ourselves. */
  @HostListener('document:keydown', ['$event'])
  protected onKeydown(ev: Event): void {
    if (!(ev instanceof KeyboardEvent) || ev.key !== 'Tab') return;
    const card = this.cardEl()?.nativeElement;
    if (!card) return;
    const focusable = card.querySelectorAll<HTMLElement>(
      'button, input, [tabindex]:not([tabindex="-1"])',
    );
    if (focusable.length === 0) return;
    const first = focusable[0];
    const last = focusable[focusable.length - 1];
    const active = document.activeElement;
    if (ev.shiftKey) {
      if (active === first || !card.contains(active)) {
        ev.preventDefault();
        last.focus();
      }
    } else {
      if (active === last || !card.contains(active)) {
        ev.preventDefault();
        first.focus();
      }
    }
  }
}
