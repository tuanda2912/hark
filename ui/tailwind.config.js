/**
 * Tailwind config — design tokens piped through CSS variables.
 *
 * The actual color values live in src/styles/tokens.css under
 * `[data-theme="dark"]` and `[data-theme="light"]`. Tailwind only knows
 * the var() reference here, so theme switching is a single attribute
 * flip on <html> with zero JS recomputation.
 *
 * Utility class examples:
 *   bg-bg            → background: var(--bg)
 *   text-text-2      → color:      var(--text-2)
 *   border-border-2  → border:     var(--border-2)
 *   bg-accent-soft   → background: var(--accent-soft)
 *
 * See ADR-0010 for the styling rationale.
 */
/** @type {import('tailwindcss').Config} */
module.exports = {
  content: ['./src/**/*.{html,ts}'],
  theme: {
    extend: {
      colors: {
        bg: 'var(--bg)',
        'bg-2': 'var(--bg-2)',
        surface: 'var(--surface)',
        'surface-2': 'var(--surface-2)',
        border: 'var(--border)',
        'border-2': 'var(--border-2)',
        text: 'var(--text)',
        'text-2': 'var(--text-2)',
        'text-3': 'var(--text-3)',
        accent: 'var(--accent)',
        'accent-2': 'var(--accent-2)',
        'accent-soft': 'var(--accent-soft)',
        // Status semantics — shared across themes.
        recording: 'var(--status-recording)',
        warning: 'var(--status-warning)',
        success: 'var(--status-success)',
        cloud: 'var(--status-cloud)',
        // Speaker palette — shared across themes.
        'sp-1': 'var(--sp-1)',
        'sp-2': 'var(--sp-2)',
        'sp-3': 'var(--sp-3)',
        'sp-4': 'var(--sp-4)',
        'sp-5': 'var(--sp-5)',
        'sp-6': 'var(--sp-6)',
      },
      fontFamily: {
        ui: 'var(--font-ui)',
        display: 'var(--font-display)',
        mono: 'var(--font-mono)',
      },
      borderRadius: {
        input: 'var(--r-input)',
        panel: 'var(--r-panel)',
        card: 'var(--r-card)',
        window: 'var(--r-window)',
      },
    },
  },
  plugins: [],
};
