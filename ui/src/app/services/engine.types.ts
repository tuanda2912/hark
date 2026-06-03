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

// ─── Vault RAG (Phase 6 slice 4, ADR-0032/0033) ──────────────────────
//
// Engine-side retrieval over the local vault vector index. `rag.retrieve` is a
// UI→engine REQUEST (command, below); `rag.results` is the engine's reply
// (this payload), correlated by the request envelope `id` (like `ack`);
// `rag.index_status` is an unsolicited engine→UI event for the index-build
// indicator. Field names mirror `WireProtocol.swift` exactly (snake_case on the
// wire via `.convertToSnakeCase`).
//
// PRIVACY: a chunk's `text` is vault content the engine returns to the LOCAL UI
// over the loopback socket only — it is never networked by the engine (rule
// #1/#2). When the renderer forwards chunks to a CLOUD model it does so via
// main's `llm.ask`, which redacts first (ADR-0031); a local model sends them
// as-is (zero egress).

/** One retrieval hit. Mirrors the Swift `RagResultChunk`: the snippet `text`
 *  read live from the vault at `[char_start, char_end)`, plus its source
 *  metadata for a citation / jump-to-source affordance and the cosine `score`
 *  (higher = closer). All fields non-optional. */
export interface RagResultChunk {
  readonly text: string;
  /** Vault-relative note path, e.g. "meetings/2026-06-01-standup.md". */
  readonly note_path: string;
  /** Heading breadcrumb above the chunk, e.g. "Decisions › Pricing". */
  readonly heading_path: string;
  readonly char_start: number;
  readonly char_end: number;
  readonly score: number;
}

/** `rag.results` — reply to a `rag.retrieve`, correlated by envelope `id`.
 *  `chunks` is the top-K hits, score-descending. */
export interface RagResultsPayload {
  readonly chunks: readonly RagResultChunk[];
}

/**
 * `rag.index_status` — unsolicited engine→UI event on index build start /
 * progress / done, so the Ask panel can show an index-state indicator while a
 * cold build runs. `state` is one of the three literal values; `indexed_count`
 * is how many notes have been (re)indexed so far this build; `total` is the
 * cold-build denominator (count of `.md` files) or `null` for an incremental
 * single-file update (no meaningful total). Mirrors the Swift
 * `RagIndexStatusPayload` — `total` is explicit JSON `null` (never a dropped
 * key) so we can distinguish "no total" (incremental) from a forgotten field.
 */
export interface RagIndexStatusPayload {
  readonly state: 'idle' | 'building' | 'ready';
  readonly indexed_count: number;
  readonly total: number | null;
}

/** Verdict of an EXTERNAL retrieval-backend connection probe (ADR-0033/0034),
 *  surfaced by `window.hark.rag.testConnection()` for Settings. Content-free
 *  one-liner; `count` is hits/tools seen when known. Mirrors main's
 *  `RagConnectionResult`. (Only the external backend has a connection to test —
 *  the built-in backend retrieves in the engine over this same socket.) */
export interface RagConnectionResult {
  readonly ok: boolean;
  readonly detail: string;
  readonly count?: number;
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

/**
 * Ask the engine to retrieve the top-`k` vault chunks for `query` (Phase 6
 * slice 4c, ADR-0032/0033). The engine embeds `query` locally (e5 `.query`),
 * brute-force cosine-ranks the index, reads each hit's snippet live from the
 * vault, and replies with a `rag.results` frame correlated by the envelope
 * `id`. `k` is optional (the engine applies a default + clamps a huge value);
 * `scope` reserves room for future sub-path scoping ("vault" = everything in
 * v1). The engine NEVER calls a model — it only returns local chunks; main
 * owns the redact→LLM step. Mirrors the Swift `RagRetrieveCommand`.
 */
export interface RagRetrieveCommand {
  readonly type: 'rag.retrieve';
  readonly payload: {
    readonly query: string;
    readonly k?: number;
    readonly scope?: string;
  };
}

/**
 * Persist a generated transcript TRANSLATION into the saved meeting note
 * (BACKLOG translation §1). Mirrors `SummaryWriteCommand`: the translation is
 * produced in Electron main (the egress chokepoint) and the engine only
 * PERSISTS it — appending a `## Transcript — <lang>` section to the meeting
 * markdown for `session_id` and making the local git-commit (vault writes stay
 * single-owner, CLAUDE.md #4). `lang` is the human language name used in the
 * heading (e.g. "Thai"); a re-translate to the same `lang` REPLACES that
 * section (idempotent), while a different `lang` adds a separate section. The
 * engine replies `ack` on success, `error` on failure (existing channel).
 */
export interface TranslationWriteCommand {
  readonly type: 'translation.write';
  readonly payload: {
    readonly session_id: string;
    readonly lang: string;
    readonly translation: string;
  };
}

export type EngineCommand =
  | CaptureStartCommand
  | CaptureStopCommand
  | BookmarkCreateCommand
  | SpeakerRenameCommand
  | SummaryWriteCommand
  | TranslationWriteCommand
  | RagRetrieveCommand;

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
