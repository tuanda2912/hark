// Onboarding — first-run, full-window wizard (Slice 2 of the first-run UX).
//
// Four screens (Trust → Permissions → Privacy → Setup) gated above everything
// on a fresh install (PreferencesService.hasCompletedOnboarding === false). The
// last screen's "Start using Hark" persists the flag and emits `complete`,
// dismissing the overlay for good. The engine warms up in the background
// while the user reads, so the model download is masked behind onboarding.
//
// The Privacy step (ADR-0027) is the informed-consent moment for the two
// sensitive features — Keep audio + Remember speakers — each defaulting OFF.
// The user knowingly opts in here (and can change it later in Settings →
// Privacy). It writes straight through PreferencesService.setPrivacy().
//
// Content is adapted from the design artboard to stay HONEST about what we
// actually ship (see the build brief + ADRs):
//   - Engine label is WhisperKit large-v3-turbo (not whisper.cpp).
//   - Screen 2 is "Two system permissions": Microphone + System Audio
//     Recording. System audio uses Core Audio Process Taps
//     (kTCCServiceAudioCapture, ADR-0011), NOT Screen Recording, and macOS
//     prompts for it lazily at first capture (ADR-0012) — so it's purely
//     informational here, no fake "Grant". The Accessibility/global-hotkeys
//     card is dropped (not built).
//   - Screen 3 shows the FIXED vault path with real writable/git status
//     chips + Reveal in Finder. The folder picker and Anthropic API key
//     field are rendered in the design's layout but DISABLED/deferred —
//     configurable vault path and Keychain key storage are future work, so
//     we never ship inputs that silently do nothing.
//
// Token-only styling, OnPush, signals, @if/@for. No new deps.

import {
  ChangeDetectionStrategy,
  Component,
  HostListener,
  OnInit,
  inject,
  signal,
} from '@angular/core';
import { PreferencesService } from '../services/preferences.service';
import { RipplesComponent } from './ripples.component';

/** macOS Microphone TCC status, narrowed for the badge. Anything we don't
 *  recognise (or running outside Electron) collapses to 'unknown'. */
type MicStatus =
  | 'granted'
  | 'denied'
  | 'restricted'
  | 'not-determined'
  | 'unknown';

@Component({
  selector: 'hark-onboarding',
  standalone: true,
  changeDetection: ChangeDetectionStrategy.OnPush,
  imports: [RipplesComponent],
  templateUrl: './onboarding.component.html',
  styleUrl: './onboarding.component.css',
})
export class OnboardingComponent implements OnInit {
  private readonly prefs = inject(PreferencesService);

  /** Total number of wizard screens (Trust → Permissions → Privacy → Setup). */
  readonly lastStep = 4 as const;

  /** Current screen, 1..4. */
  readonly step = signal<1 | 2 | 3 | 4>(1);

  /** Vault path for the Setup screen (fixed, from main). */
  readonly vaultPath = this.prefs.vaultPath;

  // ─── Privacy step (ADR-0027) ────────────────────────────────────────
  // The two opt-in sensitive features, bound to PreferencesService so a
  // choice made here is the SAME persisted state Settings → Privacy reads.
  // Both default OFF; the user knowingly turns them on.
  readonly keepAudio = this.prefs.keepAudio;
  readonly rememberSpeakers = this.prefs.rememberSpeakers;

  toggleKeepAudio(): void {
    this.prefs.setPrivacy({ keepAudio: !this.keepAudio() });
  }

  toggleRememberSpeakers(): void {
    this.prefs.setPrivacy({ rememberSpeakers: !this.rememberSpeakers() });
  }

  // ─── Vault-search backend (ADR-0033/0034) ───────────────────────────
  // A concise first-run choice: where should Hark search the vault when you
  // Ask across all notes — Hark's built-in on-device index (default, nothing
  // to run) or your own LOCAL retrieval service (configured in detail later in
  // Settings → Vault search). Binds to the SAME persisted state Settings
  // reads/writes; default 'builtin'. Picking external here only records the
  // intent — the endpoint/transport live in Settings to keep onboarding light.
  readonly ragBackend = this.prefs.ragBackend;

