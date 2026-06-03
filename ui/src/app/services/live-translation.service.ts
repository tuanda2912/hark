// LiveTranslationService — live translation of finalized captions to an
// ARBITRARY (non-English) target (ADR-0035, translation §3).
//
// The on-device path (§2, the `→ EN` toggle) only produces English — Whisper's
// `task: .translate` is English-only. For any OTHER target there is no on-device
// model shipped (we deferred NLLB), so we reuse the configured LLM: as each
// FINALIZED caption segment lands, we send ITS text to main's per-segment
// translate (LlmService.translateSegment) and write the result back under the
// original line (bilingual live view).
//
// Layering: this is the ORCHESTRATOR. It owns no network and no socket — it
// listens to EngineService's `segmentFinalized$` (the local read model), calls
// the LLM facade (main is the egress chokepoint, ADR-0029/0031), and writes the
// translation back into EngineService via `setSegmentTranslation`. Java/Spring
// analogue: a small `@Service` that bridges two other services with a bit of
// per-meeting state (the dedupe set).
//
// PRIVACY (ADR-0031, ADR-0035): every byte leaves the machine ONLY through
// main's translateSegment — CLOUD redacts each line first + the egress is logged
// (aggregated); a LOCAL (loopback) model sends as-is, ZERO egress. That's why a
// local model is the recommended setup for live translation, surfaced via
// `usesCloud`. We never persist these live translations — the saved transcript
// stays the original; a translated copy is §1's job (end-of-meeting).

import { Injectable, computed, effect, inject, signal } from '@angular/core';
import { EngineService } from './engine.service';
import { LlmService } from './llm.service';
import type { CaptureState, DisplayedSegment } from './engine.types';

/** A live-translation target. `name` is the canonical English language name we
 *  send the model; `label` is the friendly native-script picker string; `code`
 *  is the ISO-639-1 code used ONLY to skip a line already in the target language
 *  (the model would just echo it). English is deliberately absent — the
 *  on-device `→ EN` toggle (§2) covers English for free, with zero egress. */
export interface LiveTranslateTarget {
  readonly label: string;
  readonly name: string;
  readonly code: string;
}

/** Offered live targets (non-English — English is the §2 on-device path). */
export const LIVE_TRANSLATE_TARGETS: readonly LiveTranslateTarget[] = [
  { label: 'Vietnamese (Tiếng Việt)', name: 'Vietnamese', code: 'vi' },
  { label: 'Thai (ไทย)', name: 'Thai', code: 'th' },
  { label: 'Chinese (中文)', name: 'Chinese', code: 'zh' },
  { label: 'Japanese (日本語)', name: 'Japanese', code: 'ja' },
  { label: 'Korean (한국어)', name: 'Korean', code: 'ko' },
  { label: 'Spanish', name: 'Spanish', code: 'es' },
  { label: 'French', name: 'French', code: 'fr' },
  { label: 'German', name: 'German', code: 'de' },
];

@Injectable({ providedIn: 'root' })
export class LiveTranslationService {
  private readonly engine = inject(EngineService);
  private readonly llm = inject(LlmService);

  // ─── State ──────────────────────────────────────────────────────────

  /** The chosen target language NAME (e.g. "Vietnamese"), or null = OFF. */
  private readonly _targetLang = signal<string | null>(null);
  readonly targetLang = this._targetLang.asReadonly();

  /** True when a live target is selected (live arbitrary-target translation on). */
  readonly enabled = computed(() => this._targetLang() !== null);

  /** Count of per-segment translations currently in flight — drives a subtle
   *  "translating…" indicator. */
  private readonly _inFlight = signal(0);
  readonly inFlight = this._inFlight.asReadonly();

  /** The egress kind of the most recent successful line ('cloud' | 'local'), or
   *  null before the first. Honest UI: confirms what actually happened. */
  private readonly _lastEgress = signal<'cloud' | 'local' | null>(null);
  readonly lastEgress = this._lastEgress.asReadonly();

  /** The most recent per-segment failure detail, or null. Surfaced quietly —
   *  a single line failing to translate must not break the live view. */
  private readonly _lastError = signal<string | null>(null);
  readonly lastError = this._lastError.asReadonly();

  /**
   * Whether the configured model would send each line to the CLOUD (vs a LOCAL
   * loopback model = zero egress). Mirrors main's `isLocalEgress` so the picker
   * can warn honestly BEFORE the first line is sent. Anthropic (no baseUrl) and
   * any non-loopback baseUrl ⇒ cloud; a loopback OpenAI-compatible baseUrl ⇒
   * local. Null config ⇒ treat as cloud (the safe assumption). */
  readonly usesCloud = computed(() => !this.isLocalModel());

