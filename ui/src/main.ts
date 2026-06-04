// Angular renderer bootstrap. The Electron main process loads this after
// building (dev: via ng serve; prod: from dist/renderer/).
//
// ── Surface fork (no router) ──
// One bundle, one index.html. The URL HASH picks which surface to bootstrap:
//   • `#tray` → the styled menu-bar popover (TrayPopoverComponent), loaded in
//     the frameless popover BrowserWindow (main/tray-popover.ts).
//   • anything else → the main app shell (AppComponent), as before.
// A hash fork (not @angular/router) keeps the popover a tiny, dependency-free
// surface — it shares the bundle but pulls in none of the main app's services
// (EngineService, prefs, etc.). main/tray-preload.ts gives it the ONLY bridge
// it needs (window.harkTray); it never opens a WebSocket to harkd.
import { bootstrapApplication } from '@angular/platform-browser';
import { provideZoneChangeDetection } from '@angular/core';
import { AppComponent } from './app/app.component';
import { appConfig } from './app/app.config';
import { TrayPopoverComponent } from './app/tray-popover.component';

if (window.location.hash === '#tray') {
  // Mark the document as the TRAY surface so the global stylesheet drops the
  // opaque app background (styles.css `html,body{background:var(--bg)}`) — the
  // popover window is `transparent:true` and the component draws its own card,
  // so html/body must stay see-through or we'd paint a solid rectangle and
  // lose the rounded corners + shadow.
  document.documentElement.setAttribute('data-surface', 'tray');
  // Minimal config for the popover: zone change detection only (its OnPush
  // template + click handlers run inside zone). No EngineService, no prefs —
  // the popover is a dumb view fed by the harkTray IPC bridge.
  bootstrapApplication(TrayPopoverComponent, {
    providers: [provideZoneChangeDetection({ eventCoalescing: true })],
  }).catch((err) =>
    // eslint-disable-next-line no-console
    console.error('[hark] tray bootstrap failed:', err),
  );
} else {
  bootstrapApplication(AppComponent, appConfig).catch((err) =>
    // eslint-disable-next-line no-console
    console.error('[hark] bootstrap failed:', err),
  );
}
