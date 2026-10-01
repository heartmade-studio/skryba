# AGENTS.md — skryba

Public, open-source macOS menu-bar app (Swift 6, SwiftUI + AppKit, no dependencies) for
push-to-talk dictation via Groq Whisper (or Cloudflare Workers AI, with optional local
whisper.cpp). Published under the `heartmade-studio` GitHub org as a showcase, so the code must
stay small, readable, and well commented.

## Build

- `swift build`: compile check (Swift 6 language mode, strict concurrency).
- `swift test`: unit tests (Swift Testing) for the pure logic. Hardware-facing behaviour is covered by
  `docs/manual-tests.md`; update that checklist when you change recording, triggers or pasting.
- CI (`.github/workflows/ci.yml`) runs build, test and bundle assembly on macOS.
- `scripts/build.sh [--install]`: assemble and sign `build/Skryba.app` (optionally install it to
  /Applications and launch it). The app must run as a bundle because it needs `Resources/Info.plist`.
- If `xcode-select` points at the Command Line Tools, the script sets `DEVELOPER_DIR` to Xcode.

## Rules

- **Public repo: never commit secrets.** API keys and tokens live only in the keychain (`Keychain.swift`).
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
- A take lives in `AudioRecorder.directory` while it records. A valid finished take moves to
  `PendingRecordings` before anything is sent, and leaves it once transcribed (an empty or
  hallucinated result counts as transcribed). Failures, offline and cancels keep it there for a
  manual retry from the menu; nothing is re-sent by itself. The queue stays private, out of backups,
  and expires after `PendingRecordings.maximumAge`. A cancelled recording (as opposed to a cancelled
  transcription), a too-short or a silent take is deleted.
- Keep the product simple: one provider (`Settings.provider`: Groq, Cloudflare or local Whisper),
  plus local Whisper as an opt-in fallback for the cloud ones. No primary/fallback matrix, no
  cloud-to-cloud chain. `whisper-cli` starts directly (argv, never a shell). Every wait on the
  network or on whisper-cli must be visible in the HUD and cancellable (`cancelTranscription`).
  All cloud attempts share one deadline (`Retry.attempts`); never give a request its own long timeout.
- Retries from the menu copy the transcript to the clipboard; only a fresh take pastes.
- AI cleanup is optional, and it only removes hesitations and applies the user's `Replacements`. It
  must never lose a dictation: on any error, or a reply that changed anything else
  (`TextCleanup.isAllowed`, run on the final text), paste the plain transcript. Never log
  dictated text; log only the kind of rejection.
- Do not sandbox the app. The App Sandbox blocks the synthetic ⌘V. Distribution: source, plus an
  unnotarized universal DMG attached to each GitHub release (no Apple Developer Program). The DMG
  is built with `scripts/build.sh --dmg`, and the README explains Gatekeeper's "Open Anyway".
  Every version bump gets a release tagged `v<version>`: `UpdateCheck` reads the latest one.
- Signing identity: `Apple Development` auto-detected, or `SKRYBA_SIGN_IDENTITY`. Ad-hoc signing
  resets TCC permissions on every build. Keep that warning in `build.sh` and the README.
- Code, comments, UI strings and docs in English.
