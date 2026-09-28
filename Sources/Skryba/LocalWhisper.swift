import AVFoundation
import Foundation

/// Optional offline transcription with whisper.cpp's `whisper-cli`, for when the cloud can't be reached.
///
/// Skryba ships no model and runs nothing in the background: the user installs whisper.cpp, downloads a
/// model and points Settings at both. The tool is started directly (never through a shell) and is
/// stopped when the take is cancelled or runs too long.
struct LocalWhisper {
    let executablePath: String
    let modelPath: String

    /// Where Homebrew puts `whisper-cli`, tried when the path in Settings is empty.
    static let defaultExecutablePaths = ["/opt/homebrew/bin/whisper-cli", "/usr/local/bin/whisper-cli"]

    enum Failure: LocalizedError, Equatable {
        case executableMissing, modelMissing, unsupportedAudio, timedOut, failed(Int32)

        var errorDescription: String? {
            switch self {
            case .executableMissing: "whisper-cli wasn't found. Check the path in Settings → Offline."
            case .modelMissing: "The Whisper model file wasn't found. Check the path in Settings → Offline."
            case .unsupportedAudio: "The recording couldn't be converted for whisper.cpp."
            case .timedOut: "Local transcription took too long."
            case .failed(let status): "whisper-cli failed (exit code \(status))."
            }
        }
    }

    /// The executable to run: the configured path, or Homebrew's when none is set.
    var executableURL: URL? {
        let configured = (executablePath as NSString).expandingTildeInPath
        let candidates = configured.isEmpty ? Self.defaultExecutablePaths : [configured]
        return candidates.first(where: FileManager.default.isExecutableFile(atPath:)).map(URL.init(fileURLWithPath:))
    }

    var modelURL: URL? {
        let path = (modelPath as NSString).expandingTildeInPath
        guard !path.isEmpty, FileManager.default.isReadableFile(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// Checks the setup without running anything; nil means ready.
    var setupProblem: Failure? {
        if executableURL == nil { return .executableMissing }
        if modelURL == nil { return .modelMissing }
        return nil
    }

    func transcribe(fileURL: URL, duration: TimeInterval, language: String, prompt: String) async throws -> String {
        guard let executable = executableURL else { throw Failure.executableMissing }
        guard let model = modelURL else { throw Failure.modelMissing }

        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("pl.heartmade.skryba-local-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: work) }

        let wav = work.appendingPathComponent("audio.wav")
        let output = work.appendingPathComponent("transcript")
        try Self.convertToWAV(fileURL, to: wav)
        try await Self.run(
            executable,
            arguments: Self.arguments(model: model, audio: wav, language: language, prompt: prompt, outputBase: output),
            timeout: Self.timeout(forClipOf: duration)
        )
        let text = try String(contentsOf: output.appendingPathExtension("txt"), encoding: .utf8)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Long enough for a slow Mac to transcribe the clip, short enough not to hold the next take hostage.
    static func timeout(forClipOf duration: TimeInterval) -> Duration {
        .seconds(max(30, 3 * duration))
    }

    static func arguments(model: URL, audio: URL, language: String, prompt: String, outputBase: URL) -> [String] {
        var arguments = [
            "--model", model.path,
            "--file", audio.path,
            "--language", language.isEmpty ? "auto" : language,
            "--output-txt", "--output-file", outputBase.path,
            "--no-prints",
        ]
        if !prompt.isEmpty { arguments += ["--prompt", prompt] }
        return arguments
    }

    /// whisper.cpp reads WAV but not AAC, so the 16 kHz mono recording is rewritten as 16-bit PCM.
    /// AVFoundation does it in-process, which spares the user installing ffmpeg.
    static func convertToWAV(_ source: URL, to destination: URL) throws {
        let input = try AVAudioFile(forReading: source)
        let format = input.processingFormat
        // whisper.cpp needs exactly 16 kHz mono, which is what `AudioRecorder` records.
        guard format.sampleRate == 16_000, format.channelCount == 1 else { throw Failure.unsupportedAudio }
        let output = try AVAudioFile(
            forWriting: destination,
            settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
            ],
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000) else {
            throw Failure.unsupportedAudio
        }
        while input.framePosition < input.length {
            try input.read(into: buffer)
            if buffer.frameLength == 0 { break }
            try output.write(from: buffer)
        }
    }

    /// Runs the tool and waits for it without blocking a thread. Cancelling the task, or the timeout,
    /// terminates the process.
    private static func run(_ executable: URL, arguments: [String], timeout: Duration) async throws {
        let process = RunningProcess(executable: executable, arguments: arguments)
        let timer = Task {
            try await Task.sleep(for: timeout)
            process.stop(timedOut: true)
        }
        defer { timer.cancel() }

        let status = try await withTaskCancellationHandler {
            try await process.run()
        } onCancel: {
            process.stop(timedOut: false)
        }
        try Task.checkCancellation()
        if process.timedOut { throw Failure.timedOut }
        guard status == 0 else { throw Failure.failed(status) }
    }
}

/// A child process that can be stopped from any thread. `Process` isn't `Sendable`, so a lock
/// guards the state shared by the waiting task, the timer and the cancellation handler.
private final class RunningProcess: @unchecked Sendable {
    private let process = Process()
    private let lock = NSLock()
    private var stopped = false
    private var didTimeOut = false

    init(executable: URL, arguments: [String]) {
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
    }

    var timedOut: Bool { lock.withLock { didTimeOut } }

    /// Starts the process and returns its exit status.
    func run() async throws -> Int32 {
        try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try lock.withLock {
                    // Stopped before it started (a cancel right away): don't start it at all.
                    guard !stopped else { throw CancellationError() }
                    try process.run()
                }
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
    }

    func stop(timedOut: Bool) {
        lock.withLock {
            guard !stopped else { return }
            stopped = true
            didTimeOut = timedOut
            if process.isRunning { process.terminate() }
        }
    }
}
