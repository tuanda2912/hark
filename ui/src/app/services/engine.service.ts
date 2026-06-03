// EngineService — owns the WebSocket connection to harkd.
//
// Responsibilities:
//   - Discover the engine port via the preload-exposed window.hark API.
//   - Connect, parse incoming envelopes, dispatch to typed handlers.
//   - Expose connection + capture state as Angular signals.
//   - Maintain a utterance_id-keyed Map of displayed segments. New
//     segments add; segments with the same utterance_id REPLACE; a
//     `segment.final` flips the isFinal flag for that utterance_id.
//   - Expose a `segments()` signal returning the ordered list (by
//     t_start) for the live-transcript view.
//
// Java/Spring analogue: this is a `@Service` with two concerns —
// connection lifecycle (like a `WebSocketHandler`) and a derived
// in-memory projection (like a denormalized read model).

import { Injectable, signal, computed, Signal } from '@angular/core';
import { Subject } from 'rxjs';
import {
  WireEnvelope,
  MetaHelloPayload,
  MetaHeartbeatPayload,
  MetaReadyPayload,
  MetaModelProgressPayload,
  CaptureStartedPayload,
  CaptureStoppedPayload,
  SegmentPayload,
  SegmentSupersededPayload,
  ErrorPayload,
  WarningPayload,
  BookmarkCreatedPayload,
  MeetingSavedPayload,
  MeetingTranscriptPayload,
  RagResultChunk,
  RagResultsPayload,
  RagIndexStatusPayload,
  RagConnectionResult,
  DisplayedSegment,
  ConnectionState,
  CaptureState,
  EngineCommand,
} from './engine.types';
import type { Prefs, PrefsResult } from './preferences.service';
import type {
  LlmConfig,
  LlmStatus,
  LlmTestResult,
  SummarizeReq,
  SummarizeResult,
  AskReq,
  AskResult,
  TranslateReq,
  TranslateResult,
  TranslateSegmentReq,
  TranslateSegmentResult,
  CloudCallLogEntry,
} from './llm.types';

/** Capture/connection snapshot pushed to the menu-bar tray. Mirrors
 *  TrayState in main/tray.ts and preload.ts. */
export interface TrayState {
  capturing: boolean;
  ready: boolean;
  connected: boolean;
}

/** Tray-initiated actions routed from main → renderer. */
export type TrayAction = 'start' | 'stop';