  setRagBackend(backend: 'builtin' | 'external'): void {
    this.prefs.setRag({ backend });
  }

  /** Live Microphone permission status for the real badge on screen 2.
   *  'unknown' until the first read resolves (or outside Electron). */
  readonly micStatus = signal<MicStatus>('unknown');
  /** True while askForMediaAccess is in flight, to disable the button. */
  readonly micAsking = signal(false);

  ngOnInit(): void {
    void this.refreshMicStatus();
  }

  /** Read the current mic TCC status from main. No-op-safe outside Electron
   *  (window.hark undefined → stays 'unknown', card reads informational). */
  private async refreshMicStatus(): Promise<void> {
    if (!window.hark?.getMicPermission) return;
    try {
      const s = await window.hark.getMicPermission();
      this.micStatus.set(this.narrow(s));
    } catch {
      this.micStatus.set('unknown');
    }
  }

  private narrow(s: string): MicStatus {
    switch (s) {
      case 'granted':
      case 'denied':
      case 'restricted':
      case 'not-determined':
        return s;
      default:
        return 'unknown';
    }
  }

  /** Fire the macOS Microphone prompt (optional nicety). Only meaningful
   *  when status is not-determined / unknown; once decided macOS resolves
   *  immediately without re-prompting. Re-reads status afterward so the
   *  badge reflects the outcome. */
  async grantMic(): Promise<void> {
    if (!window.hark?.askMicPermission || this.micAsking()) return;
    this.micAsking.set(true);
    try {
      await window.hark.askMicPermission();
    } catch {
      // Swallow — the status re-read below is the source of truth.
    } finally {
      this.micAsking.set(false);
      await this.refreshMicStatus();
    }
  }

  /** True when we have a real "granted" reading — drives the green badge.
   *  Anything else shows the neutral "Not yet" badge + (if actionable) the
   *  Grant button. */
  micGranted(): boolean {
    return this.micStatus() === 'granted';
  }

  /** Whether to offer the in-flow "Grant microphone" button. Only when the
   *  bridge exists AND macOS hasn't already decided — a denied/restricted
   *  user must change it in System Settings, so we don't dangle a button
   *  that would silently no-op. */
  canPromptMic(): boolean {
    return (
      !!window.hark?.askMicPermission && this.micStatus() === 'not-determined'
    );
  }

  /** Helper for the badge label on the mic card. */
  micBadgeLabel(): string {
    switch (this.micStatus()) {
      case 'granted':
        return 'Granted';
      case 'denied':
      case 'restricted':
        return 'Denied — System Settings';
      default:
        // 'not-determined' and 'unknown' both read as "macOS will ask".
        return 'Not yet';
    }
  }

  /** Open the vault folder in Finder (Setup screen). */
  revealVault(): void {
    this.prefs.revealVault();
  }

  // ─── Navigation ─────────────────────────────────────────────────────
  next(): void {
    this.step.update((s) => (s < 4 ? ((s + 1) as 1 | 2 | 3 | 4) : s));
  }

  back(): void {
    this.step.update((s) => (s > 1 ? ((s - 1) as 1 | 2 | 3 | 4) : s));
  }

  /** Finish: persist the flag (PreferencesService.completeOnboarding) and
   *  let the host dismiss the overlay by reacting to hasCompletedOnboarding.
   *  No separate `complete` output is needed — the gate is the signal. */
  finish(): void {
    this.prefs.completeOnboarding();
  }

  /** Enter advances/finishes; Escape is intentionally NOT a dismiss — the
   *  user must make a deliberate choice (there's no "skip onboarding"). */
  @HostListener('document:keydown.enter')
  onEnter(): void {
    if (this.step() === this.lastStep) {
      this.finish();
    } else {
      this.next();
    }
  }
}
