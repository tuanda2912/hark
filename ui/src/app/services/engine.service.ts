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
  DisplayedSegment,
  ConnectionState,
  CaptureState,
  EngineCommand,
} from './engine.types';
import type { Prefs, PrefsResult } from './preferences.service';

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

  private socket: WebSocket | null = null;

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
  }): void {
    // Payload is required by the engine's decoder even when empty —
    // see CaptureStartCommand type. Default to both sources unless the
    // caller explicitly opts out.
    const sources = { mic: opts?.mic ?? true, system: opts?.system ?? true };
    const payload: { sources: typeof sources; language?: string } = { sources };
    if (opts?.language) payload.language = opts.language;
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

  // ─── Internals ──────────────────────────────────────────────────────

  private send(cmd: EngineCommand): void {
    if (!this.socket || this.socket.readyState !== WebSocket.OPEN) {
      this.errors$.next({
        code: 'NOT_CONNECTED',
        message: `cannot send ${cmd.type} — socket not open`,
        recoverable: true,
        action: null,
      });
      return;
    }
    this.socket.send(JSON.stringify(cmd));
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
      case 'meeting.saved': {
        const saved = env.payload as MeetingSavedPayload;
        this._lastMeetingSaved.set(saved);
        this.meetingSaved$.next(saved);
        break;
      }
      case 'warning':
        this.warnings$.next(env.payload as WarningPayload);
        break;
      case 'error': {
        const err = env.payload as ErrorPayload;
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

  private applySegment(p: SegmentPayload, isFinal: boolean): void {
    // Replace-by-utterance-id semantics — matches harkd's contract.
    // A `segment.final` with the same utterance_id as a prior partial
    // mutates the row in place and flips its isFinal flag.
    this.segmentsMap.set(p.utterance_id, {
      utteranceId: p.utterance_id,
      segmentId: p.segment_id,
      tStart: p.t_start,
      tEnd: p.t_end,
      text: p.text,
      language: p.language,
      speaker: p.speaker,
      translation: p.translation,
      isFinal,
    });
    this._segmentsTick.update((v) => v + 1);
  }
}

function stringifyError(err: unknown): string {
  if (err instanceof Error) return err.message;
  if (typeof err === 'string') return err;
  return JSON.stringify(err);
}