declare global {
  interface Window {
    hark?: {
      getEnginePort(): Promise<number>;
      /** Push capture/connection state to the tray (icon + menu enablement). */
      setTrayState(state: TrayState): void;
      /** Register a handler for tray Start/Stop. Whitelisted in preload. */
      onTrayAction(cb: (action: TrayAction) => void): void;
      /** Load persisted prefs + the vault path. */
      loadPrefs(): Promise<PrefsResult>;
      /** Persist prefs (fire-and-forget; re-validated in main). */
      savePrefs(prefs: Prefs): void;
      /** Reveal the vault folder in Finder. */
      revealVault(): void;
      /** Read a persisted meeting-audio .wav (validated vault-internal path in
       *  main) for the Post-Meeting Review screen. Resolves with the raw bytes;
       *  rejects if the path is outside the vault / not a .wav / unreadable. */
      readMeetingAudio(path: string): Promise<Uint8Array>;
      /** Current macOS Microphone TCC status ('granted' | 'denied' |
       *  'restricted' | 'not-determined' | 'unknown'). */
      getMicPermission(): Promise<string>;
      /** Fire the macOS Microphone prompt; resolves true if granted. */
      askMicPermission(): Promise<boolean>;
      /**
       * LLM provider bridge (ADR-0029). All provider HTTP lives in MAIN; the
       * renderer only talks over this IPC surface — no direct network, no CSP
       * relaxation, and the API key is set/cleared but NEVER read back (main
       * encrypts it via safeStorage). The renderer consumes `LlmStatus`
       * (booleans + non-secret config) and `LlmTestResult` only.
       */
      llm: {
        /** Current provider readiness snapshot. */
        getStatus(): Promise<LlmStatus>;
        /** Persist the non-secret provider/model/baseUrl; returns the new status. */
        setConfig(cfg: LlmConfig): Promise<LlmStatus>;
        /** Save the API key for the CURRENT provider (main encrypts it). The
         *  key never round-trips back; the renderer learns only `hasKey`. */
        setApiKey(key: string): Promise<LlmStatus>;
        /** Forget the saved key for the current provider. */
        clearApiKey(): Promise<LlmStatus>;
        /** Probe the configured provider; returns a one-line verdict. */
        testConnection(): Promise<LlmTestResult>;
        /**
         * Summarize transcript TEXT (ADR-0031). Main owns the cloud/local fork,
         * redaction (cloud only), the provider HTTP, and the local cloud-call
         * log. The renderer never makes a network call and never sees the key.
         */
        summarize(req: SummarizeReq): Promise<SummarizeResult>;
        /**
         * Translate the whole transcript to a target language (BACKLOG
         * translation §1). Same egress model as summarize: main redacts for a
         * cloud send, sends as-is for a local (loopback) model. The renderer
         * never makes a network call and never sees the key.
         */
        translate(req: TranslateReq): Promise<TranslateResult>;
        /**
         * Answer a question about THIS meeting from its transcript TEXT
         * (Phase 6 slice 3). Same egress model as `summarize`: main owns the
         * cloud/local fork, redaction (cloud only), the provider HTTP, and the
         * local cloud-call log. The renderer never makes a network call, never
         * sees the key, and persists nothing.
         */
        ask(req: AskReq): Promise<AskResult>;
        /**
         * Translate ONE finalized caption line to an arbitrary target (ADR-0035,
         * §3 — live translation). Fired per finalized segment when the user
         * opted in. Same egress model as the other calls: CLOUD redacts the line
         * first, LOCAL (loopback) sends it as-is (zero egress). Egress is
         * AGGREGATED into one metadata-only cloud-log entry — never one per line.
         */
        translateSegment(req: TranslateSegmentReq): Promise<TranslateSegmentResult>;
        /** Commit the pending live-translation roll-up to its single aggregated
         *  cloud-log entry (called when live translation stops). Fire-and-forget. */
        flushLiveTranslate(): void;
        /** Read the local cloud-activity log (metadata only — never content)
         *  for Settings → Privacy. */
        getCloudLog(): Promise<CloudCallLogEntry[]>;
      };
      /**
       * EXTERNAL vault-retrieval backend bridge (ADR-0033/0034). Present only as
       * a typed surface — actually used only when the user picked an external
       * backend (prefs.rag.backend === 'external'); the built-in backend
       * retrieves in the engine over this WebSocket instead. LOOPBACK-only;
       * main enforces the guard. Absent outside Electron.
       */
      rag?: {
        /** Retrieve top-K vault chunks via the external backend. Same chunk
         *  shape as the built-in engine path. Rejects on a content-free error
         *  (unreachable / non-loopback / malformed). */
        retrieve(
          query: string,
          opts?: { k?: number; scope?: string },
        ): Promise<readonly RagResultChunk[]>;
        /** Probe the configured external backend (Settings "Test connection"). */
        testConnection(): Promise<RagConnectionResult>;
      };
    };
  }
}

@Injectable({ providedIn: 'root' })
export class EngineService {
  // ─── Public signals ─────────────────────────────────────────────────

  private readonly _connection = signal<ConnectionState>({ kind: 'idle' });
  readonly connection: Signal<ConnectionState> = this._connection.asReadonly();

  private readonly _capture = signal<CaptureState>({ kind: 'idle' });
  readonly capture: Signal<CaptureState> = this._capture.asReadonly();

  private readonly _heartbeat = signal<MetaHeartbeatPayload | null>(null);
  readonly heartbeat: Signal<MetaHeartbeatPayload | null> =
    this._heartbeat.asReadonly();

  private readonly _hello = signal<MetaHelloPayload | null>(null);
  readonly hello: Signal<MetaHelloPayload | null> = this._hello.asReadonly();

  /**
   * True once the engine model is loaded and capture can start. Set by
   * `meta.ready`, or by `meta.hello` when a late-connecting client gets
   * the real model name (i.e. not the "(loading)" placeholder). Reset to
   * false on socket close so a reconnect re-gates the Start affordance.
   */
  private readonly _ready = signal(false);
  readonly ready = this._ready.asReadonly();

  /**
   * Latest `meta.model_progress` frame during a cold-start warm-up, or
   * null when no progress is in flight. Drives the "Preparing Hark"
   * overlay (detail text + determinate bar / indeterminate spinner).
   * Cleared on `meta.ready` (warm-up done) and on socket close (a fresh
   * connection re-derives readiness, so stale progress must not linger).
   */
  private readonly _modelProgress = signal<MetaModelProgressPayload | null>(null);
  readonly modelProgress: Signal<MetaModelProgressPayload | null> =
    this._modelProgress.asReadonly();

  /**
   * Latest error envelope from the engine. Cleared when capture starts
   * again. Drives the inline error banner in the UI.
   */
  private readonly _lastError = signal<ErrorPayload | null>(null);
  readonly lastError: Signal<ErrorPayload | null> = this._lastError.asReadonly();

