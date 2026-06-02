// TypeScript counterparts to the Swift wire types in
// engine/Sources/Harkd/WireProtocol.swift. Shape MUST match exactly
// — these are the JSON envelopes that flow over the WebSocket.
//
// Both partial and final segments use SegmentPayload. Partials carry
// only `utterance_id`; finals additionally carry a stable `segment_id`.
// utterance_id stability across partial→partial→final is guaranteed
// by harkd's UtteranceLedger (ADR-0009).

/** Outbound envelope shape: { v, ts, type, payload } */
export interface WireEnvelope<T = unknown> {
  readonly v: 1;
  readonly ts: string;
  readonly type: string;
  readonly id?: string;
  readonly payload: T;
}

// ─── Engine → UI payloads ────────────────────────────────────────────

export interface MetaHelloPayload {
  readonly engine_version: string;
  readonly protocol_version: number;
  readonly model_loaded: string;
  readonly capabilities: readonly string[];
}

export interface MetaHeartbeatPayload {
  readonly rtf_current: number;
  readonly ring_buffer_fill_sec: number;
}

/**
 * First-run model warm-up progress. Emitted repeatedly during a cold
 * start while harkd downloads + ANE-compiles the speech / diarizer
 * models — before `meta.ready`. The UI uses it to drive the
 * "Preparing Hark" overlay so a fresh install doesn't look hung.
 *
 * `fraction` is 0..1 for the downloadable phases; it is `null` for the
 * indeterminate ANE-compile / optimization phases (no byte count to
 * track) — the UI shows a spinner, NOT a fake percentage, when null.
 * `phase` is a stable machine token; `detail` is the human label to show.
 *
 * Mirrors the Swift `MetaModelProgressPayload` (snake_case on the wire
 * via `.convertToSnakeCase`). `fraction` is encoded as explicit JSON `null`
 * (not omitted) for indeterminate phases — keep both sides in lockstep.
 */
export interface MetaModelProgressPayload {
  /** "downloading_speech" | "optimizing_speech" | "downloading_diarizer" | "optimizing_diarizer" */
  readonly phase: string;
  /** 0..1 for determinate (download) phases; null when indeterminate (ANE compile). */
  readonly fraction: number | null;
  /** Human label, e.g. "Downloading speech model". */
  readonly detail: string;
}

/**
 * Sent once when the model finishes loading. harkd brings up the
 * WebSocket + port file before the model is ready, so an early client
 * sees `meta.hello.model_loaded === "(loading)"` and then this frame
 * when the model is ready. A client connecting after the model is loaded
 * gets the real model name in `meta.hello` and no `meta.ready`.
 */
export interface MetaReadyPayload {
  readonly model_loaded: string;
}

export interface CaptureStartedPayload {
  readonly session_id: string;
  readonly sample_rate_hz: number;
  readonly channels: number;
  readonly model: string;
  readonly vad: string;
  readonly started_at: string;
}

export interface CaptureStoppedPayload {
  readonly session_id: string;
  readonly duration_sec: number;
}

export interface SegmentPayload {
  readonly utterance_id: string;
  /** Present only on `segment.final`. */
  readonly segment_id: string | null;
  readonly t_start: number;
  readonly t_end: number;
  readonly text: string;
  readonly language: string | null;
  readonly speaker: string | null;
  readonly translation: string | null;
}

/**
 * Engine → UI retraction signal. Emitted once when an utterance has been
 * superseded by a later, overlapping, more-complete re-segmentation
 * (ADR-0009 mints a fresh utterance_id on re-segmentation; this frame
 * retracts the older fragment). Consumer semantics: drop `utterance_id`
 * from the displayed/retained set — it has been replaced by `superseded_by`.
 */
export interface SegmentSupersededPayload {
  readonly utterance_id: string;
  readonly superseded_by: string;
}

export interface WarningPayload {
  readonly code: string;
  readonly message: string;
  readonly severity: string;
}

export interface BookmarkCreatedPayload {
  readonly bookmark_id: string;
  /** Moment in the recording, seconds since capture start. */
  readonly t: number;
  readonly label: string;
}

export interface ErrorPayload {
  readonly code: string;
  readonly message: string;
  readonly recoverable: boolean;
  readonly action: string | null;
}

