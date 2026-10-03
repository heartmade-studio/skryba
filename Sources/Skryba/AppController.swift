import AppKit
import AVFoundation
import Observation
import os

/// Orchestrates the dictation loop: key down → record → key up → transcribe → paste.
///
/// One take at a time: `recording → transcribing → pasting → idle`. A new take can't start until the
/// previous one has fully finished, including putting the user's clipboard back.
///
/// A finished take is saved to `PendingRecordings` before it is sent. It leaves the queue once it has
/// been transcribed; if the cloud can't be reached (and local Whisper is off or fails), or the user
/// cancels, it stays there for a manual retry from the menu.
@MainActor @Observable
final class AppController {
    enum Phase: Equatable {
        case idle, transcribing, pasting
        case recording(RecordingMode)
        case error(String)

        var isRecording: Bool {
            if case .recording = self { return true }
            return false
        }
    }

    enum RecordingMode: Equatable {
        /// Recording while the trigger is held.
        case pushToTalk
        /// Recording continues without holding Fn, until Fn is tapped again (entered by a triple tap).
        case handsFree
    }

    private(set) var phase: Phase = .idle
    private(set) var lastTranscript: String?
    /// The transcript before AI cleanup, when cleanup changed it; for comparing and recovering.
    private(set) var lastRawTranscript: String?
    private(set) var hotKeyError: String?
    private(set) var microphoneGranted = false
    private(set) var accessibilityGranted = false
    private(set) var fnKeyFree = FnKey.isFreeForApps

    let settings = Settings()
    let pendingRecordings = PendingRecordings()
    let network = NetworkMonitor()
    let updates = UpdateCheck()

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
    @ObservationIgnored private var fnGesture = FnGesture()
    /// The transcription in flight, so the user can cancel it.
    @ObservationIgnored private var job: Task<Void, Never>?
    /// The AI cleanup in flight, so the user can skip it.
    @ObservationIgnored private var cleanupTask: Task<String, Error>?

    /// Clips shorter than this are treated as accidental taps and never sent.
    private static let minimumClipDuration: TimeInterval = 0.3
    /// Clips with less voice than this are silence (a key click is one ~50 ms window). They are never
    /// sent: on silence Whisper invents text like "Dziękuję za uwagę!".
    private static let minimumVoicedDuration: TimeInterval = 0.2
    /// Recording starts at once, but the HUD and sound wait this long, so quick taps and Fn+key
    /// shortcuts (Fn+⌫, Fn+↑) don't flash anything.
    private static let feedbackDelay: TimeInterval = 0.2
    private static let log = Logger(subsystem: "pl.heartmade.skryba", category: "dictation")
    /// How long AI cleanup may take before the plain transcript is used instead. Thinking models need
    /// ~15 s for a short dictation (Gemma on Cloudflare), more for a long one; the HUD offers Skip.
    static func cleanupDeadline(for text: String) -> Duration {
        .seconds(30 + Double(text.count) / 20)
    }
    /// Hard cap on one take, in case the key-up is never seen.
    static let maximumRecordingDuration: TimeInterval = 5 * 60

    var menuBarSymbol: String {
        switch phase {
        case .idle: pendingRecordings.items.isEmpty ? "waveform" : "tray.full"
        case .recording: "mic.fill"
        case .transcribing, .pasting: "ellipsis.circle"
        case .error: "exclamationmark.triangle"
        }
    }

    private var isBusy: Bool {
        phase.isRecording || phase == .transcribing || phase == .pasting || isTesting
    }

    /// A Settings test is using the microphone.
    private(set) var isTesting = false