  /**
   * Internal segments map keyed by utterance_id. Mutated by handlers,
   * snapshotted into the signal so Angular can detect changes.
   */
  private readonly segmentsMap = new Map<string, DisplayedSegment>();
  private readonly _segmentsTick = signal(0);
  readonly segments: Signal<readonly DisplayedSegment[]> = computed(() => {
    // Touch the tick so this re-evaluates when the map is mutated.
    this._segmentsTick();
    return Array.from(this.segmentsMap.values()).sort(
      (a, b) => a.tStart - b.tStart,
    );
  });

  // RxJS surface for the things signals don't fit well: error toasts,
  // warning banners, bookmark confirmations. Subjects keep the event
  // semantics ("each emission is a discrete thing") that signals collapse.
  readonly errors$ = new Subject<ErrorPayload>();
  readonly warnings$ = new Subject<WarningPayload>();
  readonly bookmarkCreated$ = new Subject<BookmarkCreatedPayload>();
  /** Fired once per meeting when the engine reports a vault write complete. */
  readonly meetingSaved$ = new Subject<MeetingSavedPayload>();

  /**
   * Fired each time a `segment.final` lands during a LIVE capture — the hook
   * LiveTranslationService listens on to translate finalized lines to an
   * arbitrary target (ADR-0035, §3). Deliberately NOT fired by the post-stop
   * `meeting.transcript` swap (those clean labeled lines are §1's job, not live
   * per-segment translation), so the orchestrator only ever sees genuine live
   * finals. Emits the merged DisplayedSegment so a listener has the
   * utteranceId + text + speaker without re-reading the map.
   */
  readonly segmentFinalized$ = new Subject<DisplayedSegment>();

  /**
   * The most recent `meeting.saved` payload, retained so a component that
   * mounts (or re-renders) after the event can still show the saved
   * confirmation + speaker roster. Cleared on `clearTranscript()`.
   */
  private readonly _lastMeetingSaved = signal<MeetingSavedPayload | null>(null);
  readonly lastMeetingSaved: Signal<MeetingSavedPayload | null> =
    this._lastMeetingSaved.asReadonly();

  /** All bookmarks created this session, in creation order. */
  private readonly _bookmarks = signal<BookmarkCreatedPayload[]>([]);
  readonly bookmarks: Signal<readonly BookmarkCreatedPayload[]> =
    this._bookmarks.asReadonly();

  /**
   * Latest `rag.index_status` from the engine, or null before the first frame
   * (or when RAG is unavailable — the embedder/index didn't load). Drives the
   * Ask panel's vault-index indicator: `building` shows "Indexing your vault…"
   * (+ `indexed_count`/`total` progress), `ready` enables confident vault Q&A.
   * Reset to null on socket close so a reconnect re-derives it.
   */
  private readonly _ragIndexStatus = signal<RagIndexStatusPayload | null>(null);
  readonly ragIndexStatus: Signal<RagIndexStatusPayload | null> =
    this._ragIndexStatus.asReadonly();

  private socket: WebSocket | null = null;

  // ─── rag.retrieve request/response correlation ──────────────────────
  //
  // The socket is otherwise fire-and-forget (push frames + `ack` we ignore).
  // `rag.retrieve` is the one REQUEST/REPLY exchange: we tag the outbound
  // envelope with a unique `id`, park a pending promise here, and resolve it
  // when the matching `rag.results` (id-correlated) arrives — or reject it on a
  // matching `error` frame, a timeout, or socket close. Keyed by the id we mint.
  private ragSeq = 0;
  private readonly pendingRag = new Map<
    string,
    {
      resolve: (chunks: readonly RagResultChunk[]) => void;
      reject: (err: Error) => void;
      timeout: ReturnType<typeof setTimeout>;
    }
  >();

  /** How long to wait for a `rag.results` before giving up. A cold-built index
   *  query is well under a second; this is a generous ceiling so a stuck engine
   *  surfaces an honest error instead of a hung spinner. */
  private static readonly RAG_RETRIEVE_TIMEOUT_MS = 15_000;

  // ─── Lifecycle ──────────────────────────────────────────────────────

