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
  CaptureStartedPayload,
  CaptureStoppedPayload,
  SegmentPayload,
  ErrorPayload,
  WarningPayload,
  DisplayedSegment,
  ConnectionState,
  CaptureState,
  EngineCommand,
} from './engine.types';

declare global {
  interface Window {
    hark?: {
      getEnginePort(): Promise<number>;
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
  // warning banners. Subjects keep the event semantics ("each emission
  // is a discrete thing") that signals collapse.
  readonly errors$ = new Subject<ErrorPayload>();
  readonly warnings$ = new Subject<WarningPayload>();

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
      this.socket = null;
    };
    ws.onmessage = (ev) => this.dispatchFrame(ev.data);
  }

  // ─── Commands ───────────────────────────────────────────────────────

  startCapture(opts?: { mic?: boolean; system?: boolean }): void {
    const sources = opts ? { mic: opts.mic ?? true, system: opts.system ?? true } : undefined;
    const cmd: EngineCommand = sources
      ? { type: 'capture.start', payload: { sources } }
      : { type: 'capture.start' };
    this._capture.set({ kind: 'starting' });
    this.send(cmd);
  }

  stopCapture(): void {
    if (this._capture().kind !== 'running') return;
    this._capture.set({ kind: 'stopping' });
    this.send({ type: 'capture.stop' });
  }

  /**
   * Clear the displayed segments. Doesn't touch the engine — purely a
   * local reset, e.g. for "clear screen between meetings."
   */
  clearSegments(): void {
    this.segmentsMap.clear();
    this._segmentsTick.update((v) => v + 1);
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
      case 'meta.hello':
        this._hello.set(env.payload as MetaHelloPayload);
        this._connection.set({ kind: 'connected', helloAt: Date.now() });
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
      case 'warning':
        this.warnings$.next(env.payload as WarningPayload);
        break;
      case 'error':
        this.errors$.next(env.payload as ErrorPayload);
        break;
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
