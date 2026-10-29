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
- [ ] Say a sentence ending in a vocabulary term, then stay silent for 3 s before releasing. The log
      shows `sent` about 2.5 s shorter than `take`, the last word is intact, and nothing follows it.
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

- [ ] With AI cleanup and local fallback enabled, **Skip cleanup after local fallback** starts on.
      Cause the cloud transcription to fail while macOS still reports a network connection: local
      Whisper transcribes and the text is pasted/copied without *Cleaning up…* or a chat request.
      Turn the option off, restart Skryba, and verify the choice persists. Repeat with a cloud
      transcription failure: cleanup is attempted if connectivity allows it, and failure still
      delivers the raw local transcript. A successful cloud transcription still gets cleanup with
      either switch position. Local Whisper as primary never sends a chat request.
- [ ] Turn on AI cleanup and add the replacement `claude md → CLAUDE.md`. Dictate "yyy otwórz plik
      claude md". The HUD shows *Cleaning up…* and "Otwórz plik CLAUDE.md" is pasted.
- [ ] Dictate a question ("jaka jest stolica Francji"). The question is pasted, not an answer.
- [ ] Dictate "no to wyślij to jutro". "no" stays: only hesitations are removed.
- [ ] The log shows `groq chat openai/gpt-oss-120b` with a timing and no `cleanup failed` line.
      Repeat with Qwen.
- [ ] Switch the provider to Cloudflare: the Model picker lists GPT-OSS 120B, Gemma 4 26B and
      Mistral Small 3.1 24B. Repeat the dictations above with each; the log shows
      `cloudflare chat @cf/…` with a timing. Switch back to Groq: its earlier choice is kept.
- [ ] With Gemma on Cloudflare, click **Skip** while the HUD shows *Cleaning up…*: the plain
      transcript is pasted at once, with no warning, and the log says `cleanup skipped by the user`.
- [ ] Switch the provider to Local Whisper: the Cleanup tab shows no picker and says cleanup needs
      Groq or Cloudflare. A dictation pastes the plain text, with no chat request in the log.

## Safety

- [ ] Start dictating in Notes, switch to another app while it says "Transcribing…". Nothing is
      pasted, you see "You switched apps…", and the text is on the clipboard.
- [ ] Start dictating in one browser tab, switch tabs while it transcribes. Nothing is pasted.
- [ ] Same with two Notes windows, and with two chats in Slack. Slack may not report its focused
      field; if it pastes, the README's Electron caveat applies.
- [ ] Copy something right after releasing Fn, before the paste. Your copied item is not
      overwritten or pasted, and the transcript is under **Copy last**.
- [ ] Clipboard restore: copy a word, dictate, then ⌘V. Your original word comes back.
- [ ] Slow app: copy a word, start a long reply streaming in the Claude app, dictate into its
      prompt twice in a row. Both takes paste the transcript, never the copied word.
- [ ] Unread paste: copy a word, dictate into a field that ignores ⌘V (for example Finder with no
      selection). After about 3 s you see "The app didn’t take the text in time…", and ⌘V gives
      the transcript.
- [ ] Hold Fn and change **Hold to dictate** in Settings with the mouse. Recording stops (orange mic
      dot disappears) and nothing is sent.
- [ ] Hold Fn, click into a password field (for example a login form in Safari),
      release Fn. Recording stops within about a second.
- [ ] While recording, open the menu. **Cancel recording** stops the mic without sending anything.
- [ ] Quit Skryba mid-take. The mic dot disappears. At the next launch
      `ls "$TMPDIR/pl.heartmade.skryba"` shows no files (or the folder is missing).

## HUD layout

- [ ] Trigger a cleanup warning (for example, disable network during cleanup): the full notice, reason included, wraps inside the pill; its × at the upper-right closes it immediately, and typing focus stays in the original app.
- [ ] Show a short HUD state, then cancel a recording. The full “Cancelled. The recording is saved
      in the Skryba menu.” message stays inside the black pill, wraps as needed, and does not
      overlap the app underneath.
