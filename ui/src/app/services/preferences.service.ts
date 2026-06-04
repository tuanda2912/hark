// PreferencesService — renderer-side wrapper over the prefs IPC bridge.
//
// Owns the user's persisted defaults (audio source toggles + language)
// and the read-only vault path. State is exposed as signals; `save()`
// pushes the current snapshot back to main, which validates + persists it.
//
// Guard: window.hark is undefined outside Electron (bare `ng serve` in a
// browser). Exactly like the tray code in app.component, we degrade to
// in-memory defaults — no persistence, but the UI stays functional.
//
// The Prefs shape here MUST mirror the main-process Prefs in
// src/main/prefs.ts. The renderer can't import from src/main (it's
// excluded from tsconfig.app.json), so the type is duplicated; keep the
// two in lockstep.

import { Injectable, signal, Signal } from '@angular/core';

/** UI appearance choice — 'system' follows the macOS Light/Dark setting.
 *  Mirrors `Prefs.theme` in src/main/prefs.ts. */
export type ThemeChoice = 'system' | 'light' | 'dark';

/** Mirrors `Prefs` in src/main/prefs.ts. Versioned & minimal. */
export interface Prefs {
  readonly version: 1;
  readonly audio: {
    readonly mic: boolean;
    readonly system: boolean;
    readonly language: string | null;
  };
  /** Whether the first-run onboarding flow has been completed. */
  readonly hasCompletedOnboarding: boolean;
  /** UI appearance: 'system' (follow macOS) | 'light' | 'dark'. */
  readonly theme: ThemeChoice;
  /** Privacy & data-control flags (ADR-0027). All default false. */
  readonly privacy: {
    readonly keepAudio: boolean;
    readonly rememberSpeakers: boolean;
    readonly syncAudio: boolean;
    readonly syncSpeakers: boolean;
  };
  /** Vault-retrieval backend (ADR-0033/0034). Optional; absent ⇒ built-in
   *  (the engine handles retrieval). Set to external to query a user-run
   *  LOCAL service. Mirrors `Prefs.rag` in src/main/prefs.ts. */
  readonly rag?: {
    readonly backend: 'builtin' | 'external';
    readonly external?: {
      readonly transport: 'http' | 'mcp';
      readonly endpoint: string;
      readonly toolName?: string;
    };
  };
}

/** Retrieval transport for an external backend (mirrors main `RagTransport`). */
export type RagTransport = 'http' | 'mcp';
/** Which retrieval backend answers vault questions. */
export type RagBackend = 'builtin' | 'external';

/** Mirrors the `hark:load-prefs` response shape in main/preload.ts. */
export interface PrefsResult {
  readonly prefs: Prefs;
  readonly vaultPath: string;
}

const DEFAULT_PREFS: Prefs = {
  version: 1,
  audio: { mic: true, system: true, language: null },
  hasCompletedOnboarding: false,
  theme: 'system',
  privacy: {
    keepAudio: false,
    rememberSpeakers: false,
    syncAudio: false,
    syncSpeakers: false,
  },
};

@Injectable({ providedIn: 'root' })
export class PreferencesService {
  // Audio defaults — seeded from disk on construction, written back on save().
  private readonly _mic = signal(DEFAULT_PREFS.audio.mic);
  private readonly _system = signal(DEFAULT_PREFS.audio.system);
  private readonly _language = signal<string | null>(DEFAULT_PREFS.audio.language);
  readonly mic: Signal<boolean> = this._mic.asReadonly();
  readonly system: Signal<boolean> = this._system.asReadonly();
  readonly language: Signal<string | null> = this._language.asReadonly();

  /** Absolute vault path for display + "Reveal in Finder". Empty until
   *  loaded (or when running outside Electron). */
  private readonly _vaultPath = signal<string>('');
  readonly vaultPath: Signal<string> = this._vaultPath.asReadonly();

  /** Whether the first-run onboarding flow has been completed. Seeded from
   *  disk; flipped true by completeOnboarding(). The app gates the
   *  full-window onboarding overlay on the inverse of this. Defaults false
   *  (= treat as first run) until the async load resolves. */
  private readonly _hasCompletedOnboarding = signal(
    DEFAULT_PREFS.hasCompletedOnboarding,
  );
  readonly hasCompletedOnboarding: Signal<boolean> =
    this._hasCompletedOnboarding.asReadonly();

  // ─── Appearance (light/dark/system) ─────────────────────────────────
  // The user's theme choice; ThemeService reads this and applies the resolved
  // theme to <html data-theme>. 'system' follows the OS. Seeded from disk;
  // persisted immediately on change.
  private readonly _theme = signal<ThemeChoice>(DEFAULT_PREFS.theme);
  readonly theme: Signal<ThemeChoice> = this._theme.asReadonly();

