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

export interface WarningPayload {
  readonly code: string;
  readonly message: string;
  readonly severity: string;
}

export interface ErrorPayload {
  readonly code: string;
  readonly message: string;
  readonly recoverable: boolean;
  readonly action: string | null;
}

// ─── UI → Engine command shapes ──────────────────────────────────────

export interface CaptureStartCommand {
  readonly type: 'capture.start';
  readonly payload?: {
    readonly sources?: { readonly mic?: boolean; readonly system?: boolean };
    readonly translation?: {
      readonly enabled?: boolean;
      readonly mode?: string;
      readonly target_lang?: string;
    };
  };
}

export interface CaptureStopCommand {
  readonly type: 'capture.stop';
}

export type EngineCommand = CaptureStartCommand | CaptureStopCommand;

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