- [ ] Show a short state, then start recording while offline. The second-line note appears inside
      the pill without clipping; when it disappears on the next online take, the pill shrinks and
      stays near the bottom centre of the active screen.

## Offline and bad connections

- [ ] With Groq or Cloudflare, choose Settings → General → **Maximum cloud attempts → 1 — no retries**.
      Restart Skryba: the choice stays selected. Stall a request: after about 6 seconds for a short
      take, local fallback starts (if enabled), otherwise the recording stays in the menu.
      Choose 2 and simulate quick connection failures: the HUD says *attempt 2 of 2*, never 3.
      Choose 3: the previous retry behavior remains. With local Whisper, the cloud control is hidden.
- [ ] Turn Wi-Fi off. Hold Fn: the HUD shows *Offline · will be saved for later* under *Listening…*.
      Release: you see "You're offline. The recording is saved…", and the menu-bar icon is a tray.
- [ ] The menu lists the saved recording (time · length). Turn Wi-Fi on: within a few seconds a
      notice says a recording is waiting. Nothing is sent by itself.
- [ ] **Transcribe and copy** in the menu: the text is on the clipboard, the HUD says "Copied", the
      recording disappears from the menu and the icon is the quill again.
- [ ] **Delete…** asks for confirmation; after Delete the recording is gone from the menu and from
      `~/Library/Application Support/Skryba/Pending`.
- [ ] Simulate a stalled connection (Network Link Conditioner, *100% Loss*). Dictate: the HUD shows
      *Transcribing…* with **Cancel**, then *Connection trouble · attempt 2 of 3…*. Click **Cancel**
      in the HUD: the focus stays in your app, and the recording is saved. Repeat with **Cancel
      transcription** in the menu.
- [ ] With a stalled connection and no cancel, a short take gives up within about 12 s and is saved
      (or goes to local Whisper, when that's the fallback).
- [ ] Hold Fn and stay silent or just cough (voice under 0.8 s). Nothing is saved to the menu.
- [ ] Quit Skryba with a saved recording, relaunch: it is still listed and not sent.

## Providers

- [ ] Choose Cloudflare, enter the account ID and a Workers AI token, Save. Dictate a Polish
      sentence: it is pasted. The log shows `cloudflare transcription` with a timing.
- [ ] A wrong Cloudflare token shows "Cloudflare rejected the credentials…" and saves the take.
- [ ] With Cloudflare chosen and AI cleanup on, no Groq key is needed: cleanup goes to Cloudflare.
- [ ] **Test** in Settings → General, for each provider: speak for 4 s; it shows your words and the
      time taken. Write down the Groq and Cloudflare times for a short and a long sentence.
- [ ] Choose **Local Whisper** as the provider with Wi-Fi on: the log shows no network request,
      and the HUD says *Transcribing on this Mac…*.
- [ ] Enable Settings → Offline → local Whisper, choose a model: it says "Ready". With Wi-Fi off,
      dictate: the HUD says *Offline · will transcribe on this Mac*, then *Transcribing on this
      Mac…*, and the text is pasted.
- [ ] During *Transcribing on this Mac…* click **Cancel**: `pgrep whisper-cli` finds nothing, and
      the recording is saved.
- [ ] Point the whisper-cli path at a missing file: Settings shows the warning, and an offline
      take is saved with that message.

## Settings

- [ ] With an Apple Development identity, build the app and inspect `codesign -d -r- build/Skryba.app`:
      the designated requirement includes `anchor apple generic`, the app identifier, the WWDR
      intermediate marker and the Team ID.
- [ ] With Accessibility denied, the Settings link opens Privacy & Security → Accessibility. If an
      old enabled entry does not work, remove it and grant access again; verify paste works afterward.
- [ ] Enter a wrong API key and Save. Dictation shows "Groq rejected the API key".
- [ ] Save a new key, quit and relaunch. The new key is still there.
- [ ] Switch to a custom shortcut and record ⌃⇧Space. Holding it dictates. ⌥-only shortcuts are
      rejected with a beep.
- [ ] With 🌐 set to anything but "Do Nothing", Settings shows the orange warning, and it disappears
      after changing the setting.
- [ ] **Launch at login** survives a logout.
