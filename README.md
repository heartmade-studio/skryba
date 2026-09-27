# Skryba

Hold **Fn**, speak, let go: your words appear as text wherever your cursor is.

Skryba (Polish for *scribe*) is a small open-source macOS menu-bar app for push-to-talk dictation.
It records while you hold the Fn (🌐) key, or a shortcut of your choice. It sends the audio to
[Groq](https://groq.com)'s hosted **Whisper large-v3-turbo** model and pastes the transcript into
the text field you were typing in.

Vibe-coded by [Heartmade](https://heartmade.pl/en/) as a readable reference app: no dependencies,
17 Swift files, about 2,000 lines including comments.

**Status: 1.1.** It is used daily on an Apple Silicon Mac with macOS 27. Other setups are
untested, so bug reports are welcome.

## How it works

```
hold Fn      ──► AVAudioRecorder (16 kHz mono AAC, temp file) + level meter
release      ──► discard if the level meter heard no voice
             ──► POST /openai/v1/audio/transcriptions  (Groq, whisper-large-v3-turbo)
             ──► drop text Whisper invents on near-silence, fix vocabulary near misses
             ──► optional: AI cleanup of punctuation and fillers (Groq chat model)
             ──► same app, window and field in focus? clipboard ← text, ⌘V, clipboard restored
```

| File | Role |
|---|---|
| `AppController.swift` | The state machine for one take at a time: idle → recording → transcribing → pasting → idle. It also enforces the 5-minute cap and polls the key state in case a key-up is lost. |
| `FnKey.swift` | Hold-Fn trigger via NSEvent modifier monitors. Pressing any other key while Fn is down (Fn+⌫, Fn+↑) cancels the take. |
| `HotKey.swift` | Alternative custom-shortcut trigger via Carbon `RegisterEventHotKey`, which reports both press and release. |
| `AudioRecorder.swift` | Records to a private temp folder at 16 kHz mono (the rate Whisper uses internally) and meters the level. |
| `GroqClient.swift` | Multipart upload over an ephemeral URL session (nothing cached on disk), then `verbose_json` parsing. |
| `TextCleanup.swift` | Optional AI cleanup: prompt, model settings, and a guard that falls back to the raw transcript if the reply strays from it. |
| `Hallucinations.swift` | Drops stock phrases ("Thanks for watching") and prompt echoes, but only from clips with under 0.8 s of voice. |
| `Vocabulary.swift` | Your list of names, used as Whisper's prompt and to fix near misses afterwards ("Hrtmade" → "Heartmade"), keeping Polish case endings. |
| `PasteTarget.swift` | Remembers the app, window and text field that had focus when the take started, read through the Accessibility API. |
| `Paster.swift` | The paste step: a transient clipboard item, then ⌘V, then your clipboard restored. It refuses if the focus moved, and never overwrites something you copied meanwhile. |
| `RecordingHUD.swift` | A non-activating floating pill, so it never steals focus from the app you're typing in. |
| `Keychain.swift` | Keeps the API key in the macOS keychain, not in files or UserDefaults. |

## Requirements

- macOS 14 Sonoma or later. Apple Silicon is tested; Intel should work but is untested.
- Xcode 16 or later (for the Swift 6 toolchain)
- A Groq API key. The free tier is enough: [console.groq.com/keys](https://console.groq.com/keys)

## Build & install

```bash
git clone https://github.com/heartmade-studio/skryba.git
cd skryba
scripts/build.sh --install
```

This builds `build/Skryba.app`, copies it to `/Applications`, and launches it. On first launch,
Settings opens. Paste your Groq key, click **Save**, and grant two permissions:

- **Microphone**, to record while you hold the trigger.
- **Accessibility**, to see the Fn key while other apps are in front and to send ⌘V. Without it,
  the Fn trigger won't work in other apps. A custom shortcut still works, but the text is only left
  on your clipboard.

Skryba is not notarized, so it's meant to be built from source. If you download a build someone
else made, macOS Gatekeeper will block it.

### Signing (read this, or permissions reset on every rebuild)

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

## Usage

- **Hold Fn**, speak, and **release**. Taps shorter than 0.3 s and takes with no voice are ignored.
  One take can last up to 5 minutes.
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
- Silence detection is a level meter, not speech recognition. Loud background noise can pass it,
  and very quiet speech might not. The measured levels are logged (see Troubleshooting).

## Privacy

Skryba has no servers, accounts, analytics or telemetry. It talks to one endpoint:
`api.groq.com`.

- **What leaves your Mac:** the audio of each take, plus your vocabulary list (sent as Whisper's
  prompt). With AI cleanup on, the transcript and your cleanup instructions also go to a Groq
  chat model. If you put client names in the vocabulary, Groq receives them with every request. Read
  [Groq's privacy policy](https://groq.com/privacy-policy/) if that matters for your use.
- **What stays local:** your settings and vocabulary (in UserDefaults), the API key (in the
  keychain), and the last transcript (in memory only, shown under *Copy last*).
- **Recordings** go to a private temporary folder and are deleted once the request finishes. They
  are also cleared when Skryba quits and at the next launch after a crash. Deleting a file on an SSD
  is not a secure erase.
- **Network:** an ephemeral URL session, so no cookies or HTTP cache are written to disk.
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

Whisper transcribes what it hears, including "yyy", false starts and punctuation guesses. Turn on
**Settings → AI cleanup** to pass each transcript through a Groq chat model: `openai/gpt-oss-120b`
by default, or `qwen/qwen3.8-27b` (preview). It is told to fix punctuation and misheard words and
to remove fillers, stutters and self-corrections, without rewording you.

- **It's a second request**, so dictation takes a little longer. The HUD shows *Cleaning up…*
  while it runs, and request timings are logged (see Troubleshooting).
- **Instructions are editable** in Settings. The defaults are in Polish when your dictation
  language is Polish, otherwise in English. Your vocabulary is appended automatically. Add your
  own typical misrecognitions there (for example *"kloud md" → CLAUDE.md*).
- **It can't lose your dictation.** A language model may answer a dictated question instead of
  correcting it, or add text. Skryba pastes the plain transcript instead, with a note in the HUD,
  in any of these cases: more than half of the words change (fillers don't count), the reply gets
  longer, it adds a vocabulary term you didn't say, or the request fails.
- **Names are left alone.** The default instructions tell the model not to "fix" names and
  foreign words it doesn't know. For names it should spell a particular way, add them to
  Vocabulary.
- **Compare with the original:** after a cleaned-up dictation, **Copy without AI cleanup** in the
  menu gives you the plain transcript. Like *Copy last*, it's kept in memory only.

## Cost

Groq bills whisper-large-v3-turbo at $0.04 per hour of audio, with a 10-second minimum per request
(pricing as of September 2026, so check Groq's site). One thousand short dictations come to about
$0.11.

AI cleanup adds token costs: $0.15/$0.60 per million input/output tokens for GPT-OSS 120B, and
$0.80/$4.00 for Qwen 3.8 27B. A short dictation with the default prompt is roughly 450 tokens in
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

Found a security issue? See [SECURITY.md](SECURITY.md).

## License

MIT, see [LICENSE](LICENSE).