  /**
   * Discover the engine port from the preload-exposed API, then connect.
   * Idempotent — subsequent calls are no-ops while already connected.
   */
  async connect(): Promise<void> {
    if (this._connection().kind === 'connecting' || this._connection().kind === 'connected') {
      return;
    }
    if (!window.hark) {
      this._connection.set({
        kind: 'error',
        message:
          'window.hark not available — preload script did not run. ' +
          'Are you running the renderer outside Electron?',
      });
      return;
    }
    this._connection.set({ kind: 'connecting' });
    let port: number;
    try {
      port = await window.hark.getEnginePort();
    } catch (err) {
      this._connection.set({
        kind: 'error',
        message: `engine port discovery failed: ${stringifyError(err)}`,
      });
      return;
    }
    const url = `ws://127.0.0.1:${port}/v1`;
    const ws = new WebSocket(url);
    this.socket = ws;
    ws.onopen = () => {
      // hello frame is sent by the server; we don't transition to
      // 'connected' until we see it (proves protocol compatibility).
    };
    ws.onerror = () => {
      this._connection.set({
        kind: 'error',
        message: `websocket error against ${url}`,
      });
    };
    ws.onclose = (ev) => {
      this._connection.set({
        kind: 'disconnected',
        reason: `${ev.code} ${ev.reason || ''}`.trim(),
      });
      // Re-gate Start on reconnect: a fresh socket must see hello/ready
      // again before we trust the model is loaded.
      this._ready.set(false);
      // Drop any in-flight warm-up progress — a reconnect re-derives it.
      this._modelProgress.set(null);
      // Stale index state from the dead connection must not linger; a reconnect
      // re-derives it from fresh `rag.index_status` frames.
      this._ragIndexStatus.set(null);
      // Fail any in-flight vault retrievals — their reply can never arrive now.
      this.rejectAllPendingRag('engine connection closed');
      this.socket = null;
    };
    ws.onmessage = (ev) => this.dispatchFrame(ev.data);
  }

  // ─── Commands ───────────────────────────────────────────────────────

  startCapture(opts?: {
    mic?: boolean;
    system?: boolean;
    /** ISO-639-1 code or null/undefined for auto-detect. */
    language?: string | null;
    /** Persist the meeting audio locally (ADR-0027). Default false ⇒ the
     *  engine discards audio after transcription (current behavior). */
    keepAudio?: boolean;
    /** Store + match voiceprints (ADR-0026/0027). Default false ⇒ the engine
     *  performs zero `.speakers/` reads/writes. */
    rememberSpeakers?: boolean;
    /** Live translate captions → English (BACKLOG translation §2). Default false.
     *  When true the engine runs WhisperKit with `task: .translate` (any source
     *  language → English text), on-device, zero egress. Whisper only translates
     *  TO English; other live targets are §3. */
    translateToEnglish?: boolean;
  }): void {
    // Payload is required by the engine's decoder even when empty —
    // see CaptureStartCommand type. Default to both sources unless the
    // caller explicitly opts out.
    const sources = { mic: opts?.mic ?? true, system: opts?.system ?? true };
    const payload: {
      sources: typeof sources;
      language?: string;
      keep_audio: boolean;
      remember_speakers: boolean;
      translation?: { enabled: boolean; mode: string; target_lang: string };
    } = {
      sources,
      // Privacy gates (ADR-0027). Always sent explicitly from the user's
      // persisted choice; absent would read as false engine-side anyway, but
      // sending the boolean keeps the contract unambiguous. Privacy-first:
      // anything not explicitly enabled is false.
      keep_audio: opts?.keepAudio ?? false,
      remember_speakers: opts?.rememberSpeakers ?? false,
    };
    if (opts?.language) payload.language = opts.language;
    // Live → English (§2). Only sent when on; the engine flips its decode task
    // to `.translate`. mode/target_lang are carried for the §3 contract (live
    // arbitrary target); §2 only does English, so target_lang is "en".
    if (opts?.translateToEnglish) {
      payload.translation = { enabled: true, mode: 'live', target_lang: 'en' };
    }
    const cmd: EngineCommand = { type: 'capture.start', payload };
    // A fresh capture is a fresh meeting: reset the on-screen view so the
    // previous meeting's segments, saved card, bookmarks, and stale error
    // don't bleed into the new session. View-only — does not touch the
    // socket, readiness, or capture state. (Pause/resume must NOT call this;
    // only startCapture begins a new session.)
    this.clearTranscript();
    this._capture.set({ kind: 'starting' });
    this.send(cmd);
  }

  stopCapture(): void {
    if (this._capture().kind !== 'running') return;
    this._capture.set({ kind: 'stopping' });
    this.send({ type: 'capture.stop' });
  }

  /**
   * Mark the current moment. `t` is seconds since capture start; the
   * caller computes it (the engine echoes it back in bookmark.created).
   */
  createBookmark(t: number, label?: string): void {
    this.send({ type: 'bookmark.create', payload: { t, label } });
  }

  /**
   * Rename speakers in a previously-saved meeting. `names` maps each
   * speaker's CURRENT label (the key the engine knows — "Speaker 1", or an
   * already-applied name) to its new display name. Only changed rows should
   * be passed; a no-op (empty map) sends nothing. The engine acks on success
   * and emits an `error` frame on failure, which surfaces through the
   * existing `errors$` / `lastError` channel — no new inbound frame.
   */
  renameSpeakers(sessionId: string, names: Record<string, string>): void {
    if (Object.keys(names).length === 0) return;
    this.send({ type: 'speaker.rename', payload: { session_id: sessionId, names } });
    this.applyOptimisticRename(sessionId, names);
  }

