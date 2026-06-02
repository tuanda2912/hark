// SettingsPanel — modal preferences overlay.
//
// A backdrop + centered card with three sections backed by REAL state:
//   - General (read-only): engine version + model (from EngineService
//     `hello`), connection status.
//   - Audio: default Mic/System toggles + default Language — the persisted
//     defaults applied at app launch (NOT the live, capture-locked toggles
//     in the top bar). Changing one writes through PreferencesService.
//   - Vault: the vault path (read-only) + "Reveal in Finder".
//
// Deliberately scoped: NO theme/redaction/Q&A controls — those are Phase 6
// and would be dead UI today (per the build brief). The Privacy section IS
// wired (ADR-0027): the two storage gates (Keep audio, Remember speakers) are
// read by the engine on capture.start; the two sync flags are forward-looking
// intent (audio + voiceprints are already gitignored).
//
// Dismissal: Esc (host keydown), backdrop click, and the close button all
// fire `close`. Clicks inside the card stop-propagate so they don't bubble
// to the backdrop handler.

import {
  ChangeDetectionStrategy,
  Component,
  HostListener,
  computed,
  effect,
  inject,
  signal,
  output,
} from '@angular/core';
import { EngineService } from '../services/engine.service';
import { PreferencesService } from '../services/preferences.service';
import { LlmService } from '../services/llm.service';
import { LANGUAGE_CHOICES } from '../services/engine.types';
import type { LlmProviderId } from '../services/llm.types';

@Component({
  selector: 'hark-settings-panel',
  standalone: true,
  changeDetection: ChangeDetectionStrategy.OnPush,
  templateUrl: './settings-panel.component.html',
  styleUrl: './settings-panel.component.css',
})
export class SettingsPanelComponent {
  /** Emitted on Esc, backdrop click, or the close button. */
  readonly close = output<void>();

  private readonly engine = inject(EngineService);
  private readonly prefs = inject(PreferencesService);
  private readonly llm = inject(LlmService);

  constructor() {
    // Settings is mounted on open (AppComponent `@if (settingsOpen())`), so
    // construction == open: pull the latest cloud-activity log + provider
    // status. Fire-and-forget; both are guarded no-ops outside Electron.
    void this.llm.refreshCloudLog();
    void this.llm.refresh();
  }

  // ─── General (read-only) ────────────────────────────────────────────
  private readonly hello = this.engine.hello;
  private readonly connection = this.engine.connection;

  readonly engineVersion = computed(() => this.hello()?.engine_version ?? '—');
  readonly modelLoaded = computed(() => this.hello()?.model_loaded ?? '—');
  readonly connectionLabel = computed(() => {
    const c = this.connection();
    switch (c.kind) {
      case 'idle':
        return 'idle';
      case 'connecting':
        return 'connecting…';
      case 'connected':
        return 'connected';
      case 'disconnected':
        return `disconnected (${c.reason})`;
      case 'error':
        return 'error';
    }
  });
  /** Green dot when connected, amber while connecting, red otherwise. */
  readonly connectionColor = computed(() => {
    switch (this.connection().kind) {
      case 'connected':
        return 'var(--status-success)';
      case 'connecting':
        return 'var(--status-warning)';
      default:
        return 'var(--status-recording)';
    }
  });

  // ─── Audio defaults ─────────────────────────────────────────────────
  readonly languageChoices = LANGUAGE_CHOICES;
  readonly mic = this.prefs.mic;
  readonly system = this.prefs.system;
  readonly language = this.prefs.language;

  toggleMicDefault(): void {
    this.prefs.setAudioDefaults({ mic: !this.mic() });
  }

  toggleSystemDefault(): void {
    this.prefs.setAudioDefaults({ system: !this.system() });
  }

  /** Empty string from the <select> becomes null (auto-detect). */
  onLanguageChange(value: string): void {
    this.prefs.setAudioDefaults({ language: value === '' ? null : value });
  }

  // ─── Privacy (ADR-0027) ─────────────────────────────────────────────
  // The four data-control flags, bound to PreferencesService. Keep audio +
  // Remember speakers gate what the engine stores (sent in capture.start);
  // Sync audio + Sync speakers are forward-looking intent. All default OFF.
  readonly keepAudio = this.prefs.keepAudio;
  readonly rememberSpeakers = this.prefs.rememberSpeakers;
  readonly syncAudio = this.prefs.syncAudio;
  readonly syncSpeakers = this.prefs.syncSpeakers;

  toggleKeepAudio(): void {
    this.prefs.setPrivacy({ keepAudio: !this.keepAudio() });
  }
  toggleRememberSpeakers(): void {
    this.prefs.setPrivacy({ rememberSpeakers: !this.rememberSpeakers() });
  }
  toggleSyncAudio(): void {
    this.prefs.setPrivacy({ syncAudio: !this.syncAudio() });
  }
  toggleSyncSpeakers(): void {
    this.prefs.setPrivacy({ syncSpeakers: !this.syncSpeakers() });
  }

