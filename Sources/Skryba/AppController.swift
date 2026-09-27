import AppKit
import AVFoundation
import Observation
import os

/// Orchestrates the dictation loop: key down → record → key up → Groq → paste.
///
/// One take at a time: `recording → transcribing → pasting → idle`. A new take can't start until the
/// previous one has fully finished, including putting the user's clipboard back.
@MainActor @Observable
final class AppController {
    enum Phase: Equatable {
        case idle, recording, transcribing, pasting
        case error(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var lastTranscript: String?
    /// The transcript before AI cleanup, when cleanup changed it; for comparing and recovering.
    private(set) var lastRawTranscript: String?
    private(set) var hotKeyError: String?
    private(set) var microphoneGranted = false
    private(set) var accessibilityGranted = false
    private(set) var fnKeyFree = FnKey.isFreeForApps
    /// Recording continues without holding Fn, until Fn is tapped again (entered by a triple tap).
    private(set) var isHandsFree = false

    let settings = Settings()

    @ObservationIgnored private let hotKey = HotKey()
    @ObservationIgnored private let fnKey = FnKey()
    @ObservationIgnored private let recorder = AudioRecorder()
    @ObservationIgnored private let hud = RecordingHUD()
    @ObservationIgnored private let settingsWindow = SettingsWindow()
    /// Identifies the current take, so timers from an earlier take can't act on a newer one.
    @ObservationIgnored private var take = UUID()
    /// Where the take started; the only place its text may be pasted.
    @ObservationIgnored private var pasteTarget: PasteTarget?
    @ObservationIgnored private var feedbackShown = false
    @ObservationIgnored private var tripleTap = TripleTap()
    /// The release that follows the triple tap or the tap ending hands-free mode must not stop anything.
    @ObservationIgnored private var ignoreNextFnRelease = false

    /// Clips shorter than this are treated as accidental taps and never sent.
    private static let minimumClipDuration: TimeInterval = 0.3
    /// Clips with less voice than this are silence (a key click is one ~50 ms window). They are never
    /// sent: on silence Whisper invents text like "Dziękuję za uwagę!".
    private static let minimumVoicedDuration: TimeInterval = 0.2
    /// Recording starts at once, but the HUD and sound wait this long, so quick taps and Fn+key
    /// shortcuts (Fn+⌫, Fn+↑) don't flash anything.
    private static let feedbackDelay: TimeInterval = 0.2
    private static let log = Logger(subsystem: "pl.heartmade.skryba", category: "dictation")
    /// Hard cap on one take, in case the key-up is never seen.
    static let maximumRecordingDuration: TimeInterval = 5 * 60

    var menuBarSymbol: String {
        switch phase {
        case .idle: "waveform"
        case .recording: "mic.fill"
        case .transcribing, .pasting: "ellipsis.circle"
        case .error: "exclamationmark.triangle"
        }
    }

    private var isBusy: Bool {
        phase == .recording || phase == .transcribing || phase == .pasting
    }

    func start() {
        AudioRecorder.removeLeftovers()
        hotKey.onPress = { [weak self] in self?.startRecording() }
        hotKey.onRelease = { [weak self] in self?.stopRecording() }
        fnKey.onPress = { [weak self] in self?.fnPressed() }
        fnKey.onRelease = { [weak self] in self?.fnReleased() }
        fnKey.onCancel = { [weak self] in
            self?.tripleTap.reset()
            self?.cancelRecording()
        }
        applyTrigger()
        refreshPermissions()
        watchPermissions()

        if settings.apiKey.isEmpty || !microphoneGranted || !accessibilityGranted {
            openSettings()
        }
    }

    /// Called when the app quits: stop the microphone and delete any recording.
    func shutdown() {
        cancelRecording()
        AudioRecorder.removeLeftovers()
    }

    func openSettings() {
        settingsWindow.show(controller: self)
    }

    // MARK: Trigger

    var triggerName: String {
        settings.trigger == .fn ? "Fn" : settings.shortcut.displayString
    }

    /// Arms whichever trigger Settings selects and disarms the other.
    func applyTrigger() {
        // The old trigger's key-up will never arrive, so a take in progress must end here.
        cancelRecording()
        switch settings.trigger {
        case .fn:
            hotKey.unregister()
            hotKeyError = nil
            fnKey.start()
        case .shortcut:
            fnKey.stop()
            let shortcut = settings.shortcut
            hotKeyError = hotKey.register(shortcut)
                ? nil
                : "\(shortcut.displayString) is already taken by another app. Pick a different shortcut."
        }
    }

    /// Frees the shortcut while the user records a new one in Settings.
    func suspendHotKey() {
        cancelRecording()
        hotKey.unregister()
    }

    // MARK: Permissions

    func requestMicrophone() {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        } else {
            SystemSettings.open(.microphone)
        }
    }