  /**
   * Persist a generated meeting summary into the saved meeting note (ADR-0031).
   * Sent over the SAME socket as `renameSpeakers` (the `send()` path); the
   * engine appends a `## Summary` section to `session_id`'s meeting markdown and
   * makes the local git-commit, then acks. A no-op for empty content. Failure
   * arrives as an `error` frame on the existing `errors$` / `lastError` channel
   * — there is no dedicated inbound frame.
   */
  writeSummary(sessionId: string, summary: string): void {
    if (!sessionId || summary.trim().length === 0) return;
    this.send({ type: 'summary.write', payload: { session_id: sessionId, summary } });
  }

  /**
   * Persist a transcript translation into the saved meeting note (BACKLOG
   * translation §1). Mirrors `writeSummary`: sent over the same socket; the
   * engine appends a `## Transcript — <lang>` section to `session_id`'s markdown
   * and git-commits, then acks. No-op for empty content. Failure arrives as an
   * `error` frame on the existing `errors$` / `lastError` channel.
   */
  writeTranslation(sessionId: string, lang: string, translation: string): void {
    if (!sessionId || !lang.trim() || translation.trim().length === 0) return;
    this.send({
      type: 'translation.write',
      payload: { session_id: sessionId, lang, translation },
    });
  }

  /**
   * Retrieve the top-`k` vault chunks for `query` from the engine's local RAG
   * index (Phase 6 slice 4c, ADR-0032/0033). The engine embeds the query
   * locally, brute-force cosine-ranks the index, and reads each hit's snippet
   * LIVE from the vault — nothing leaves the machine here. This is the only
   * request/reply exchange on the socket: we tag the envelope with a unique id
   * and await the id-correlated `rag.results` reply.
   *
   * Resolves with the hits (possibly empty — no vault match). REJECTS on:
   *   - an id-correlated `error` frame (e.g. RAG_UNAVAILABLE when the embedder/
   *     index didn't load) — the message is surfaced to the caller, NOT the
   *     global error banner (it's a scoped failure the Ask panel renders inline);
   *   - a timeout (engine hung);
   *   - the socket not being open / closing mid-flight.
   *
   * The caller (the host's vault-scope Ask) feeds the returned chunks into
   * `llm.ask` (main), which redacts them for a cloud model (ADR-0031) or sends
   * them as-is for a local one. The engine never calls a model.
   */
  retrieve(
    query: string,
    opts?: { k?: number; scope?: string },
  ): Promise<readonly RagResultChunk[]> {
    const q = query.trim();
    if (q.length === 0) return Promise.resolve([]);
    if (!this.socket || this.socket.readyState !== WebSocket.OPEN) {
      return Promise.reject(new Error('not connected to the engine'));
    }
    const id = `rag-${++this.ragSeq}`;
    return new Promise<readonly RagResultChunk[]>((resolve, reject) => {
      const timeout = setTimeout(() => {
        this.pendingRag.delete(id);
        reject(new Error('vault search timed out'));
      }, EngineService.RAG_RETRIEVE_TIMEOUT_MS);
      this.pendingRag.set(id, { resolve, reject, timeout });
      this.send(
        {
          type: 'rag.retrieve',
          payload: {
            query: q,
            ...(opts?.k !== undefined ? { k: opts.k } : {}),
            ...(opts?.scope !== undefined ? { scope: opts.scope } : {}),
          },
        },
        id,
      );
    });
  }

  /** Settle + drop a pending `rag.retrieve` by id (clears its timeout). Returns
   *  the parked handlers, or undefined if the id is unknown/already settled. */
  private takePendingRag(id: string | undefined) {
    if (id === undefined) return undefined;
    const pending = this.pendingRag.get(id);
    if (!pending) return undefined;
    clearTimeout(pending.timeout);
    this.pendingRag.delete(id);
    return pending;
  }

  /** Reject + clear every parked `rag.retrieve` (socket closed — no reply can
   *  arrive). Clears each timeout so nothing fires post-rejection. */
  private rejectAllPendingRag(reason: string): void {
    for (const [, pending] of this.pendingRag) {
      clearTimeout(pending.timeout);
      pending.reject(new Error(reason));
    }
    this.pendingRag.clear();
  }

