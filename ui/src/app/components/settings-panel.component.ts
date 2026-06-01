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
// Deliberately scoped: NO theme/redaction/speaker/Q&A controls — those are
// Phase 5/6 and would be dead UI today (per the build brief).
//
// Dismissal: Esc (host keydown), backdrop click, and the close button all
// fire `close`. Clicks inside the card stop-propagate so they don't bubble
// to the backdrop handler.

import {
  ChangeDetectionStrategy,
  Component,
  HostListener,
  computed,
  inject,
  output,
} from '@angular/core';
import { EngineService } from '../services/engine.service';
import { PreferencesService } from '../services/preferences.service';
import { LANGUAGE_CHOICES } from '../services/engine.types';

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