  // ─── Privacy & data-control flags (ADR-0027) ────────────────────────
  // All default OFF (privacy-first). The engine gates audio/voiceprint
  // storage on keepAudio/rememberSpeakers (sent in capture.start); the two
  // sync flags are forward-looking intent. Each setter persists immediately.
  private readonly _keepAudio = signal(DEFAULT_PREFS.privacy.keepAudio);
  private readonly _rememberSpeakers = signal(
    DEFAULT_PREFS.privacy.rememberSpeakers,
  );
  private readonly _syncAudio = signal(DEFAULT_PREFS.privacy.syncAudio);
  private readonly _syncSpeakers = signal(DEFAULT_PREFS.privacy.syncSpeakers);
  readonly keepAudio: Signal<boolean> = this._keepAudio.asReadonly();
  readonly rememberSpeakers: Signal<boolean> = this._rememberSpeakers.asReadonly();
  readonly syncAudio: Signal<boolean> = this._syncAudio.asReadonly();
  readonly syncSpeakers: Signal<boolean> = this._syncSpeakers.asReadonly();

  // ─── Vault-retrieval backend (ADR-0033/0034) ────────────────────────
  // Which backend answers VAULT-scope Ask questions: 'builtin' (the engine's
  // local index, default) or 'external' (a user-run LOCAL retrieval service).
  // The external endpoint/transport/toolName are only meaningful when backend
  // is 'external'; they're retained across a toggle so switching back and forth
  // doesn't lose the typed-in endpoint. Persisted as the `rag` prefs block.
  private readonly _ragBackend = signal<RagBackend>('builtin');
  private readonly _ragTransport = signal<RagTransport>('mcp');
  private readonly _ragEndpoint = signal<string>('');
  private readonly _ragToolName = signal<string>('');
  readonly ragBackend: Signal<RagBackend> = this._ragBackend.asReadonly();
  readonly ragTransport: Signal<RagTransport> = this._ragTransport.asReadonly();
  readonly ragEndpoint: Signal<string> = this._ragEndpoint.asReadonly();
  readonly ragToolName: Signal<string> = this._ragToolName.asReadonly();

  /** True once the initial load() has resolved (or fallen back). Lets the
   *  UI avoid persisting placeholder defaults before disk is read. */
  private readonly _loaded = signal(false);
  readonly loaded: Signal<boolean> = this._loaded.asReadonly();

  constructor() {
    void this.load();
  }

  /** Pull prefs + vault path from main. No-op-safe outside Electron. */
  async load(): Promise<void> {
    if (!window.hark?.loadPrefs) {
      // Bare ng serve / browser — keep in-memory defaults.
      this._loaded.set(true);
      return;
    }
    try {
      const res = await window.hark.loadPrefs();
      this._mic.set(res.prefs.audio.mic);
      this._system.set(res.prefs.audio.system);
      this._language.set(res.prefs.audio.language);
      // Tolerate an older main that doesn't yet send the field (reads as
      // first run) — the renderer must never throw on a partial response.
      this._hasCompletedOnboarding.set(!!res.prefs.hasCompletedOnboarding);
      // Appearance: a missing/invalid value (old main) reads as 'system'.
      this._theme.set(normalizeTheme(res.prefs.theme));
      // Privacy flags — a missing block (old main) reads as all-false, the
      // privacy-first state. `??`/`!!` keep us safe against a partial payload.
      const pv = res.prefs.privacy;
      this._keepAudio.set(!!pv?.keepAudio);
      this._rememberSpeakers.set(!!pv?.rememberSpeakers);
      this._syncAudio.set(!!pv?.syncAudio);
      this._syncSpeakers.set(!!pv?.syncSpeakers);
      // RAG backend (ADR-0033/0034). A missing block (old main / fresh install /
      // default) reads as built-in. The external sub-block is only applied when
      // present; transport defaults to 'mcp' if a stored value is unexpected.
      const rag = res.prefs.rag;
      this._ragBackend.set(rag?.backend === 'external' ? 'external' : 'builtin');
      if (rag?.external) {
        this._ragTransport.set(rag.external.transport === 'http' ? 'http' : 'mcp');
        this._ragEndpoint.set(rag.external.endpoint ?? '');
        this._ragToolName.set(rag.external.toolName ?? '');
      }
      this._vaultPath.set(res.vaultPath);
    } catch {
      // Leave defaults in place — load failures must not break the app.
    } finally {
      this._loaded.set(true);
    }
  }

  /** Update the in-memory defaults and persist. Components call this when
   *  the user changes a default (and AppComponent mirrors the live toggles
   *  here when not capturing). */
  setAudioDefaults(opts: {
    mic?: boolean;
    system?: boolean;
    language?: string | null;
  }): void {
    if (opts.mic !== undefined) this._mic.set(opts.mic);
    if (opts.system !== undefined) this._system.set(opts.system);
    if (opts.language !== undefined) this._language.set(opts.language);
    this.save();
  }

