# AGENTS.md — skryba

Public, open-source macOS menu-bar app (Swift 6, SwiftUI + AppKit, no dependencies) for
push-to-talk dictation via Groq Whisper. Published under the `heartmade-studio` GitHub org as a
showcase, so the code must stay small, readable, and well commented.

## Build

- `swift build`: compile check (Swift 6 language mode, strict concurrency).
- `swift test`: unit tests (Swift Testing) for the pure logic. Hardware-facing behaviour is covered by
  `docs/manual-tests.md`; update that checklist when you change recording, triggers or pasting.
- CI (`.github/workflows/ci.yml`) runs build, test and bundle assembly on macOS.
- `scripts/build.sh [--install]`: assemble and sign `build/Skryba.app` (optionally install it to
  /Applications and launch it). The app must run as a bundle because it needs `Resources/Info.plist`.
- If `xcode-select` points at the Command Line Tools, the script sets `DEVELOPER_DIR` to Xcode.

## Rules

- **Public repo: never commit secrets.** The Groq key lives only in the keychain (`Keychain.swift`).
  No `.env` files, no keys in tests or docs.
- No third-party dependencies without a strong reason. The small footprint is the point.
- Keep everything under `@MainActor` unless there's a reason not to. Carbon callbacks arrive on
  the main thread (`MainActor.assumeIsolated`).
- The HUD must stay a non-activating panel. Taking focus would break pasting.
- One take at a time (`AppController.Phase`). Timers and tasks must check the take ID before acting.
- Paste only into the `PasteTarget` (app, window, field) captured at the start of the take; otherwise fall back
  to the clipboard. Never overwrite a clipboard the user changed meanwhile (`Paster.decide`).
- Recordings live only in `AudioRecorder.directory`, and every path out of a take deletes its file.
- AI cleanup is optional and must never lose a dictation: on any error or an unfaithful reply
  (`TextCleanup.isFaithful`), paste the plain transcript.
- Do not sandbox the app. The App Sandbox blocks the synthetic ⌘V. Distribution is source-only
  (no notarization, no Apple Developer Program).
- Signing identity: `Apple Development` auto-detected, or `SKRYBA_SIGN_IDENTITY`. Ad-hoc signing
  resets TCC permissions on every build. Keep that warning in `build.sh` and the README.
- Code, comments, UI strings and docs in English.