  /**
   * Reflect a `speaker.rename` in the retained `meeting.saved` roster
   * immediately, before the engine acks — so every consumer that reads
   * `lastMeetingSaved()` (the Attendees panel, the meeting-saved card) shows
   * the new name reactively. This is the SINGLE source of truth for the
   * optimistic update; surfaces should NOT keep their own divergent copy.
   *
   * For each speaker whose CURRENT label is a key in `names`, set its
   * `matched_name` to the chosen name AND advance its `label` to that name —
   * so the speaker's rename key for a follow-up edit is the new name, matching
   * the engine's own relabeling. Only touched when the saved session matches
   * (a stale/mismatched session id is a no-op, leaving the roster untouched).
   * If the engine later rejects the rename it emits an `error` frame on the
   * existing channel; this is an optimistic projection, not a guarantee.
   */
  private applyOptimisticRename(
    sessionId: string,
    names: Record<string, string>,
  ): void {
    // Session-id guard: only the most-recently-saved meeting is renameable
    // (ADR-0020 MVP), and the displayed transcript is that same meeting's, so a
    // mismatched id leaves BOTH the roster and the transcript untouched.
    const saved = this._lastMeetingSaved();
    if (!saved || saved.session_id !== sessionId) return;

    // 1) Roster (Attendees panel + saved card read this signal).
    this._lastMeetingSaved.update((s) => {
      if (!s || s.session_id !== sessionId) return s;
      let changed = false;
      const speakers = s.speakers.map((sp) => {
        const next = names[sp.label];
        if (next === undefined || next === sp.label) return sp;
        changed = true;
        return { ...sp, label: next, matched_name: next };
      });
      return changed ? { ...s, speakers } : s;
    });

    // 2) Displayed transcript: relabel every line spoken by a renamed speaker so
    // the on-screen lines (and their colors, which key off the now-advanced
    // roster label) update with the roster. The label keys match because the
    // labeled transcript rows carry the SAME "Speaker N" labels as the roster.
    let touched = false;
    for (const [key, seg] of this.segmentsMap) {
      const next = seg.speaker ? names[seg.speaker] : undefined;
      if (next === undefined || next === seg.speaker) continue;
      this.segmentsMap.set(key, { ...seg, speaker: next });
      touched = true;
    }
    if (touched) this._segmentsTick.update((v) => v + 1);
  }

  /**
   * Reset the on-screen transcript view to empty — the "New meeting" /
   * clear-screen action, and the auto-reset at the top of startCapture().
   *
   * Clears: the displayed segments map (+ tick so `segments()` recomputes to
   * empty), the retained `meeting.saved` card state, the per-session bookmark
   * highlights, and the last engine error banner.
   *
   * Does NOT touch the WebSocket connection, readiness, or capture state —
   * this is view-only. The saved vault files are untouched (each
   * capture.start→stop is its own meeting file).
   */
  clearTranscript(): void {
    this.segmentsMap.clear();
    this._segmentsTick.update((v) => v + 1);
    this._bookmarks.set([]);
    this._lastMeetingSaved.set(null);
    this._lastError.set(null);
  }

  // ─── Speaker → color (single source of truth) ───────────────────────
  //
  // ONE mapping used by BOTH the Attendees panel and the transcript so a
  // speaker's color matches everywhere within a meeting. We cycle the six muted
  // palette tokens (--sp-1..--sp-6) keyed by ROSTER ORDER — the index of the
  // label in lastMeetingSaved().speakers. After a rename the roster's `label`
  // advances to the new name (applyOptimisticRename), and the relabeled
  // transcript rows carry that same new label, so both still resolve to the
  // same palette slot. Fallback (no roster yet, or a label not in it): order of
  // first appearance among the displayed segments — so the transcript still
  // colors consistently before/without a meeting.saved roster.

  /** Stable index 0..5 for a speaker label within the current meeting. Roster
   *  order wins; otherwise first-appearance order in the displayed segments. */
  private speakerIndexFor(label: string): number {
    const saved = this._lastMeetingSaved();
    if (saved) {
      const i = saved.speakers.findIndex((sp) => sp.label === label);
      if (i >= 0) return i;
    }
    // Fallback: first-appearance order among labeled segments (sorted by tStart,
    // matching the rendered order), de-duped to a stable per-label slot.
    const seen: string[] = [];
    for (const s of this.segments()) {
      if (s.speaker && !seen.includes(s.speaker)) seen.push(s.speaker);
    }
    const j = seen.indexOf(label);
    return j >= 0 ? j : 0;
  }

  /** Palette CSS-var token (`var(--sp-N)`) for a speaker label, stable within a
   *  meeting and SHARED with the Attendees panel so colors agree across
   *  surfaces. Cycles --sp-1..--sp-6 by the speaker's roster index. */
  speakerColorFor(label: string | null): string {
    if (!label) return 'var(--text-3)';
    return `var(--sp-${(this.speakerIndexFor(label) % 6) + 1})`;
  }