  /** Set the UI appearance and persist. ThemeService reacts to the signal and
   *  applies the resolved theme to <html>. */
  setTheme(theme: ThemeChoice): void {
    this._theme.set(normalizeTheme(theme));
    this.save();
  }

  /** Update one or more privacy flags and persist (ADR-0027). Components pass
   *  only the flag(s) the user changed; the rest stay put. The onboarding
   *  privacy step and Settings → Privacy both write through here. */
  setPrivacy(opts: {
    keepAudio?: boolean;
    rememberSpeakers?: boolean;
    syncAudio?: boolean;
    syncSpeakers?: boolean;
  }): void {
    if (opts.keepAudio !== undefined) this._keepAudio.set(opts.keepAudio);
    if (opts.rememberSpeakers !== undefined)
      this._rememberSpeakers.set(opts.rememberSpeakers);
    if (opts.syncAudio !== undefined) this._syncAudio.set(opts.syncAudio);
    if (opts.syncSpeakers !== undefined)
      this._syncSpeakers.set(opts.syncSpeakers);
    this.save();
  }

  /**
   * Update the vault-retrieval backend selection and persist (ADR-0033/0034).
   * Pass only the field(s) that changed; the rest stay put (so toggling backend
   * keeps the typed-in endpoint). Endpoint/toolName are trimmed. The snapshot
   * builder turns this into the `rag` prefs block; an 'external' backend with an
   * empty endpoint sanitizes back to built-in main-side (a half-config can't
   * silently route retrieval at a blank URL).
   */
  setRag(opts: {
    backend?: RagBackend;
    transport?: RagTransport;
    endpoint?: string;
    toolName?: string;
  }): void {
    if (opts.backend !== undefined) this._ragBackend.set(opts.backend);
    if (opts.transport !== undefined) this._ragTransport.set(opts.transport);
    if (opts.endpoint !== undefined) this._ragEndpoint.set(opts.endpoint.trim());
    if (opts.toolName !== undefined) this._ragToolName.set(opts.toolName.trim());
    this.save();
  }

  /** Build the `rag` prefs block from the current signals. Built-in ⇒
   *  `{ backend: 'builtin' }` (main drops it → reads as the default); external ⇒
   *  the full block. Always included in the snapshot so switching back to
   *  built-in actually clears a prior external config. */
  private ragSnapshot(): Prefs['rag'] {
    if (this._ragBackend() !== 'external') return { backend: 'builtin' };
    const external: { transport: RagTransport; endpoint: string; toolName?: string } = {
      transport: this._ragTransport(),
      endpoint: this._ragEndpoint(),
    };
    const tool = this._ragToolName();
    if (tool.length > 0) external.toolName = tool;
    return { backend: 'external', external };
  }

  /** Push the current snapshot back to main. Fire-and-forget; no-op outside
   *  Electron. We don't persist before the initial load resolves, so a slow
   *  disk read can't be clobbered by placeholder defaults. */
  save(): void {
    if (!this._loaded()) return;
    window.hark?.savePrefs?.(this.snapshot());
  }

  /** Open the vault folder in Finder via main. No-op outside Electron. */
  revealVault(): void {
    window.hark?.revealVault?.();
  }

  /** Reveal a specific vault file in Finder (open its folder + select it) — e.g.
   *  the saved meeting note. main validates the path is inside the vault. No-op
   *  for an empty path / outside Electron. */
  revealPath(filePath: string): void {
    if (!filePath) return;
    window.hark?.revealPath?.(filePath);
  }

  /** Mark the first-run onboarding flow complete and persist it. Called
   *  when the user taps "Start using Hark". Idempotent; the overlay reads
   *  the inverse of `hasCompletedOnboarding` and dismisses for good once
   *  this lands. Outside Electron the signal still flips (in-memory only),
   *  so the dev/browser flow doesn't get stuck on the overlay. */
  completeOnboarding(): void {
    this._hasCompletedOnboarding.set(true);
    this.save();
  }

  private snapshot(): Prefs {
    return {
      version: 1,
      audio: {
        mic: this._mic(),
        system: this._system(),
        language: this._language(),
      },
      hasCompletedOnboarding: this._hasCompletedOnboarding(),
      theme: this._theme(),
      privacy: {
        keepAudio: this._keepAudio(),
        rememberSpeakers: this._rememberSpeakers(),
        syncAudio: this._syncAudio(),
        syncSpeakers: this._syncSpeakers(),
      },
      rag: this.ragSnapshot(),
    };
  }
}

/** Coerce an untrusted theme value to a known choice; anything unexpected
 *  (missing, an old main that doesn't send it, a typo) reads as 'system'. */
function normalizeTheme(v: unknown): ThemeChoice {
  return v === 'light' || v === 'dark' ? v : 'system';
}