  // ─── Models (LLM provider) — ADR-0029 ───────────────────────────────
  //
  // Configures the cloud/local model used by Ask + summaries. All provider
  // HTTP lives in Electron MAIN; this pane only talks to `window.hark.llm`
  // over IPC via LlmService. The API key is sent down to main (encrypted via
  // safeStorage) and NEVER read back — the input is a write-only field cleared
  // after Save, and we surface only the `hasKey` indicator.
  //
  // The provider/model/baseUrl are edited in local draft signals so the user
  // can type freely, then committed with Save (setConfig). The draft seeds
  // from the current config and follows it as the persisted status changes.
  readonly llmConfigured = this.llm.configured;
  readonly llmHasKey = this.llm.hasKey;
  readonly llmConfig = this.llm.config;
  readonly llmTesting = this.llm.testing;
  readonly llmTestResult = this.llm.testResult;

  /** Local draft of the provider, seeded from the saved config (default
   *  anthropic). Drives which fields show + what Save persists. */
  readonly draftProvider = signal<LlmProviderId>(
    this.llm.config()?.provider ?? 'anthropic',
  );
  readonly draftModel = signal<string>(this.llm.config()?.model ?? '');
  readonly draftBaseUrl = signal<string>(this.llm.config()?.baseUrl ?? '');

  /** Write-only API-key field. Held locally only long enough to send to main,
   *  then cleared on Save — we can't read the stored key back and never want
   *  to display it. */
  readonly draftApiKey = signal<string>('');

  /** The status loads over async IPC, so the saved config may be null at field
   *  init. Seed the drafts ONCE the first config arrives, without clobbering a
   *  user who has already started editing. After that, the drafts are the
   *  user's working copy and Save is the only writer back to main. */
  private seededDraft = false;
  private readonly _seedDraft = effect(() => {
    const cfg = this.llm.config();
    if (this.seededDraft || !cfg) return;
    this.draftProvider.set(cfg.provider);
    this.draftModel.set(cfg.model);
    this.draftBaseUrl.set(cfg.baseUrl ?? '');
    this.seededDraft = true;
  });

  /** Whether the base-URL row is shown (OpenAI-compatible / local only). */
  readonly showBaseUrl = computed(
    () => this.draftProvider() === 'openai-compatible',
  );

  /** Placeholder model name, provider-appropriate. */
  readonly modelPlaceholder = computed(() =>
    this.draftProvider() === 'anthropic'
      ? 'claude-3-5-sonnet-latest'
      : 'gpt-4o (cloud) or llama3.1 (local)',
  );

  onProviderChange(value: string): void {
    // Only the two known ids; anything else falls back to anthropic.
    this.draftProvider.set(
      value === 'openai-compatible' ? 'openai-compatible' : 'anthropic',
    );
    // Switching providers invalidates a prior probe result.
    this.llm.testResult.set(null);
  }

  onModelChange(value: string): void {
    this.draftModel.set(value);
  }

  onBaseUrlChange(value: string): void {
    this.draftBaseUrl.set(value);
  }

  onApiKeyChange(value: string): void {
    this.draftApiKey.set(value);
  }

  /** Persist the non-secret provider/model/baseUrl. baseUrl is only sent for
   *  the openai-compatible provider (trimmed; omitted when blank). */
  async saveModelConfig(): Promise<void> {
    const provider = this.draftProvider();
    const model = this.draftModel().trim();
    const baseUrl = this.draftBaseUrl().trim();
    await this.llm.setConfig({
      provider,
      model,
      ...(provider === 'openai-compatible' && baseUrl ? { baseUrl } : {}),
    });
  }

  /** Send the typed key to main, then clear the field — we never keep or
   *  re-display it. No-op on an empty field. */
  async saveApiKey(): Promise<void> {
    const key = this.draftApiKey();
    if (!key) return;
    await this.llm.setApiKey(key);
    this.draftApiKey.set('');
  }

  /** Forget the saved key for the current provider; also clears any draft. */
  async clearApiKey(): Promise<void> {
    await this.llm.clearApiKey();
    this.draftApiKey.set('');
  }

  /** Probe the configured provider; result surfaces inline. */
  async testConnection(): Promise<void> {
    await this.llm.test();
  }

  // ─── Cloud activity (ADR-0031) ──────────────────────────────────────
  //
  // A read-only list of recent model calls (cloud AND local), metadata only —
  // never transcript content. The list comes from main's local
  // `cloud-calls.json` via LlmService. Settings is mounted only while open
  // (AppComponent's `@if (settingsOpen())`), so refreshing in the constructor
  // is effectively "refresh on open". Most-recent-first for the display.
  readonly cloudLog = computed(() =>
    // Copy before reverse so we never mutate the service's array in place.
    [...this.llm.cloudLog()].reverse(),
  );

  /** A short, human-readable timestamp for a log row. Falls back to the raw
   *  string if it isn't a parseable date. */
  formatCallTime(ts: string): string {
    const ms = Date.parse(ts);
    if (Number.isNaN(ms)) return ts;
    return new Date(ms).toLocaleString(undefined, {
      month: 'short',
      day: 'numeric',
      hour: '2-digit',
      minute: '2-digit',
    });
  }

  // ─── Vault ──────────────────────────────────────────────────────────
  readonly vaultPath = this.prefs.vaultPath;

  revealVault(): void {
    this.prefs.revealVault();
  }

  // ─── Dismissal ──────────────────────────────────────────────────────
  @HostListener('document:keydown.escape')
  onEscape(): void {
    this.close.emit();
  }

  onBackdropClick(): void {
    this.close.emit();
  }

  onClose(): void {
    this.close.emit();
  }
}
