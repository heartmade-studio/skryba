import AVFoundation
import os

/// A finished recording. The caller owns (and deletes) the file.
struct Clip {
    let url: URL
    let duration: TimeInterval
    /// How long the input was loud enough to be speech.
    let voicedDuration: TimeInterval
}

/// Records the microphone to a temporary AAC file and measures how much of it is voice.
///
/// 16 kHz mono is what Whisper works with internally, so recording at that rate keeps uploads
/// tiny (about 20 KB per 10 seconds) without losing accuracy.
@MainActor
final class AudioRecorder {
    private var recorder: AVAudioRecorder?
    private var meterTask: Task<Void, Never>?
    private var voicedWindows = 0
    private var peakLevel: Float = -160

    private static let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 16_000,
        AVNumberOfChannelsKey: 1,
        AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
    ]

    /// Level meter sampling period.
    private static let meterWindow: TimeInterval = 0.05
    /// Average power (dBFS) above which a window counts as voice. A quiet room on a MacBook mic
    /// sits around -55…-65 dB; speech at normal distance around -30…-15 dB.
    private static let voiceThreshold: Float = -40

    private let log = Logger(subsystem: "pl.heartmade.skryba", category: "audio")

    /// Recordings live only here, inside the per-user temporary directory, and only for one take.
    static let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("pl.heartmade.skryba", isDirectory: true)

    /// Deletes any recording left behind by a crash or force quit. Call at launch and at quit,
    /// when no take can be in flight.
    static func removeLeftovers() {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files {
            remove(file)
        }
    }

    static func remove(_ url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
        } catch CocoaError.fileNoSuchFile {
            // Already gone.
        } catch {
            Logger(subsystem: "pl.heartmade.skryba", category: "audio")
                .error("could not delete recording: \(error.localizedDescription, privacy: .public)")
        }
    }

    func start() throws {
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let url = Self.directory.appendingPathComponent("\(UUID().uuidString).m4a")
        let recorder = try AVAudioRecorder(url: url, settings: Self.settings)
        recorder.isMeteringEnabled = true
        guard recorder.record() else {
            Self.remove(url)
            throw SkrybaError.recordingFailed
        }
        self.recorder = recorder
        voicedWindows = 0
        peakLevel = -160
        meterTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.meterWindow))
                self?.sampleLevel()
            }
        }
    }

    func stop() -> Clip? {
        guard let recorder else { return nil }
        meterTask?.cancel()
        meterTask = nil
        let duration = recorder.currentTime
        recorder.stop()
        self.recorder = nil

        let voiced = Double(voicedWindows) * Self.meterWindow
        log.info("take: \(duration, format: .fixed(precision: 2))s, voiced \(voiced, format: .fixed(precision: 2))s, peak \(self.peakLevel, format: .fixed(precision: 1)) dB")
        return Clip(url: recorder.url, duration: duration, voicedDuration: voiced)
    }

    private func sampleLevel() {
        guard let recorder else { return }
        recorder.updateMeters()
        let level = recorder.averagePower(forChannel: 0)
        peakLevel = max(peakLevel, level)
        if level > Self.voiceThreshold { voicedWindows += 1 }
    }
}
