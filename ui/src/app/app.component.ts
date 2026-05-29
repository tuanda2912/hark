// AppComponent — Phase 4 thin-slice shell. Single window with:
//   - Top bar (REC indicator, controls, RTF readout)
//   - Live transcript list driven by EngineService.segments()
//
// Tray, Q&A panel, Settings, Speaker tagging all land in follow-up
// commits per ADR-0010.

import { ChangeDetectionStrategy, Component, OnInit, inject, signal } from '@angular/core';
import { EngineService } from './services/engine.service';
import { LANGUAGE_CHOICES } from './services/engine.types';

@Component({
  selector: 'hark-root',
  standalone: true,
  templateUrl: './app.component.html',
  styleUrl: './app.component.css',
  changeDetection: ChangeDetectionStrategy.OnPush,
})
export class AppComponent implements OnInit {
  private readonly engine = inject(EngineService);

  readonly connection = this.engine.connection;
  readonly capture = this.engine.capture;
  readonly heartbeat = this.engine.heartbeat;
  readonly hello = this.engine.hello;
  readonly segments = this.engine.segments;
  readonly lastError = this.engine.lastError;

  readonly languageChoices = LANGUAGE_CHOICES;
  /** Currently-selected language code; null = auto-detect. */
  readonly language = signal<string | null>(null);

  ngOnInit(): void {
    void this.engine.connect();
  }

  // ─── Template helpers ───────────────────────────────────────────────

  isCapturing(): boolean {
    return this.capture().kind === 'running';
  }

  isConnected(): boolean {
    return this.connection().kind === 'connected';
  }

  connectionLabel(): string {
    const c = this.connection();
    switch (c.kind) {
      case 'idle': return 'idle';
      case 'connecting': return 'connecting…';
      case 'connected': return 'connected';
      case 'disconnected': return `disconnected (${c.reason})`;
      case 'error': return `error: ${c.message}`;
    }
  }

  rtfDisplay(): string {
    const hb = this.heartbeat();
    if (!hb) return '—';
    return hb.rtf_current.toFixed(2);
  }

  ringFillDisplay(): string {
    const hb = this.heartbeat();
    if (!hb) return '—';
    return `${hb.ring_buffer_fill_sec.toFixed(1)}s`;
  }

  onStart(): void {
    this.engine.clearSegments();
    this.engine.startCapture({ language: this.language() });
  }

  /** Bound to the language `<select>`. Empty string from the DOM
   *  becomes null (auto-detect). */
  onLanguageChange(value: string): void {
    this.language.set(value === '' ? null : value);
  }

  onStop(): void {
    this.engine.stopCapture();
  }

  segmentTrackBy(_index: number, s: { utteranceId: string }): string {
    return s.utteranceId;
  }
}