/** One row of the speaker roster in `meeting.saved`. */
export interface MeetingSpeaker {
  readonly label: string;
  /**
   * Phase 5 v1 is anonymous, so this is always `null`. Phase 5.1
   * (enrollment / naming) populates it from a matched voice profile.
   */
  readonly matched_name: string | null;
  /** Match confidence 0..1, or `null` when unmatched (Phase 5 v1). */
  readonly confidence: number | null;
}

export interface MeetingStats {
  readonly segments: number;
  readonly duration_sec: number;
  readonly rtf_avg: number;
}

/**
 * Emitted once after `capture.stop`, when diarization has run and the
 * transcript has been written to the vault. The UI uses `vault_path` for a
 * "reveal in Finder" affordance and renders the speaker roster + stats as a
 * saved-confirmation.
 */
export interface MeetingSavedPayload {
  readonly session_id: string;
  readonly vault_path: string;
  /**
   * Absolute path to the persisted meeting audio (`vault/.audio/<id>.wav`,
   * 16 kHz mono), or `null` when *Keep audio* was off (the default) or the
   * write didn't happen. Privacy-gated by `keep_audio` (ADR-0027); audio is
   * persisted only on explicit opt-in (ADR-0028). The Post-Meeting Review
   * screen uses this to load the audio for verify-by-ear speaker tagging.
   * Mirrors the Swift `MeetingSavedPayload.audioPath` — always present on the
   * wire (explicit JSON `null`, never a dropped key), analogous to `vault_path`.
   */
  readonly audio_path: string | null;
  readonly speakers: readonly MeetingSpeaker[];
  readonly stats: MeetingStats;
}

/** One labeled utterance in `meeting.transcript` — the deduped, "Speaker N"-
 *  labeled line as written to the vault. `id` is a stable per-utterance key for
 *  the UI's `@for` track (e.g. "u0", "u1"…). Mirrors the Swift
 *  `TranscriptUtterance`; all fields non-optional. `tStart` ↔ `t_start`. */
export interface MeetingTranscriptUtterance {
  readonly id: string;
  readonly t_start: number;
  readonly text: string;
  /** "Speaker N" — the SAME label as the saved file / `meeting.saved` roster. */
  readonly speaker: string;
}

/**
 * Emitted once per meeting at `capture.stop`, JUST BEFORE `meeting.saved`.
 * Carries the deduped, diarization-labeled final transcript exactly as written
 * to the vault markdown body. Live `segment.final` frames ship `speaker: null`
 * (diarization is a post-stop batch pass), so the UI swaps its messy live
 * partials/dupes for these clean labeled utterances on arrival, giving every
 * on-screen line its speaker. `session_id` matches `meeting.saved` /
 * `speaker.rename`, scoping the replacement to the right meeting. Mirrors the
 * Swift `MeetingTranscriptPayload` (snake_case on the wire).
 */
export interface MeetingTranscriptPayload {
  readonly session_id: string;
  readonly utterances: readonly MeetingTranscriptUtterance[];
}

// ─── UI → Engine command shapes ──────────────────────────────────────

export interface CaptureStartCommand {
  readonly type: 'capture.start';
  /**
   * Required (even if empty) — the engine's decoder reads the top-level
   * `payload` field and rejects the envelope if it's missing. Inner
   * fields are all optional. See ADR-0010 / the 2026-05-28 dev-loop fix.
   *
   * `language`: ISO-639-1 code ("vi", "en", "th"…) to lock the session
   * to that language. Omit (or pass "auto") to let WhisperKit auto-detect
   * per transcribe call. Locking is strongly recommended for non-English
   * speech because per-window auto-detect on short audio is unreliable.
   */
  readonly payload: {
    readonly sources?: { readonly mic?: boolean; readonly system?: boolean };
    readonly translation?: {
      readonly enabled?: boolean;
      readonly mode?: string;
      readonly target_lang?: string;
    };
    readonly language?: string;
    /**
     * Privacy gates (ADR-0027). Mirror `CaptureStartCommand.keepAudio` /
     * `.rememberSpeakers` in WireProtocol.swift — snake_case on the wire,
     * folded via `.convertFromSnakeCase`. BOTH default to the privacy-safe
     * behavior when ABSENT (the engine treats `nil`/absent as false), so we
     * only ever send `true`/`false` from the user's persisted choice.
     *
     *  - keep_audio:        persist the meeting audio (future review screen).
     *  - remember_speakers: store + match voiceprints (enrollment, ADR-0026).
     */
    readonly keep_audio?: boolean;
    readonly remember_speakers?: boolean;
  };
}

