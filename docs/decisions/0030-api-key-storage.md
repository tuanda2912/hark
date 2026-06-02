# ADR-0030: LLM API key storage — Electron safeStorage (OS Keychain), main-only (Phase 6)

- **Date:** 2026-06-02
- **Status:** Accepted
- **Deciders:** Dang Anh Tuan

## Context

Cloud LLM providers (ADR-0029) need an API key. The design promises: *"Stored in the macOS
Keychain. Hark never sees your key."* The key is a secret that must be stored securely, **never
exposed to the renderer**, never logged, and never sent anywhere except the provider's own auth
header. We also don't want a native dependency to build/sign if we can avoid it.

## Decision

Use **Electron `safeStorage`** (on macOS this derives its key from the **Keychain**) to encrypt
the API key in the **main process**:

- `safeStorage.encryptString(key)` → store the ciphertext (base64) in **app-data**, in a file
  **separate from `prefs.json`**: `~/Library/Application Support/Hark/llm-keys.json` (secrets
  kept out of the config file). One entry per provider.
- **Decrypt only in main**, only to inject into the provider's `Authorization` / `x-api-key`
  header at call time.
- The renderer can `setApiKey` / `clearApiKey` and query **`hasKey: boolean`**, but can **never
  read the key back** across the bridge. Keys are **never logged** and never persisted in plain
  text.
- If `safeStorage.isEncryptionAvailable()` is false (locked/again unavailable keychain), fail
  gracefully — report "key storage unavailable", don't fall back to plaintext.

## Alternatives considered

- **`keytar`** (native Keychain module). ❌ extra native dependency to build + codesign +
  notarize; `safeStorage` is built into Electron and already uses the Keychain on macOS.
  **Rejected.**
- **Plaintext in `prefs.json`.** ❌ obviously insecure. **Rejected.**
- **A custom Swift Keychain helper in the engine.** ❌ overkill, and pulls a secret into the
  audio-privileged engine process. **Rejected.**

## Consequences

**Positive** — secure at rest, no native dep, renderer-isolated (matches "we never see your
key"), secrets file separate from config.

**Negative / accepted** — `safeStorage` ciphertext is bound to the app's OS-derived key, so a
change in app identity (or a different machine) means re-entering the key; requires the keychain
to be available. App-data location is config-adjacent (rule #2 fine — it's a credential, not
user content, and never enters the vault).

## References

- ADR-0029 (LLM provider layer — what the key authenticates), ADR-0027 (privacy model),
  CLAUDE.md rule #2 (vault-only for content; this is a credential in app-data, not content),
  rule #3 (no exfiltration).
- Design: `Onboarding.jsx` Setup screen ("Stored in macOS Keychain"), `SettingsPrivacy.jsx`.
- `docs/BACKLOG.md` — "Anthropic API key storage (Keychain)" (now active).
