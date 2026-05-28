import { ApplicationConfig, provideZoneChangeDetection } from '@angular/core';

export const appConfig: ApplicationConfig = {
  providers: [
    // Zone-based change detection with batched event coalescing. Angular
    // signals are the primary state mechanism (see ADR-0010); zone stays
    // because RxJS streams from the engine service still flow through it.
    provideZoneChangeDetection({ eventCoalescing: true }),
  ],
};