    func requestAccessibility() {
        Paster.requestAccessibility()
    }

    private func refreshPermissions() {
        microphoneGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        accessibilityGranted = Paster.isTrusted
        fnKeyFree = FnKey.isFreeForApps
    }

    /// None of these post a change notification, so poll while the app runs.
    private func watchPermissions() {
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                self?.refreshPermissions()
            }
        }
    }

    // MARK: Fn: hold to talk, triple-tap for hands-free

    private func fnPressed() {
        if isHandsFree {
            // This tap ends hands-free mode.
            ignoreNextFnRelease = true
            tripleTap.reset()
            stopRecording()
            return
        }
        // Every press starts recording at once, so push-to-talk keeps its first syllable. The two
        // taps before the third are too short to be sent and are discarded as accidental taps.
        let completesTripleTap = tripleTap.press(at: ProcessInfo.processInfo.systemUptime)
        startRecording()
        if completesTripleTap, phase == .recording {
            isHandsFree = true
            ignoreNextFnRelease = true
        }
    }

    private func fnReleased() {
        tripleTap.release(at: ProcessInfo.processInfo.systemUptime)
        if ignoreNextFnRelease {
            ignoreNextFnRelease = false
            return
        }
        stopRecording()
    }

    // MARK: Dictation loop

    private func startRecording() {
        // Carbon may repeat "pressed" while the key is held; an unfinished take also blocks a new one.
        guard !isBusy else { return }
        guard !settings.apiKey.isEmpty else {
            fail("Add your Groq API key in Settings.")
            openSettings()
            return
        }
        do {
            try recorder.start()
        } catch {
            fail("Microphone unavailable: \(error.localizedDescription)")
            return
        }
        let id = UUID()
        take = id
        pasteTarget = PasteTarget.current()
        phase = .recording
        feedbackShown = false
        showFeedback(after: Self.feedbackDelay, for: id)
        watchTrigger(for: id)
    }

    private func showFeedback(after delay: TimeInterval, for id: UUID) {
        Task {
            try? await Task.sleep(for: .seconds(delay))
            guard take == id, phase == .recording else { return }
            feedbackShown = true
            hud.show(isHandsFree ? .handsFree : .recording)
            playSound("Tink")
        }
    }

    /// A backstop for a lost key-up. While a password field has focus, macOS hides key events from
    /// other apps ("secure input"), so the release may never be reported. This polls the physical
    /// key state instead and also enforces the length cap.
    private func watchTrigger(for id: UUID) {
        Task { [weak self] in
            let started = ContinuousClock.now
            var sawHeld = false
            var misses = 0
            while true {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, self.take == id, self.phase == .recording else { return }
                if ContinuousClock.now - started > .seconds(Self.maximumRecordingDuration) {
                    self.stopRecording()
                    return
                }
                // In hands-free mode the key is up on purpose; only the length cap applies.
                if self.isHandsFree { continue }
                if self.isTriggerPhysicallyHeld {
                    sawHeld = true
                    misses = 0
                } else if sawHeld {
                    // Trust the poll only once it has seen the key down, and only after two misses in a row.
                    misses += 1
                    if misses >= 2 {
                        self.stopRecording()
                        return
                    }
                }
            }
        }
    }

    private var isTriggerPhysicallyHeld: Bool {
        switch settings.trigger {
        case .fn:
            CGEventSource.flagsState(.combinedSessionState).contains(.maskSecondaryFn)
        case .shortcut:
            CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(settings.shortcut.keyCode))
        }
    }

    private func stopRecording() {
        guard phase == .recording, let clip = recorder.stop() else { return }
        take = UUID() // retire this take's timers
        isHandsFree = false
        if feedbackShown { playSound("Pop") }

        guard clip.duration >= Self.minimumClipDuration else {
            AudioRecorder.remove(clip.url)
            phase = .idle
            hud.hide()
            return
        }
        guard clip.voicedDuration >= Self.minimumVoicedDuration else {
            AudioRecorder.remove(clip.url)
            fail("No speech detected.")
            return
        }

        phase = .transcribing
        hud.show(.transcribing)
        let target = pasteTarget
        Task { await transcribe(clip, pasteInto: target) }
    }

    /// Ends a take without sending anything: another key joined the trigger (it was a shortcut, not
    /// dictation), the trigger changed, the user chose Cancel in the menu, or the app is quitting.
    func cancelRecording() {
        guard phase == .recording else { return }
        take = UUID()
        isHandsFree = false
        if let clip = recorder.stop() {
            AudioRecorder.remove(clip.url)
        }
        phase = .idle
        hud.hide()
    }

    private func transcribe(_ clip: Clip, pasteInto target: PasteTarget?) async {
        defer { AudioRecorder.remove(clip.url) }
        var text: String
        let vocabulary = Vocabulary(settings.vocabulary)
        do {
            let transcript = try await GroqClient(apiKey: settings.apiKey).transcribe(
                fileURL: clip.url,
                language: settings.language,
                prompt: vocabulary.prompt
            )
            let invented = Hallucinations.isLikely(
                transcript, prompt: vocabulary.prompt, voicedDuration: clip.voicedDuration
            )
            text = invented ? "" : vocabulary.correct(transcript)
        } catch {
            fail(error.localizedDescription)
            return
        }

        var cleanupWarning: String?
        let raw = text
        if !text.isEmpty, settings.cleanupEnabled {
            hud.show(.cleaningUp)
            (text, cleanupWarning) = await cleanUp(text, vocabulary: vocabulary)
        }

        hud.hide()
        guard !text.isEmpty else {
            phase = .idle
            return
        }
        lastTranscript = text
        lastRawTranscript = raw == text ? nil : raw
        phase = .pasting
        let outcome = await Paster.paste(text, into: target)
        phase = .idle
        if case .notPasted(let message) = outcome {
            fail(message)
        } else if let cleanupWarning {
            // The dictation still arrived; say why it wasn't cleaned up rather than fail silently.
            fail(cleanupWarning)
        }
    }

    /// Returns the cleaned-up text, or `text` unchanged plus a warning if cleanup fails or strays
    /// from it. The dictation itself must never be lost to this optional step.
    private func cleanUp(_ text: String, vocabulary: Vocabulary) async -> (text: String, warning: String?) {
        let cleanup = TextCleanup(client: GroqClient(apiKey: settings.apiKey), model: settings.cleanupModel)
        do {
            let cleaned = try await cleanup.clean(
                text, instructions: settings.cleanupInstructions, vocabulary: vocabulary, language: settings.language
            )
            guard TextCleanup.isFaithful(original: text, cleaned: cleaned) else {
                Self.log.notice("cleanup rejected: reply strayed from the transcript")
                return (text, "AI cleanup changed too much, so the plain transcript was pasted.")
            }
            guard !TextCleanup.insertsVocabulary(original: text, cleaned: cleaned, vocabulary: vocabulary) else {
                Self.log.notice("cleanup rejected: reply added a vocabulary term that wasn't spoken")
                return (text, "AI cleanup added a word you didn't say, so the plain transcript was pasted.")
            }
            return (vocabulary.correct(cleaned), nil)
        } catch {
            Self.log.error("cleanup failed: \(error.localizedDescription, privacy: .public)")
            return (text, "AI cleanup skipped. \(error.localizedDescription)")
        }
    }

    private func fail(_ message: String) {
        let failure = Phase.error(message)
        phase = failure
        hud.show(.error(message))
        Task {
            try? await Task.sleep(for: .seconds(4))
            if phase == failure {
                phase = .idle
                hud.hide()
            }
        }
    }

    private func playSound(_ name: String) {
        guard settings.playSounds else { return }
        NSSound(named: name)?.play()
    }
}

enum SystemSettings {
    enum Pane: String {
        case microphone = "com.apple.preference.security?Privacy_Microphone"
        case accessibility = "com.apple.preference.security?Privacy_Accessibility"
        case keyboard = "com.apple.Keyboard-Settings.extension"
    }

    static func open(_ pane: Pane) {
        if let url = URL(string: "x-apple.systempreferences:\(pane.rawValue)") {
            NSWorkspace.shared.open(url)
        }
    }
}
