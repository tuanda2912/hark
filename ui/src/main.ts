// Angular renderer bootstrap. The Electron main process loads this
// after building (dev: via ng serve; prod: from dist/renderer/).
import { bootstrapApplication } from '@angular/platform-browser';
import { AppComponent } from './app/app.component';
import { appConfig } from './app/app.config';

bootstrapApplication(AppComponent, appConfig).catch((err) =>
  // eslint-disable-next-line no-console
  console.error('[hark] bootstrap failed:', err),
);
