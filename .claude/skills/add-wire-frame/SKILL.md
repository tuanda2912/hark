---
name: add-wire-frame
description: Adds or changes a message/frame in Hark's harkd↔UI WebSocket protocol, keeping BOTH sides in lockstep. Use this skill whenever you add or edit a wire message — a new engine→UI event (meta.*, capture.*, segment.*, warning, error) or a UI→engine command (capture.*, bookmark.*) — or when the user says things like "the engine should send X to the UI", "add a frame/field", or "the UI should send a Y command". A frame only truly exists when the Swift struct, the TypeScript interface, AND both handlers all agree; this skill makes sure none of those four edit points is forgotten and the snake_case wire shape stays correct. Pairs with the harkd-wire-expert agent.
---

Add or modify a WebSocket frame so the Swift engine (`harkd`) and the Angular UI never drift. The #1 failure mode is editing one side only: the other side then silently ignores the frame (forward-compat drops unknown types) and you debug a "nothing happens" ghost. This skill enumerates the four edit points so that can't happen.

## The contract (read first)

- **Envelope**: every frame is `{ v, ts, type, payload }` (commands may add `id` for ack correlation). `v` = `WIRE_PROTOCOL_VERSION`.
- **Casing**: the engine encodes outbound with `.convertToSnakeCase` and decodes inbound with `.convertFromSnakeCase`. So a Swift property `modelLoaded` becomes wire `model_loaded` becomes TS `model_loaded`. **Name the Swift field in camelCase, the TS field in snake_case, and they line up automatically.**
- **Nullable fields**: if a field must serialize as JSON `null` (not be omitted), follow `SegmentPayload` in `WireProtocol.swift` — it gives an explicit `CodingKeys` + `encode(to:)` that `encodeNil`s optionals. Omission vs `null` matters when the UI distinguishes "absent" from "explicitly empty".

The two mirrors that MUST agree:
- `engine/Sources/Harkd/WireProtocol.swift` (Swift `Encodable`/`Decodable` structs)
- `ui/src/app/services/engine.types.ts` (TypeScript interfaces)

## Procedure — engine → UI event (e.g. `meta.ready`, `warning`)

1. **Swift payload** — in `WireProtocol.swift`, "Engine → UI payloads" section, add:
   ```swift
   struct FooPayload: Encodable {
       let someField: String   // → wire "some_field"
   }
   ```
2. **TS interface** — in `engine.types.ts`, mirror it with snake_case fields:
   ```ts
   export interface FooPayload { readonly some_field: string; }
   ```
3. **Emit (engine)** — from `EngineSession.swift`, send it. Broadcast to all clients (`broadcast(WireEnvelope(type: "foo.bar", payload: FooPayload(...)))`) or `sendOnly` to one. Mirror how `capture.started` / `meta.ready` are sent.
4. **Consume (UI)** — in `engine.service.ts` `dispatchFrame`, add `case 'foo.bar':` and project the payload into a signal or one of the `Subject`s (`warnings$` etc.). Unknown types hit `default: break`, so without this case the frame is silently dropped.

## Procedure — UI → engine command (e.g. `capture.start`, `bookmark.create`)

1. **Swift command** — in `WireProtocol.swift`, "UI → Engine command payloads", add a `Decodable` struct (optional fields where the UI may omit them).
2. **TS command type** — in `engine.types.ts`, add the command interface and include it in the `EngineCommand` union; add a `send()` path in `engine.service.ts`. Remember the payload field is **required even when empty** — the engine's decoder reads top-level `payload` and rejects the envelope if missing.
3. **Dispatch (engine)** — in `EngineSession.handleInbound`, add `case "foo.bar":` routing to a handler. `handleInbound` runs on the actor; if the handler must `await`, make the case `await dispatch…` and guard reentrancy (see `dispatchCaptureStart`).
4. **Ack/error** — reply with `sendAck` on success or `sendError(code:…, recoverable:…)` on failure. Never `exit()` on a client-induced problem.

## Verify

- Engine: `cd engine && swift build -c release`
- UI: `cd ui && npx tsc -p tsconfig.app.json --noEmit` (and `ngc -p tsconfig.app.json --noEmit` if templates changed)
- **Confirm the JSON shape**: reason through the encoder — a Swift `modelLoaded` field with `.convertToSnakeCase` produces `"model_loaded"`. State the exact frame, e.g.:
  ```json
  {"v":1,"ts":"…","type":"meta.ready","payload":{"model_loaded":"large-v3…"}}
  ```
- For real runtime confirmation, use the `smoke-harkd` skill and watch the frame arrive in `websocat`.

## Worked example: `meta.ready`

Engine pushes it from `EngineSession.attachModel`; payload `MetaReadyPayload { modelLoaded: String }` → wire `{type:"meta.ready", payload:{model_loaded:"…"}}`; UI mirrors `MetaReadyPayload { model_loaded: string }` and handles `case 'meta.ready':` to flip a `ready` signal. Four edit points, all four touched.

## Keep it honest

`meta.hello.capabilities` advertises only what truly ships — don't list a capability a frame doesn't back. And the socket is loopback-only with no auth; if a change would expose it beyond `127.0.0.1`, stop — that's an ADR + threat-model decision, not a wire tweak. See [CLAUDE.md](../../../CLAUDE.md) and [ADR-0008](../../../docs/decisions/0008-phase-3-streaming-architecture.md).
