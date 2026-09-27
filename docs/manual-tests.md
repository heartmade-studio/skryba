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

## Hands-free (1.2)

- [ ] Tap Fn three times quickly. The HUD says *Hands-free · tap Fn to stop*, and recording goes on
      with no key held. Speak, tap Fn once: the text is transcribed and pasted.
- [ ] Tap Fn twice, then hold it to talk. That's normal push-to-talk, not hands-free.
- [ ] Three slow taps (about a second apart) don't start hands-free.
- [ ] In hands-free mode, type on the keyboard. Recording continues, and only an Fn tap stops it.
- [ ] In hands-free mode, **Cancel recording** in the menu discards the take.
- [ ] Switching **Hold to dictate** to a custom shortcut during hands-free stops the recording.
- [ ] With macOS Dictation's shortcut on *Press 🌐 twice*, note what happens (README caveat).
- [ ] Say a vocabulary term ("Heartmade"). It is spelled as in Settings.
- [ ] Say "Dziękuję za uwagę" deliberately. It is pasted, not filtered.

## AI cleanup

- [ ] Turn on AI cleanup. Dictate with a few "yyy" and a self-correction ("do Ani, nie, do Kasi").
      The HUD shows *Cleaning up…* and the pasted text is clean, with no rewording.
- [ ] Dictate a question ("jaka jest stolica Francji"). The question is pasted, not an answer.
- [ ] The log shows `groq chat openai/gpt-oss-120b` with a timing and no `cleanup failed` line.
      Repeat with Qwen.
- [ ] Edit the instructions, then **Reset to default** brings back the default for your language.

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

## Settings

- [ ] Enter a wrong API key and Save. Dictation shows "Groq rejected the API key".
- [ ] Save a new key, quit and relaunch. The new key is still there.
- [ ] Switch to a custom shortcut and record ⌃⇧Space. Holding it dictates. ⌥-only shortcuts are
      rejected with a beep.
- [ ] With 🌐 set to anything but "Do Nothing", Settings shows the orange warning, and it disappears
      after changing the setting.
- [ ] **Launch at login** survives a logout.