/**
 * Language choices surfaced in the top-bar picker. `null` = auto-detect.
 * Order is roughly "developer's likely use cases first" — adjust freely;
 * Whisper supports ~99 languages, this is just a quick-pick.
 */
export interface LanguageChoice {
  readonly code: string | null;
  readonly label: string;
}

export const LANGUAGE_CHOICES: readonly LanguageChoice[] = [
  { code: null, label: 'Auto' },
  { code: 'en', label: 'English' },
  { code: 'vi', label: 'Tiếng Việt' },
  { code: 'th', label: 'ไทย' },
  { code: 'zh', label: '中文' },
  { code: 'ja', label: '日本語' },
  { code: 'ko', label: '한국어' },
];

export interface CaptureStopCommand {
  readonly type: 'capture.stop';
}

export interface BookmarkCreateCommand {
  readonly type: 'bookmark.create';
  /** `t` = moment in the recording (seconds since capture start). */
  readonly payload: { readonly t: number; readonly label?: string };
}

/**
 * Rename one or more speakers in a saved meeting. Sent from the
 * meeting-saved card's roster editor (Phase 5.1).
 *
 * `names` maps the speaker's CURRENT label (the map key the engine knows —
 * "Speaker 1", or a previously-applied name on a second edit) to the user's
 * chosen display name. Include ONLY rows whose name actually changed; the
 * engine rewrites those labels in the vault file for `session_id`. The
 * engine replies with a plain `ack` on success and an `error` frame on
 * failure (no dedicated inbound frame). Matches the Swift
 * `SpeakerRenameCommand` decoder — keys are passed through verbatim, so
 * `.convertFromSnakeCase` does not touch the dictionary values/keys.
 */
export interface SpeakerRenameCommand {
  readonly type: 'speaker.rename';
  readonly payload: {
    readonly session_id: string;
    readonly names: Record<string, string>;
  };
}

/**
 * Persist a generated meeting summary into the saved meeting note (ADR-0031).
 * The renderer NEVER writes the vault — main NEVER writes the vault behind the
 * engine's back — so the summary goes back through the engine, which appends a
 * `## Summary` section to the meeting markdown for `session_id` and makes the
 * local git-commit (keeping vault writes + git history single-owner, CLAUDE.md
 * #4). Mirrors `SpeakerRenameCommand`'s shape: the engine replies with a plain
 * `ack` on success and an `error` frame on failure (no dedicated inbound
 * frame), surfaced via the existing `errors$` / `lastError` channel.
 */
export interface SummaryWriteCommand {
  readonly type: 'summary.write';
  readonly payload: {
    readonly session_id: string;
    readonly summary: string;
  };
}

export type EngineCommand =
  | CaptureStartCommand
  | CaptureStopCommand
  | BookmarkCreateCommand
  | SpeakerRenameCommand
  | SummaryWriteCommand;

// ─── Renderer-side derived types ─────────────────────────────────────

/**
 * UI-side merged segment. Holds the latest known text + interval for a
 * given utterance_id, plus whether it's been finalized. The engine
 * service maintains a Map keyed by utterance_id and emits this shape
 * downstream so components can render with `@for (s of segments(); ...)`.
 */
export interface DisplayedSegment {
  readonly utteranceId: string;
  readonly segmentId: string | null;
  readonly tStart: number;
  readonly tEnd: number;
  readonly text: string;
  readonly language: string | null;
  readonly speaker: string | null;
  readonly translation: string | null;
  readonly isFinal: boolean;
}

export type ConnectionState =
  | { kind: 'idle' }
  | { kind: 'connecting' }
  | { kind: 'connected'; helloAt: number }
  | { kind: 'disconnected'; reason: string }
  | { kind: 'error'; message: string };

export type CaptureState =
  | { kind: 'idle' }
  | { kind: 'starting' }
  | { kind: 'running'; sessionId: string; startedAt: string }
  | { kind: 'stopping' };
