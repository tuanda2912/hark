// ThemeService — applies the user's appearance choice to the document.
//
// The design ships dark + light tokens (styles/tokens.css, keyed by
// `[data-theme]`). This service is the single writer of that attribute on
// <html>: it resolves the user's choice ('system' | 'light' | 'dark') to a
// concrete theme and sets `data-theme`, after which the CSS-variable cascade
// repaints the whole app. 'system' follows the macOS Light/Dark setting via
// `matchMedia('(prefers-color-scheme: dark)')`, and re-resolves live when the
// OS appearance flips.
//
// Local-first note: this is purely a renderer/DOM concern — no IPC, no network,
// no disk. The CHOICE is persisted by PreferencesService (prefs.json); this
// service only reflects it.
//
// Java/Spring analogue: a tiny `@Service` that subscribes to a config signal
// and pushes the derived value into a single side-effecting sink (the DOM).

import { Injectable, effect, inject } from '@angular/core';
import { PreferencesService, ThemeChoice } from './preferences.service';

@Injectable({ providedIn: 'root' })
export class ThemeService {
  private readonly prefs = inject(PreferencesService);

  /** The OS dark-mode query, or null outside a browser (bare unit context).
   *  In the Electron renderer this is always present. */
  private readonly darkQuery: MediaQueryList | null =
    typeof window !== 'undefined' && typeof window.matchMedia === 'function'
      ? window.matchMedia('(prefers-color-scheme: dark)')
      : null;

  constructor() {
    // Apply once synchronously so the very first paint honors the choice
    // (default 'system') without waiting for the async prefs load or the
    // effect's microtask — avoids a flash of the wrong theme.
    this.apply(this.prefs.theme());

    // Re-apply whenever the user's choice changes — crucially, this fires again
    // once the async prefs load resolves with a stored 'light'/'dark'.
    effect(() => this.apply(this.prefs.theme()));

    // Re-apply on OS appearance change. matchMedia is not a signal, so the
    // effect above won't see it; we listen explicitly. Only changes the result
    // while the choice is 'system' (apply() re-reads the current choice).
    this.darkQuery?.addEventListener('change', () =>
      this.apply(this.prefs.theme()),
    );
  }

  /** Resolve `choice` to a concrete theme and write it to <html data-theme>.
   *  'system' → the OS preference (or the app's dark default if matchMedia is
   *  unavailable, matching index.html's initial attribute). */
  private apply(choice: ThemeChoice): void {
    if (typeof document === 'undefined') return;
    const resolved: 'dark' | 'light' =
      choice === 'system'
        ? this.darkQuery
          ? this.darkQuery.matches
            ? 'dark'
            : 'light'
          : 'dark'
        : choice;
    // setAttribute (not dataset.theme) to satisfy noPropertyAccessFromIndexSignature.
    document.documentElement.setAttribute('data-theme', resolved);
  }
}
