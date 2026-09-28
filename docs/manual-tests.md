# Manual test checklist

The microphone, keyboard, clipboard and focus behaviour can't be unit-tested meaningfully. Run
through this list on a real Mac before tagging a release. Install with `scripts/build.sh --install`
and keep the log open in a terminal:

```bash
log stream --predicate 'subsystem == "pl.heartmade.skryba"' --level info
```

## Dictation

- [ ] Hold Fn, say a sentence, release. The text appears in Notes, in a browser text field, in
      Slack (Electron) and in Terminal.
- [ ] Hold Fn and stay silent for 2 s. You see "No speech detected" and nothing is pasted.
- [ ] Tap Fn quickly (under 0.3 s). Nothing happens: no HUD, no sound.
- [ ] Fn+⌫ deletes forward and Fn+↑ pages up, with no recording, HUD or sound.

## Hands-free (1.2.2)

- [ ] Tap Fn three times quickly. When you let go of the third tap, the HUD says *Hands-free · tap
      Fn to stop*, and recording goes on with no key held. Speak, tap Fn once: the text is
      transcribed and pasted.
- [ ] Tap Fn twice, then hold it to talk. That's normal push-to-talk, not hands-free: releasing
      Fn transcribes.
- [ ] Tap Fn twice, press it a third time and, still holding it, press ↑. Then tap Fn once. The
      mic dot disappears at once (a stale gesture must not keep the mic on).
- [ ] Enter hands-free, **Cancel recording** in the menu, then tap Fn twice quickly. Nothing starts;
      it takes three taps again.
- [ ] Three slow taps (about a second apart) don't start hands-free.
- [ ] In hands-free mode, type on the keyboard. Recording continues, and only an Fn tap stops it.
- [ ] In hands-free mode, **Cancel recording** in the menu discards the take.
- [ ] Switching **Hold to dictate** to a custom shortcut during hands-free stops the recording.
- [ ] With macOS Dictation's shortcut on *Press 🌐 twice*, note what happens (README caveat).
- [ ] Say a vocabulary term ("Heartmade"). It is spelled as in Settings.
- [ ] Say "Dziękuję za uwagę" deliberately. It is pasted, not filtered.

## AI cleanup

- [ ] Turn on AI cleanup and add the replacement `claude md → CLAUDE.md`. Dictate "yyy otwórz plik
      claude md". The HUD shows *Cleaning up…* and "Otwórz plik CLAUDE.md" is pasted.
- [ ] Dictate a question ("jaka jest stolica Francji"). The question is pasted, not an answer.
- [ ] Dictate "no to wyślij to jutro". "no" stays: only hesitations are removed.
- [ ] The log shows `groq chat openai/gpt-oss-120b` with a timing and no `cleanup failed` line.
      Repeat with Qwen.

## Safety

- [ ] Start dictating in Notes, switch to another app while it says "Transcribing…". Nothing is
      pasted, you see "You switched apps…", and the text is on the clipboard.
- [ ] Start dictating in one browser tab, switch tabs while it transcribes. Nothing is pasted.
- [ ] Same with two Notes windows, and with two chats in Slack. Slack may not report its focused
      field; if it pastes, the README's Electron caveat applies.
- [ ] Copy something right after releasing Fn, before the paste. Your copied item is not
      overwritten or pasted, and the transcript is under **Copy last**.
- [ ] Clipboard restore: copy a word, dictate, then ⌘V. Your original word comes back.
- [ ] Hold Fn and change **Hold to dictate** in Settings with the mouse. Recording stops (orange mic
      dot disappears) and nothing is sent.
- [ ] Hold Fn, click into a password field (for example a login form in Safari),
      release Fn. Recording stops within about a second.
- [ ] While recording, open the menu. **Cancel recording** stops the mic without sending anything.
- [ ] Quit Skryba mid-take. The mic dot disappears. At the next launch
      `ls "$TMPDIR/pl.heartmade.skryba"` shows no files (or the folder is missing).
- [ ] Record a valid take while offline. After the request fails, the menu shows one pending
      recording, the menu-bar icon has an orange pending dot, and the notice says the audio is saved
      and can be retried from the menu. Record another take without losing the first.
- [ ] Quit and relaunch while a recording is pending. It remains listed and is not uploaded until
      a retry action is selected. **Saved recordings (N)** shows each take's date/time and duration.
- [ ] With several pending takes, **Retry latest saved recording** selects the newest one. After
      connectivity returns, retry copies the transcript to the clipboard without pasting; press ⌘V
      into the intended field. The clip disappears from the queue after transcription succeeds.
- [ ] In a saved recording submenu, choose **Delete recording…**. Cancel keeps it; confirm deletes
      it, and the pending count and indicator update.

## Settings

- [ ] Enter a wrong API key and Save. Dictation shows "Groq rejected the API key".
- [ ] Save a new key, quit and relaunch. The new key is still there.
- [ ] Switch to a custom shortcut and record ⌃⇧Space. Holding it dictates. ⌥-only shortcuts are
      rejected with a beep.
- [ ] With 🌐 set to anything but "Do Nothing", Settings shows the orange warning, and it disappears
      after changing the setting.
- [ ] **Launch at login** survives a logout.
- [ ] Confirm Groq is primary and Cloudflare fallback is off by default.
- [ ] Choose Local Whisper as primary. With cloud fallback off, confirm the route is local-only even
      when Groq and Cloudflare credentials exist. With cloud fallback explicitly enabled, confirm
      the route may try Groq and then Cloudflare after local failure.
- [ ] With Groq primary, enable local fallback and confirm the route order is Groq → local Whisper
      → configured Cloudflare. Disable local fallback and confirm it is skipped.
- [ ] Configure `whisper-cli`, `ffmpeg`, and the multilingual `ggml-small-q5_1.bin` model paths.
      Settings reports missing tools/model until each path is valid, then reports Ready.
- [ ] Run a short sample in the selected language and in Auto-detect. Confirm the selected language
      is passed to local Whisper and temporary WAV/text files are removed after success and failure.
- [ ] With Local Whisper primary and cloud fallback off, disconnect the network and transcribe.
      Confirm it remains local; no audio/transcript appears in logs or network requests.
- [ ] During a forced provider failure, confirm the HUD changes to “Trying local transcription…”
      or “Trying Cloudflare…” when it advances, then shows only the final saved-recording failure if
      every provider fails.
- [ ] Open **Set up local transcription…**. Confirm the official whisper.cpp and Hugging Face links,
      multilingual model name and SHA-256 are shown. Copy the setup prompt and verify it asks for OS/
      architecture detection, official sources, checksum verification, a private multilingual sample,
      and safe restart guidance without requesting credentials or uploading audio.
- [ ] Enable Cloudflare fallback and enter an Account ID/token. The settings summary says whether
      Cloudflare is enabled and configured; the token is saved in Keychain.
- [ ] Verify the route order is Groq then Cloudflare. Empty or rejected results advance to
      Cloudflare; if every configured provider fails, the audio remains saved for retry.
- [ ] Disable Cloudflare fallback and confirm it is not called even when credentials are present.
- [ ] Save a Cloudflare token and confirm it survives relaunch without appearing in UserDefaults,
      logs, or the UI after saving. Verify the account ID remains in settings.
