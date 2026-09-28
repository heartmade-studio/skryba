# Skryba

Hold **Fn**, speak, let go: your words appear as text wherever your cursor is.

Skryba (Polish for *scribe*) is a small open-source macOS menu-bar app for push-to-talk dictation.
It records while you hold the Fn (🌐) key, or a shortcut of your choice. By default it sends audio
to [Groq](https://groq.com)'s hosted **Whisper large-v3-turbo** model; you can instead use
whisper.cpp locally, or configure Cloudflare Workers AI as an optional fallback. Skryba pastes the
transcript into the text field you were typing in.

Vibe-coded by [Heartmade](https://heartmade.pl/en/) as a readable reference app: no dependencies,
19 Swift files, about 2,200 lines including comments.

**Status: 1.3.** It is used daily on an Apple Silicon Mac with macOS 27. Other setups are
untested, so bug reports are welcome.

## How it works

```
hold Fn      ──► AVAudioRecorder (16 kHz mono AAC, temp file) + level meter
release      ──► discard if the level meter heard no voice
             ──► selected primary: Groq Whisper (default) or local whisper.cpp
             ──► optional fallbacks: local Whisper, then Cloudflare (Groq primary)
                 or cloud providers only after explicit opt-in (local primary)
             ──► drop text Whisper invents on near-silence, fix vocabulary near misses
             ──► optional: AI cleanup of hesitations and your replacements (Groq chat model)
             ──► same app, window and field in focus? clipboard ← text, ⌘V, clipboard restored
```

| File | Role |
|---|---|
| `AppController.swift` | The state machine for one take at a time: idle → recording → transcribing → pasting → idle. It also enforces the 5-minute cap and polls the key state in case a key-up is lost. |
| `FnKey.swift` | Hold-Fn trigger via NSEvent modifier monitors. Pressing any other key while Fn is down (Fn+⌫, Fn+↑) cancels the take. |
| `FnGesture.swift` | Everything a Fn press means, in one place: hold to talk, a triple tap for hands-free, a tap to stop. A cancelled take resets it, so no half-finished gesture outlives it. |
| `HotKey.swift` | Alternative custom-shortcut trigger via Carbon `RegisterEventHotKey`, which reports both press and release. |
| `AudioRecorder.swift` | Records to a private temp folder at 16 kHz mono (the rate Whisper uses internally) and meters the level. |
| `GroqClient.swift` | Multipart upload over an ephemeral URL session (nothing cached on disk), then `verbose_json` parsing. |
| `LocalWhisperTranscriber.swift` | Converts the saved clip to a temporary 16 kHz mono WAV, runs whisper.cpp directly, and removes temporary files. |
| `CloudflareTranscriber.swift` | Optional final Workers AI Whisper fallback. |
| `TextCleanup.swift` | Optional AI cleanup: a fixed prompt, model settings, and a guard that pastes the raw transcript unless the reply only removed hesitations and applied your replacements. |
| `Replacements.swift` | Your rewrite rules for AI cleanup, one per line: "claude md → CLAUDE.md". |
| `Hallucinations.swift` | Drops stock phrases ("Thanks for watching") and prompt echoes, but only from clips with under 0.8 s of voice. |
| `Vocabulary.swift` | Your list of names, used as Whisper's prompt and to fix near misses afterwards ("Hrtmade" → "Heartmade"), keeping Polish case endings. |
| `PasteTarget.swift` | Remembers the app, window and text field that had focus when the take started, read through the Accessibility API. |
| `Paster.swift` | The paste step: a transient clipboard item, then ⌘V, then your clipboard restored. It refuses if the focus moved, and never overwrites something you copied meanwhile. |
| `RecordingHUD.swift` | A non-activating floating pill, so it never steals focus from the app you're typing in. |
| `Keychain.swift` | Keeps the API key in the macOS keychain, not in files or UserDefaults. |

## Requirements

- macOS 14 Sonoma or later. Apple Silicon is tested; Intel should work but is untested.
- A Groq API key if you use Groq: [console.groq.com/keys](https://console.groq.com/keys)
- Local transcription needs `whisper-cli`, `ffmpeg`, and a multilingual Whisper model. Settings includes
  setup links and a copyable assistant prompt. The local runner uses
  [whisper.cpp](https://github.com/ggml-org/whisper.cpp) and the
  [official multilingual model files](https://huggingface.co/ggerganov/whisper.cpp).
- To build from source: Xcode 16 or later (for the Swift 6 toolchain)

## Download

Download [Skryba.dmg](https://github.com/heartmade-studio/skryba/releases/latest/download/Skryba.dmg)
from the [latest release](https://github.com/heartmade-studio/skryba/releases/latest), open it and
drag Skryba into Applications. It is a universal build for Apple Silicon and Intel.

Skryba is not notarized by Apple, so macOS blocks the first launch with *"Apple could not verify
Skryba is free of malware"*. If you trust this build:

1. Click **Done** in that dialog.
2. Open System Settings → Privacy & Security, scroll down to the Skryba message and click
   **Open Anyway**. Confirm with your password.
3. Click **Open Anyway** once more when macOS asks again.

You do this once for each version you download. If you'd rather not bypass Gatekeeper for an app that asks for
Microphone and Accessibility access, read the code and build it yourself instead. Then continue with
[First launch](#first-launch).

## Build from source

```bash
git clone https://github.com/heartmade-studio/skryba.git
cd skryba
scripts/build.sh --install
```

This builds `build/Skryba.app`, copies it to `/Applications`, and launches it.

### Signing your own build (read this, or permissions reset on every rebuild)

macOS ties Microphone, Accessibility and keychain access to an app's code signature. If there is
no signing identity, the build script signs *ad hoc*. An ad-hoc signature changes with every
build, so macOS treats each build as a new app: you re-grant permissions and see keychain prompts
every time.

The fix is free and takes a minute. Open **Xcode → Settings → Accounts**, add your Apple ID, then
click **Manage Certificates… → + → Apple Development**. `build.sh` picks up that identity
automatically.

If the certificate shows up in Xcode but `build.sh` still signs ad hoc, your keychain is missing
Apple's intermediate certificate. Download
[AppleWWDRCAG3.cer](https://www.apple.com/certificateauthority/AppleWWDRCAG3.cer), double-click it,
and rebuild. `security find-identity -v -p codesigning` should then list your identity. To use a
different identity:

```bash
SKRYBA_SIGN_IDENTITY="Your Identity Name" scripts/build.sh
```

## First launch

Settings opens. Groq is the primary provider by default. Paste a Groq key and click **Save**, or
choose **Local Whisper** and configure its executable/model paths in **Transcription**. Cloudflare
Workers AI can be enabled as an optional fallback. Local primary keeps audio on this Mac unless you
explicitly enable cloud fallback. Grant two permissions:

- **Microphone**, to record while you hold the trigger.
- **Accessibility**, to see the Fn key while other apps are in front and to send ⌘V. Without it,
  the Fn trigger won't work in other apps. A custom shortcut still works, but the text is only left
  on your clipboard.

## Usage

- **Hold Fn**, speak, and **release**. Taps shorter than 0.3 s and takes with no voice are ignored.
  One take can last up to 5 minutes.
- **Hands-free:** tap Fn three times quickly (within a second) and keep talking without holding
  anything. Hands-free starts when you let go of the third tap, so two taps and then a hold are
  ordinary push-to-talk. The HUD says *Hands-free · tap Fn to stop*. Tap Fn once to stop and transcribe, or use
  **Cancel recording** in the menu to discard. The 5-minute cap still applies. Hands-free works with
  the Fn trigger only.
- If macOS Dictation is on with its shortcut set to *Press 🌐 twice* (System Settings → Keyboard →
  Dictation), a triple tap starts both dictations. Pick another shortcut for macOS Dictation or
  turn it off.
- For Fn to be free, set **System Settings → Keyboard → Press 🌐 key to → Do Nothing**. Skryba
  warns you in Settings until you do.
- Many third-party keyboards don't send Fn to macOS. In that case, switch **Hold to dictate** to a
  custom shortcut (default ⌃⇧Space). A custom shortcut needs at least one modifier (F-keys may go
  without). macOS 15+ refuses global hotkeys whose only modifiers are ⌥ or ⌥⇧.
- The text is pasted only where you started: the same app, window and text field. If you switch
  apps, windows, browser tabs or chats while it transcribes, the text goes to your clipboard
  instead. If you copy something in that moment, your copy is left alone and the transcript is only
  under **Copy last** in the menu. Some Electron apps don't report their focused field. There,
  only a change of app is detected, so a chat switch inside one app is not.
- **Vocabulary** is a comma-separated list of names and jargon. Whisper treats its prompt as "text
  that came before", so on its own the list is only a soft hint. Skryba therefore also corrects
  near misses after transcription, for terms of five letters or more. It allows one wrong letter,
  or two for terms of eight letters or more.
- **Language:** setting it explicitly (rather than *Auto-detect*) improves accuracy on short clips.
- If transcription fails, Skryba keeps the audio and shows a pending indicator in the menu bar.
  Choose **Retry latest saved recording** or a specific item under **Saved recordings**. Manual
  retries copy the transcript to your clipboard; press ⌘V where you want it. Deleting a saved
  recording asks for confirmation.
- Silence detection is a level meter, not speech recognition. Loud background noise can pass it,
  and very quiet speech might not. The measured levels are logged (see Troubleshooting).

## Privacy

Skryba has no servers, analytics or telemetry. The primary provider is Groq by default, or local
whisper.cpp when selected; Cloudflare Workers AI is an optional fallback configured in
**Settings → Transcription**.

- **What leaves your Mac:** Local whisper.cpp runs on this Mac and uses the selected language (or
  Auto-detect) and vocabulary prompt. No audio is sent to a cloud provider when Local Whisper is
  primary unless you explicitly enable cloud fallback. Groq receives audio and your vocabulary prompt when it is used.
  Cloudflare receives audio and the optional language/vocabulary prompt only when its configured
  fallback runs. With AI cleanup on, the transcript and replacements also go to Groq's chat model.
  If your vocabulary contains client names, the selected cloud provider receives them. Read
  [Groq's privacy policy](https://groq.com/privacy-policy/) and
  [Cloudflare's privacy policy](https://www.cloudflare.com/privacypolicy/) if that matters for your use.
- **What stays local:** provider settings and vocabulary (in UserDefaults), API tokens (in the
  keychain), and the last transcript (in memory only, shown under *Copy last*).
  Local model files and the configured tool paths also stay local. Temporary WAV/transcript files
  created by local inference are removed after each attempt.
- **Recordings** are saved with owner-only file permissions in your private Application Support
  folder before upload. A failed request stays in the menu as a pending recording across restarts;
  Skryba never retries or uploads it automatically. Choose **Retry latest saved recording** when ready,
  or discard it from the menu. A recording is deleted after transcription succeeds or when you
  explicitly discard it. An unfinished take cancelled or interrupted before it stops is discarded.
  Deleting a file on an SSD is not a secure erase.
- **Network:** an ephemeral URL session, so no cookies or HTTP cache are written to disk.
- **Cloudflare usage:** the current Workers Free allowance is 10,000 Neurons/day, and this model
  uses 46.63 Neurons per audio minute (about 214 minutes at the full daily allowance). Availability
  is not guaranteed; Workers Paid usage above the free allocation is billed. Check
  [Cloudflare's current pricing](https://developers.cloudflare.com/workers-ai/platform/pricing/)
  and your account dashboard.
- **Microphone:** it is on only during a take, and macOS shows its orange dot while it is.
- **Accessibility** is a broad permission. Skryba uses it to notice the Fn key, to check which
  window and field have focus, and to send ⌘V. It never reads the content of your fields, and never
  stores or sends the keys you press.
- **Clipboard:** the paste goes through the clipboard as an item marked *transient*, so clipboard
  managers that honour the convention skip it. It's a convention, not a security boundary. When
  pasting isn't possible, the text stays on your clipboard as a normal item.
- The **by Heartmade** links open heartmade.pl with a `utm_source=skryba` tag, and only when you
  click them.

## AI cleanup (optional, off by default)

Whisper transcribes what it hears, including "yyy" and "eee". Turn on **Settings → AI cleanup** to
pass each transcript through a Groq chat model: `openai/gpt-oss-120b` by default, or
`qwen/qwen3.8-27b` (preview). It does two things only:

- **Removes hesitations** such as "yyy", "eee", "hmm".
- **Applies your replacements.** One rule per line in **Replacements**, as you say it → as it should
  be written: `claude md → CLAUDE.md`, `pawel małpa heartmade pl → pawel@heartmade.pl`. The model
  also catches close variants that Whisper spelled differently ("klod md").

Everything else stays as Whisper wrote it: no rewording, no fixed words, no removed filler words
like "no" or "tego".

- **It's a second request**, so dictation takes a little longer. The HUD shows *Cleaning up…*
  while it runs, and request timings are logged (see Troubleshooting).
- **It can't lose your dictation.** A language model may answer a dictated question, reword it or
  drop a word. Skryba compares the reply with the transcript word by word, ignoring punctuation and
  case. Unless the only differences are removed hesitations and replacements that sound like one of
  your rules, it pastes the plain transcript, with a note in the HUD. It does the same if the
  request fails.
- **Compare with the original:** after a cleaned-up dictation, **Copy without AI cleanup** in the
  menu gives you the plain transcript. Like *Copy last*, it's kept in memory only.

## Cost

Groq bills whisper-large-v3-turbo at $0.04 per hour of audio, with a 10-second minimum per request
(pricing as of September 2026, so check Groq's site). One thousand short dictations come to about
$0.11.

AI cleanup adds token costs: $0.15/$0.60 per million input/output tokens for GPT-OSS 120B, and
$0.80/$4.00 for Qwen 3.8 27B. A short dictation is at most about 450 tokens in
and 200 out, which comes to about $0.20 per 1,000 dictations with GPT-OSS and $0.80 with Qwen.
These are estimates; your Groq dashboard shows the real numbers.

## Troubleshooting

- **Nothing pastes, or the Accessibility toggle is on but has no effect.** This usually means an
  old grant belongs to a previous build's signature. Remove Skryba from System Settings → Privacy &
  Security → Accessibility (the **−** button), then grant it again.
- **"Shortcut is already taken."** Another app registered it. Pick a different one.
- **The text comes out in the wrong language.** Set the language explicitly in Settings.
- **Takes are discarded as "No speech detected", or noise gets through.** Watch the logged levels
  and request timings, then open an issue with a few lines:
  ```bash
  log stream --predicate 'subsystem == "pl.heartmade.skryba"' --level info
  ```

## Uninstall

1. In Skryba's Settings, turn off **Launch at login**, clear the API key and click **Save**. Then
   quit Skryba.
2. Delete `/Applications/Skryba.app`.
3. Remove its preferences and caches:
   ```bash
   defaults delete pl.heartmade.skryba
   rm -rf ~/Library/Caches/pl.heartmade.skryba ~/Library/HTTPStorages/pl.heartmade.skryba
   ```
4. Revoke its permissions: in System Settings → Privacy & Security, select Skryba under
   **Microphone** and **Accessibility** and click **−**.

If you skipped step 1, remove the key with
`security delete-generic-password -s pl.heartmade.skryba`.

## Development

```bash
swift build          # compile (Swift 6 language mode)
swift test           # unit tests (Swift Testing)
scripts/build.sh     # assemble and sign build/Skryba.app
scripts/make-icon.sh # regenerate the icons after editing Resources/*.svg
```

You can open `Package.swift` in Xcode to edit the code. Run through `scripts/build.sh` rather than
Xcode's Run button, because the app needs its `Info.plist` (microphone usage string, `LSUIElement`)
inside a real `.app` bundle.

Automated tests cover the pure logic: vocabulary correction and the hallucination filter. The
parts that touch the microphone, keyboard and clipboard are checked by hand with
[docs/manual-tests.md](docs/manual-tests.md). Run through it before a release.

Each release gets a universal, unnotarized `Skryba.dmg` attached. To build it (needs full Xcode for
the second architecture):

```bash
scripts/build.sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"
swift build -c release --arch arm64 --arch x86_64
cp "$BIN/Skryba" build/Skryba.app/Contents/MacOS/
lipo -archs build/Skryba.app/Contents/MacOS/Skryba   # expect: x86_64 arm64
codesign --force --sign "Apple Development" build/Skryba.app
rm -rf build/dmg && mkdir build/dmg && cp -R build/Skryba.app build/dmg/
ln -s /Applications build/dmg/Applications
cp Resources/AppIcon.icns build/dmg/.VolumeIcon.icns
# The volume's custom-icon flag only survives if set on the mounted image, so go through a
# writable copy first.
hdiutil create -volname "Skryba" -srcfolder build/dmg -format UDRW -ov build/Skryba-rw.dmg
mkdir -p build/mnt && hdiutil attach build/Skryba-rw.dmg -nobrowse -mountpoint build/mnt
SetFile -a C build/mnt
rm -rf build/mnt/.fseventsd
hdiutil detach build/mnt
hdiutil convert build/Skryba-rw.dmg -format UDZO -ov -o build/Skryba.dmg
rm build/Skryba-rw.dmg
```

Found a security issue? See [SECURITY.md](SECURITY.md).

## License

MIT, see [LICENSE](LICENSE).