  // ─── Internals ──────────────────────────────────────────────────────

  private send(cmd: EngineCommand, id?: string): void {
    if (!this.socket || this.socket.readyState !== WebSocket.OPEN) {
      this.errors$.next({
        code: 'NOT_CONNECTED',
        message: `cannot send ${cmd.type} — socket not open`,
        recoverable: true,
        action: null,
      });
      return;
    }
    // Attach an envelope-level `id` for the one request/reply exchange
    // (`rag.retrieve` → id-correlated `rag.results`). Fire-and-forget commands
    // send no id; the engine's decoder treats it as optional either way.
    const frame = id !== undefined ? { ...cmd, id } : cmd;
    this.socket.send(JSON.stringify(frame));
  }

  private dispatchFrame(raw: unknown): void {
    if (typeof raw !== 'string') return;
    let env: WireEnvelope;
    try {
      env = JSON.parse(raw) as WireEnvelope;
    } catch {
      // Malformed frame — log to errors stream, drop.
      this.errors$.next({
        code: 'BAD_FRAME',
        message: 'received non-JSON frame',
        recoverable: true,
        action: null,
      });
      return;
    }
    switch (env.type) {
      case 'meta.hello': {
        const hello = env.payload as MetaHelloPayload;
        this._hello.set(hello);
        this._connection.set({ kind: 'connected', helloAt: Date.now() });
        // A client connecting after the model is ready gets the real
        // model name here (not "(loading)") and is immediately ready.
        this._ready.set(hello.model_loaded !== '(loading)');
        break;
      }
      case 'meta.ready':
        this._ready.set(true);
        // Warm-up is done — clear progress so the overlay tears down.
        this._modelProgress.set(null);
        // Keep the displayed model name fresh when hello arrived during load.
        this._hello.update((h) =>
          h ? { ...h, model_loaded: (env.payload as MetaReadyPayload).model_loaded } : h,
        );
        break;
      case 'meta.model_progress':
        // Cold-start warm-up tick (download / ANE-compile). Drives the
        // "Preparing Hark" overlay; superseded by meta.ready, which clears it.
        this._modelProgress.set(env.payload as MetaModelProgressPayload);
        break;
      case 'meta.heartbeat':
        this._heartbeat.set(env.payload as MetaHeartbeatPayload);
        break;
      case 'ack':
        // Ack matches an inbound command by id. v1 doesn't surface this
        // beyond logging; future versions may pair ack→command for retry.
        break;
      case 'capture.started': {
        const p = env.payload as CaptureStartedPayload;
        this._capture.set({
          kind: 'running',
          sessionId: p.session_id,
          startedAt: p.started_at,
        });
        break;
      }
      case 'capture.stopped': {
        const _p = env.payload as CaptureStoppedPayload;
        this._capture.set({ kind: 'idle' });
        break;
      }
      case 'segment.partial':
        this.applySegment(env.payload as SegmentPayload, false);
        break;
      case 'segment.final':
        this.applySegment(env.payload as SegmentPayload, true);
        break;
      case 'segment.superseded': {
        // Retraction (ADR-0009): the older fragment has been replaced by a
        // more-complete re-segmentation. Drop it from the displayed set;
        // `superseded_by` arrives (or has arrived) via its own segment.*
        // frames through the normal upsert path, so we don't touch it here.
        const p = env.payload as SegmentSupersededPayload;
        if (this.segmentsMap.delete(p.utterance_id)) {
          // Bump the same tick applySegment() uses so the segments()
          // computed re-evaluates after this map mutation.
          this._segmentsTick.update((v) => v + 1);
        }
        break;
      }
      case 'bookmark.created': {
        const bm = env.payload as BookmarkCreatedPayload;
        this._bookmarks.update((list) => [...list, bm]);
        this.bookmarkCreated$.next(bm);
        break;
      }
      case 'meeting.transcript': {
        // Post-stop swap (ADR-0021): replace the messy live partials/dupes with
        // the deduped, diarization-LABELED final transcript exactly as written
        // to the vault. Arrives just before meeting.saved. View-only — does not
        // touch connection or capture state.
        this.applyMeetingTranscript(env.payload as MeetingTranscriptPayload);
        break;
      }
      case 'meeting.saved': {
        const saved = env.payload as MeetingSavedPayload;
        this._lastMeetingSaved.set(saved);
        this.meetingSaved$.next(saved);
        break;
      }
      case 'rag.results': {
        // Reply to a `rag.retrieve` — resolve the id-correlated pending promise.
        // An unknown/stale id (already timed out) is ignored.
        const pending = this.takePendingRag(env.id);
        if (pending) {
          pending.resolve((env.payload as RagResultsPayload).chunks);
        }
        break;
      }
      case 'rag.index_status':
        // Unsolicited index-build state for the Ask panel's vault indicator.
        this._ragIndexStatus.set(env.payload as RagIndexStatusPayload);
        break;
      case 'warning':
        this.warnings$.next(env.payload as WarningPayload);
        break;
      case 'error': {
        const err = env.payload as ErrorPayload;
        // If this error is the id-correlated reply to an in-flight
        // `rag.retrieve` (e.g. RAG_UNAVAILABLE), reject THAT promise and stop —
        // it's a scoped failure the Ask panel renders inline, not a global
        // banner. Don't also push it to errors$/lastError.
        const pendingRag = this.takePendingRag(env.id);
        if (pendingRag) {
          pendingRag.reject(new Error(err.message || err.code));
          break;
        }
        this.errors$.next(err);
        this._lastError.set(err);
        // If capture was mid-start when this error landed, revert
        // state so the UI doesn't get stuck on "starting". Same for
        // mid-stop.
        const cap = this._capture();
        if (cap.kind === 'starting') this._capture.set({ kind: 'idle' });
        else if (cap.kind === 'stopping') {
          // Engine refused stop — stay running.
          // (Best-effort; real recovery is reconnect.)
        }
        break;
      }
      default:
        // Unknown type — ignore for forward compatibility.
        break;
    }
  }