    func start() {
        AudioRecorder.removeLeftovers()
        pendingRecordings.load()
        deleteExpiredRecordingsHourly()
        network.onReconnect = { [weak self] in self?.announcePendingRecordings() }
        network.start()
        updates.onNewVersion = { [weak self] version in self?.announceUpdate(version) }
        updates.start { [weak self] in self?.settings.checkForUpdates ?? false }
        hud.onCancel = { [weak self] in self?.cancelTranscription() }
        hotKey.onPress = { [weak self] in self?.startRecording() }
        hotKey.onRelease = { [weak self] in self?.stopRecording() }
        fnKey.onPress = { [weak self] in self?.fnPressed() }
        fnKey.onRelease = { [weak self] in self?.fnReleased() }
        fnKey.onCancel = { [weak self] in self?.cancelRecording() }
        applyTrigger()
        refreshPermissions()
        watchPermissions()

        if !settings.canTranscribe || !microphoneGranted || !accessibilityGranted {
            openSettings()
        }
    }

    /// Called when the app quits: stop the microphone and delete an unfinished take. Saved
    /// recordings stay in `PendingRecordings`.
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
        let handsFree = phase == .recording(.handsFree)
        perform(fnGesture.press(at: ProcessInfo.processInfo.systemUptime, handsFree: handsFree))
    }

    private func fnReleased() {
        perform(fnGesture.release(at: ProcessInfo.processInfo.systemUptime))
    }

    private func perform(_ action: FnGesture.Action) {
        switch action {
        case .start:
            // A press that couldn't record (a take is still transcribing) is no tap of a gesture either.
            if !startRecording() { fnGesture.reset() }
        case .stop:
            stopRecording()
        case .enterHandsFree:
            // The third tap's own take keeps running; it just no longer needs the key.
            guard phase == .recording(.pushToTalk) else { return }
            phase = .recording(.handsFree)
            if feedbackShown { hud.show(.handsFree, note: offlineNote) }
        case .none:
            break
        }
    }

    // MARK: Dictation loop

    /// Returns whether a take started. It doesn't while another take is unfinished or on an error.
    @discardableResult
    private func startRecording() -> Bool {
        // Carbon may repeat "pressed" while the key is held; an unfinished take also blocks a new one.
        guard !isBusy else { return false }
        guard settings.canTranscribe else {
            fail(settings.setupHint)
            openSettings()
            return false
        }
        do {
            try recorder.start()
        } catch {
            fail("Microphone unavailable: \(error.localizedDescription)")
            return false
        }
        let id = UUID()
        take = id
        pasteTarget = PasteTarget.current()
        phase = .recording(.pushToTalk)
        feedbackShown = false
        showFeedback(after: Self.feedbackDelay, for: id)
        watchTrigger(for: id)
        return true
    }

    private func showFeedback(after delay: TimeInterval, for id: UUID) {
        Task {
            try? await Task.sleep(for: .seconds(delay))
            guard take == id, phase.isRecording else { return }
            feedbackShown = true
            hud.show(phase == .recording(.handsFree) ? .handsFree : .recording, note: offlineNote)
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
                guard let self, self.take == id, self.phase.isRecording else { return }
                if ContinuousClock.now - started > .seconds(Self.maximumRecordingDuration) {
                    self.stopRecording()
                    return
                }
                // In hands-free mode the key is up on purpose; only the length cap applies.
                if self.phase == .recording(.handsFree) { continue }
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
        guard phase.isRecording, let clip = recorder.stop() else { return }
        take = UUID() // retire this take's timers
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

        // Saved first, so nothing that happens during the upload can lose it. If saving fails, the
        // take is still transcribed from its temporary file; it just can't wait for a retry.
        let saved: PendingRecordings.Item?
        do {
            saved = try pendingRecordings.keep(clip)
        } catch {
            Self.log.error("could not save the take: \(error.localizedDescription, privacy: .public)")
            saved = nil
        }
        let audio = Audio(
            url: saved?.url ?? clip.url, duration: clip.duration, voicedDuration: clip.voicedDuration, saved: saved
        )
        begin(audio, delivery: .paste(pasteTarget))
    }

    /// Ends a take without sending anything: another key joined the trigger (it was a shortcut, not
    /// dictation), the trigger changed, the user chose Cancel in the menu, or the app is quitting.
    func cancelRecording() {
        // The gesture ends with the take, and even without one: the tap that ended hands-free may be
        // cancelled while Fn is still down. Its release will never be reported, so nothing may wait for it.
        fnGesture.reset()
        guard phase.isRecording else { return }
        take = UUID()
        if let clip = recorder.stop() {
            AudioRecorder.remove(clip.url)
        }
        phase = .idle
        hud.hide()
    }

    // MARK: Transcription

    /// A take on its way to text, either fresh or from the saved queue.
    private struct Audio {
        let url: URL
        let duration: TimeInterval
        let voicedDuration: TimeInterval
        /// Nil when the take couldn't be saved; its temporary file is then deleted afterwards.
        let saved: PendingRecordings.Item?
    }

    /// A fresh take is pasted where it started. A retry from the menu is copied instead: by then the
    /// field it came from is long gone.
    private enum Delivery {
        case paste(PasteTarget?)
        case copy
    }

    /// Why a take wasn't transcribed. In every case a saved recording stays in the queue.
    private enum Stop: Error {
        case cancelled, offline
        case failed(String)
    }

    /// The second HUD line while recording offline, so you know at once what will happen to the take.
    private var offlineNote: String? {
        guard !network.isOnline, settings.provider != .local else { return nil }
        return settings.usesLocalFallback ? "Offline · will transcribe on this Mac" : "Offline · will be saved for later"
    }

    /// Transcribes a saved recording again and copies the text.
    func retry(_ item: PendingRecordings.Item) {
        guard !isBusy, pendingRecordings.items.contains(item) else { return }
        let audio = Audio(url: item.url, duration: item.duration, voicedDuration: item.voicedDuration, saved: item)
        begin(audio, delivery: .copy)
    }

    /// Asks first: the audio is gone for good afterwards.
    func delete(_ item: PendingRecordings.Item) {
        let alert = NSAlert()
        alert.messageText = "Delete this recording?"
        alert.informativeText = "The audio is deleted permanently and can't be transcribed later."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn {
            pendingRecordings.remove(item)
        }
    }

    /// Stops the upload or the local run. The recording stays saved.
    /// During AI cleanup it skips only the cleanup: the plain transcript still goes out.
    func cancelTranscription() {
        guard phase == .transcribing, hud.style?.isCancellable == true else { return }
        if let cleanupTask { cleanupTask.cancel() } else { job?.cancel() }
    }

    private func begin(_ audio: Audio, delivery: Delivery) {
        take = UUID()
        phase = .transcribing
        job = Task { await transcribe(audio, delivery: delivery) }
    }

    private func transcribe(_ audio: Audio, delivery: Delivery) async {
        let vocabulary = Vocabulary(settings.vocabulary)
        let result = await transcript(of: audio, vocabulary: vocabulary)
        job = nil

        var text: String
        switch result {
        case .failure(let stop):
            if audio.saved == nil { AudioRecorder.remove(audio.url) }
            fail(message(for: stop, saved: audio.saved != nil))
            return
        case .success(let transcript):
            // Transcribed, even if to nothing: the audio has done its job.
            if let saved = audio.saved { pendingRecordings.remove(saved) } else { AudioRecorder.remove(audio.url) }
            let invented = Hallucinations.isLikely(
                transcript, prompt: vocabulary.prompt, voicedDuration: audio.voicedDuration
            )
            text = invented ? "" : vocabulary.correct(transcript)
        }

        var cleanupWarning: String?
        let raw = text
        // Cleanup runs at the provider that transcribes. With local Whisper, offline, or without
        // credentials it's skipped, and the plain text goes out.
        if !text.isEmpty, settings.cleanupEnabled, let model = settings.cleanupModel,
           settings.isProviderConfigured, network.isOnline {
            hud.show(.cleaningUp)
            (text, cleanupWarning) = await cleanUp(text, model: model, vocabulary: vocabulary)
        }

        hud.hide()
        guard !text.isEmpty else {
            phase = .idle
            return
        }
        lastTranscript = text
        lastRawTranscript = raw == text ? nil : raw

        switch delivery {
        case .copy:
            Paster.copy(text)
            phase = .idle
            notify(["Copied. Press ⌘V to paste.", cleanupWarning].compactMap(\.self).joined(separator: " "))
        case .paste(let target):
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
    }

    /// Local Whisper when it's the provider. Otherwise the cloud first (unless we know we're offline),
    /// then local Whisper if the user turned it on as a fallback.
    private func transcript(of audio: Audio, vocabulary: Vocabulary) async -> Result<String, Stop> {
        let provider = settings.provider
        if provider == .local {
            return await transcribeLocally(audio, vocabulary: vocabulary)
        }

        var stop = Stop.offline
        if !settings.isProviderConfigured {
            stop = .failed(settings.setupHint)
        } else if network.isOnline {
            do {
                return .success(try await Retry.attempts(
                    within: Retry.deadline(forClipOf: audio.duration),
                    onAttempt: { attempt in
                        hud.show(.transcribing(attempt: attempt))
                        Self.log.info(
                            "cloud transcription request started provider=\(provider.rawValue, privacy: .public) attempt=\(attempt, privacy: .public)"
                        )
                    },
                    onAttemptFailure: { attempt, elapsed, error in
                        Self.log.notice(
                            "cloud transcription request failed provider=\(provider.rawValue, privacy: .public) attempt=\(attempt, privacy: .public) elapsed_ms=\(Retry.milliseconds(elapsed), privacy: .public) reason=\(Retry.failureKind(for: error), privacy: .public)"
                        )
                    },
                    operation: cloudTranscription(of: audio.url, with: provider, vocabulary: vocabulary)
                ))
            } catch where Retry.isCancellation(error) {
                return .failure(.cancelled)
            } catch where Retry.isOffline(error) {
                stop = .offline
            } catch {
                Self.log.notice(
                    "cloud transcription failed provider=\(provider.rawValue, privacy: .public) reason=\(Retry.failureKind(for: error), privacy: .public)"
                )
                stop = .failed(error.localizedDescription)
            }
        }

        guard settings.usesLocalFallback else { return .failure(stop) }
        return await transcribeLocally(audio, vocabulary: vocabulary)
    }

    private func transcribeLocally(_ audio: Audio, vocabulary: Vocabulary) async -> Result<String, Stop> {
        hud.show(.transcribingLocally)
        do {
            let text = try await settings.localWhisper.transcribe(
                fileURL: audio.url, duration: audio.duration, language: settings.language, prompt: vocabulary.prompt
            )
            return .success(text)
        } catch where Retry.isCancellation(error) {
            return .failure(.cancelled)
        } catch {
            Self.log.error("local transcription failed: \(error.localizedDescription, privacy: .public)")
            return .failure(.failed(error.localizedDescription))
        }
    }

    /// One request to a cloud provider, with everything it needs captured up front, so it can run
    /// (and be retried or cancelled) away from the main actor.
    private func cloudTranscription(
        of file: URL, with provider: Settings.TranscriptionProvider, vocabulary: Vocabulary
    ) -> @Sendable () async throws -> String {
        let language = settings.language
        let prompt = vocabulary.prompt
        let groq = GroqClient(apiKey: settings.apiKey)
        let cloudflare = settings.cloudflare
        return {
            switch provider {
            case .groq: try await groq.transcribe(fileURL: file, language: language, prompt: prompt)
            case .cloudflare: try await cloudflare.transcribe(fileURL: file, language: language, prompt: prompt)
            case .local: preconditionFailure("local Whisper is not a cloud provider")
            }
        }
    }

    private func message(for stop: Stop, saved: Bool) -> String {
        let reason = switch stop {
        case .cancelled: "Cancelled."
        case .offline: "You're offline."
        case .failed(let message): message
        }
        return reason + (saved ? " The recording is saved in the Skryba menu." : " The recording couldn't be kept.")
    }

    private func deleteExpiredRecordingsHourly() {
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60 * 60))
                self?.pendingRecordings.deleteExpired()
            }
        }
    }

    // MARK: Settings test

    /// Records a few seconds and transcribes them with one provider, without fallback or saving, to
    /// check a setup. Returns what to show in Settings, including how long the provider took.
    func testTranscription(with provider: Settings.TranscriptionProvider) async -> String {
        guard !isBusy else { return "Finish the current dictation first." }
        isTesting = true
        defer { isTesting = false }
        do {
            try recorder.start()
        } catch {
            return "Microphone unavailable: \(error.localizedDescription)"
        }
        try? await Task.sleep(for: .seconds(Self.testDuration))
        guard let clip = recorder.stop() else { return "The recording failed." }
        defer { AudioRecorder.remove(clip.url) }

        let vocabulary = Vocabulary(settings.vocabulary)
        let started = ContinuousClock.now
        do {
            let text = provider == .local
                ? try await settings.localWhisper.transcribe(
                    fileURL: clip.url, duration: clip.duration, language: settings.language, prompt: vocabulary.prompt
                )
                : try await Retry.attempts(
                    within: Retry.deadline(forClipOf: clip.duration),
                    operation: cloudTranscription(of: clip.url, with: provider, vocabulary: vocabulary)
                )
            let seconds = (ContinuousClock.now - started).formatted(.units(allowed: [.seconds], fractionalPart: .show(length: 1)))
            return text.isEmpty ? "Heard nothing (\(seconds)). Speak while it listens." : "“\(text)” · \(seconds)"
        } catch {
            return error.localizedDescription
        }
    }

    static let testDuration: TimeInterval = 4

    /// A newer version is out: one quiet note, unless a take is in progress. The menu keeps the link.
    private func announceUpdate(_ version: String) {
        guard phase == .idle else { return }
        notify("Skryba \(version) is available. Download it from the Skryba menu.")
    }

    /// After a reconnect, a gentle reminder that recordings are waiting. Nothing is sent by itself.
    private func announcePendingRecordings() {
        let count = pendingRecordings.items.count
        guard count > 0, phase == .idle else { return }
        notify("Back online. \(count == 1 ? "1 recording is" : "\(count) recordings are") waiting in the Skryba menu.")
    }

    /// Returns the cleaned-up text, or `text` unchanged plus a warning if cleanup fails or strays
    /// from it. The dictation itself must never be lost to this optional step.
    private func cleanUp(_ text: String, model: TextCleanup.Model, vocabulary: Vocabulary) async -> (text: String, warning: String?) {
        // One snapshot of the rules, so a change in Settings during the request can't mix them.
        let replacements = Replacements(settings.replacements)
        // Every cleanup model runs at Groq or Cloudflare.
        let client: any ChatClient = model.provider == .groq ? GroqClient(apiKey: settings.apiKey) : settings.cloudflare
        let cleanup = TextCleanup(client: client, model: model)
        let started = ContinuousClock.now
        do {
            // Optional, so it gets little patience: past the limit the plain transcript goes out.
            let language = settings.language
            let task = Task {
                try await Retry.run(
                    { try await cleanup.clean(text, replacements: replacements, language: language) },
                    until: .now + Self.cleanupDeadline(for: text)
                )
            }
            cleanupTask = task
            defer { cleanupTask = nil }
            let reply = try await task.value
            // Judge exactly the text that would be pasted.
            let cleaned = vocabulary.correct(reply)
            guard TextCleanup.isAllowed(original: text, cleaned: cleaned, replacements: replacements) else {
                // Never log the dictated words.
                Self.log.notice("cleanup rejected: reply changed more than allowed")
                return (text, TextCleanup.rejectionMessage)
            }
            return (cleaned, nil)
        } catch where Retry.isCancellation(error) {
            Self.log.notice("cleanup skipped by the user")
            return (text, nil)
        } catch {
            Self.log.error(
                "cleanup failed provider=\(model.provider.rawValue, privacy: .public) elapsed_ms=\(Retry.milliseconds(ContinuousClock.now - started), privacy: .public) reason=\(Retry.failureKind(for: error), privacy: .public)"
            )
            return (text, "AI cleanup skipped. \(error.localizedDescription)")
        }
    }

    /// A short message that isn't an error; it doesn't block a new take.
    private func notify(_ message: String) {
        let style = RecordingHUD.Style.info(message)
        hud.show(style)
        Task {
            try? await Task.sleep(for: .seconds(4))
            if hud.style == style { hud.hide() }
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
