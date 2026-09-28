# AGENTS.md — skryba

Public, open-source macOS menu-bar app (Swift 6, SwiftUI + AppKit, no dependencies) for
push-to-talk dictation via Groq Whisper or local whisper.cpp, with optional Cloudflare Workers AI fallback. Published under the `heartmade-studio` GitHub org as a
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

- **Public repo: never commit secrets.** Groq and Cloudflare tokens live only in the keychain (`Keychain.swift`).
  No `.env` files, no keys in tests or docs.
- No third-party dependencies without a strong reason. The small footprint is the point.
- Keep everything under `@MainActor` unless there's a reason not to. Carbon callbacks arrive on
  the main thread (`MainActor.assumeIsolated`).
- The HUD must stay a non-activating panel. Taking focus would break pasting.
- One take at a time (`AppController.Phase`). Timers and tasks must check the take ID before acting.
- Hands-free is a recording mode (`Phase.recording(.handsFree)`, entered by `FnGesture`), so it ends
  with every exit from recording. `FnGesture` owns all Fn gesture state; every cancel path
  (`cancelRecording`) must reset it, because FnKey reports no release for a cancelled press. The
  key-state watchdog is off in hands-free; only the length cap applies.
- Paste only into the `PasteTarget` (app, window, field) captured at the start of the take; otherwise fall back
  to the clipboard. Never overwrite a clipboard the user changed meanwhile (`Paster.decide`).
- Groq is the default primary; users may choose local `whisper.cpp`. Groq-primary routing may use
  local Whisper and then configured Cloudflare. Local-primary routing stays local unless the user
  explicitly enables cloud fallback; then it may try configured Groq and Cloudflare. Cloudflare
  runs only when enabled and configured. Local transcription invokes `whisper-cli` and `ffmpeg`
  with argv (never a shell), with temporary audio/text files removed after the attempt. Do not add
  a daemon or server for local inference.
- Unfinished/cancelled and invalid short or silent recordings are deleted. Each valid stopped take is
  moved to the private `PendingRecordings` Application Support queue before upload; failed uploads
  remain there across app restarts until a successful transcription or explicit user discard.
  Never retry automatically at launch. Manual retries copy the transcript to the clipboard; they
  never paste into a field from either the original take or the retry menu session.
- AI cleanup is optional, and it only removes hesitations and applies the user's `Replacements`. It
  must never lose a dictation: on any error, or a reply that changed anything else
  (`TextCleanup.isAllowed`, run on the final text), paste the plain transcript. Never log
  dictated text; log only the kind of rejection.
- Do not sandbox the app. The App Sandbox blocks the synthetic ⌘V. Distribution: source, plus an
  unnotarized universal DMG attached to each GitHub release (no Apple Developer Program). The DMG
  is built by hand with `hdiutil`, and the README explains Gatekeeper's "Open Anyway".
- Signing identity: `Apple Development` auto-detected, or `SKRYBA_SIGN_IDENTITY`. Ad-hoc signing
  resets TCC permissions on every build. Keep that warning in `build.sh` and the README.
- Code, comments, UI strings and docs in English.