  /**
   * Swap the displayed transcript for the labeled, deduped final from
   * `meeting.transcript`. Clears the live segments map and repopulates it from
   * `utterances`, each as a FINALIZED segment (isFinal: true, speaker set,
   * keyed by its stable utterance id). This replaces the live partials/dupes
   * with the clean labeled version that matches the saved vault file, so every
   * line shows its speaker. View-only — capture/connection state untouched.
   *
   * No t_end / language / translation on the wire here, so we synthesize: tEnd
   * = tStart (the line is point-anchored for sorting/bookmark range; the labeled
   * final has no per-line end), language/translation null. utteranceId = u.id so
   * a later speaker.rename can relabel these rows by matching speaker.
   */
  private applyMeetingTranscript(p: MeetingTranscriptPayload): void {
    this.segmentsMap.clear();
    for (const u of p.utterances) {
      this.segmentsMap.set(u.id, {
        utteranceId: u.id,
        segmentId: null,
        tStart: u.t_start,
        tEnd: u.t_start,
        text: u.text,
        language: null,
        speaker: u.speaker,
        translation: null,
        isFinal: true,
      });
    }
    this._segmentsTick.update((v) => v + 1);
  }

  private applySegment(p: SegmentPayload, isFinal: boolean): void {
    // Replace-by-utterance-id semantics — matches harkd's contract.
    // A `segment.final` with the same utterance_id as a prior partial
    // mutates the row in place and flips its isFinal flag.
    const seg: DisplayedSegment = {
      utteranceId: p.utterance_id,
      segmentId: p.segment_id,
      tStart: p.t_start,
      tEnd: p.t_end,
      text: p.text,
      language: p.language,
      speaker: p.speaker,
      translation: p.translation,
      isFinal,
    };
    this.segmentsMap.set(p.utterance_id, seg);
    this._segmentsTick.update((v) => v + 1);
    // Live per-segment translation hook (ADR-0035, §3): notify listeners ONLY
    // on a final (never partials — bounds the LLM call count). The orchestrator
    // dedupes by utteranceId and writes any translation back via
    // setSegmentTranslation(). Emitted after the map update so a synchronous
    // listener reading segments() sees this line.
    if (isFinal) this.segmentFinalized$.next(seg);
  }

  /**
   * Set the live translation for a displayed segment by utterance id (ADR-0035,
   * §3). Called by LiveTranslationService when a per-segment translation comes
   * back from main. A NO-OP if the segment is gone (superseded, or the view was
   * cleared / swapped for the post-stop labeled transcript) — so a late
   * translation for a retracted line can't resurrect it. Bumps the tick so the
   * `segments()` computed re-evaluates and the line re-renders with its
   * translation under the original. Never networks — main produced the text.
   */
  setSegmentTranslation(utteranceId: string, translation: string): void {
    const seg = this.segmentsMap.get(utteranceId);
    if (!seg) return;
    if (seg.translation === translation) return;
    this.segmentsMap.set(utteranceId, { ...seg, translation });
    this._segmentsTick.update((v) => v + 1);
  }
}

function stringifyError(err: unknown): string {
  if (err instanceof Error) return err.message;
  if (typeof err === 'string') return err;
  return JSON.stringify(err);
}