  private readonly isLocalModel = computed(() => {
    const cfg = this.llm.config();
    if (!cfg || cfg.provider !== 'openai-compatible') return false;
    const base = cfg.baseUrl;
    if (typeof base !== 'string' || base.length === 0) return false;
    try {
      const h = new URL(base).hostname.replace(/^\[|\]$/g, '').toLowerCase();
      return h === 'localhost' || h === '127.0.0.1' || h === '::1';
    } catch {
      return false;
    }
  });

  /** The ISO-639-1 code of the current target, or null (off / unknown). */
  private readonly targetCode = computed(() => {
    const name = this._targetLang();
    if (!name) return null;
    return LIVE_TRANSLATE_TARGETS.find((t) => t.name === name)?.code ?? null;
  });

  /** Utterance ids already handled this meeting — so a line is translated at
   *  most once even if it finalizes again (bounds the LLM call count). Cleared
   *  at the start of each capture. */
  private readonly translatedIds = new Set<string>();

  /** Previous capture kind, to detect transitions in the effect below. */
  private prevCaptureKind: CaptureState['kind'] = 'idle';

  constructor() {
    // Translate each finalized live line (never partials — the engine only
    // emits this on `segment.final`). Fire-and-forget per line.
    this.engine.segmentFinalized$.subscribe((seg) => this.onFinalized(seg));

    // React to capture lifecycle: clear the dedupe set on a fresh start, and
    // commit main's aggregated cloud-log roll-up when capture ends.
    effect(() => {
      const kind = this.engine.capture().kind;
      const prev = this.prevCaptureKind;
      this.prevCaptureKind = kind;
      if (kind === 'starting' && prev !== 'starting') {
        this.translatedIds.clear();
        this._lastError.set(null);
      }
      // Capture ended (running/stopping → idle): commit the metadata-only
      // roll-up of any lines sent to the cloud this meeting.
      if (kind === 'idle' && (prev === 'running' || prev === 'stopping')) {
        this.llm.flushLiveTranslate();
      }
    });
  }

  // ─── Control ────────────────────────────────────────────────────────

  /**
   * Set (or clear, with null) the live translation target. Turning it OFF
   * commits main's pending roll-up immediately so the audit entry lands without
   * waiting for capture to stop. Idempotent for an unchanged value.
   */
  setTargetLang(name: string | null): void {
    const next = name && name.trim().length > 0 ? name.trim() : null;
    if (next === this._targetLang()) return;
    this._targetLang.set(next);
    if (next === null) {
      this._inFlight.set(0);
      this.llm.flushLiveTranslate();
    }
  }

  /** Turn live arbitrary-target translation OFF. */
  disable(): void {
    this.setTargetLang(null);
  }

  // ─── Orchestration ──────────────────────────────────────────────────

  private onFinalized(seg: DisplayedSegment): void {
    const target = this._targetLang();
    if (!target) return; // off
    const text = (seg.text ?? '').trim();
    if (text.length === 0) return;
    if (this.translatedIds.has(seg.utteranceId)) return;
    this.translatedIds.add(seg.utteranceId);

    // Skip a line already in the target language — the model would just echo it
    // back, wasting a call (and an egress) and cluttering the line with a
    // duplicate. (language is a per-window detection and may be null; only skip
    // on a confident match.)
    const code = this.targetCode();
    if (code && seg.language && seg.language.toLowerCase() === code) return;

    this._inFlight.update((n) => n + 1);
    void this.translateOne(seg.utteranceId, text, target);
  }

  private async translateOne(
    utteranceId: string,
    text: string,
    targetLang: string,
  ): Promise<void> {
    try {
      // No knownNames: live segments are speaker-unlabeled (diarization is
      // post-stop), so there are no applied display-names to collapse yet.
      // Main's redactor still runs its pattern detectors on a cloud send.
      const res = await this.llm.translateSegment({ text, targetLang });
      if (res.ok) {
        const t = res.translation.trim();
        if (t.length > 0) this.engine.setSegmentTranslation(utteranceId, t);
        this._lastEgress.set(res.egress);
      } else {
        this._lastError.set(res.detail);
      }
    } finally {
      this._inFlight.update((n) => Math.max(0, n - 1));
    }
  }
}
