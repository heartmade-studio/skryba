import Darwin
import Foundation

/// Runs whisper.cpp and ffmpeg directly with argv. No shell or background service is involved.
struct LocalWhisperTranscriber {
    static let timeout: TimeInterval = 10 * 60

    let whisperCLIPath: String
    let ffmpegPath: String
    let modelPath: String

    static func defaultCLIPath() -> String {
        detectedExecutable(named: "whisper-cli") ?? "/opt/homebrew/bin/whisper-cli"
    }

    static func defaultFFmpegPath() -> String {
        detectedExecutable(named: "ffmpeg") ?? "/opt/homebrew/bin/ffmpeg"
    }

    static func defaultModelPath(fileManager: FileManager = .default) -> String {
        let candidates = [
            fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent(".local/share/skryba/models/ggml-small-q5_1.bin"),
            fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Skryba/Models/ggml-small-q5_1.bin"),
        ]
        return candidates.first(where: { fileManager.fileExists(atPath: $0.path) })?.path
            ?? candidates[0].path
    }

    static func preflight(cliPath: String, ffmpegPath: String, modelPath: String) -> String {
        guard resolveExecutable(cliPath) != nil else { return "whisper-cli not found or not executable" }
        guard resolveExecutable(ffmpegPath) != nil else { return "ffmpeg not found or not executable" }
        guard FileManager.default.isReadableFile(atPath: expandedPath(modelPath)) else {
            return "Whisper model file not found or not readable"
        }
        return "Ready · whisper.cpp and model found"
    }

    func transcribe(fileURL: URL, language: String, prompt: String) async throws -> String {
        guard let cliURL = Self.resolveExecutable(whisperCLIPath) else { throw LocalWhisperError.cliUnavailable }
        guard let ffmpegURL = Self.resolveExecutable(ffmpegPath) else { throw LocalWhisperError.ffmpegUnavailable }
        let modelURL = URL(fileURLWithPath: Self.expandedPath(modelPath))
        guard FileManager.default.isReadableFile(atPath: modelURL.path) else { throw LocalWhisperError.modelUnavailable }

        let workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("skryba-local-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workDirectory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: workDirectory) }

        let wavURL = workDirectory.appendingPathComponent("input.wav")
        let outputBase = workDirectory.appendingPathComponent("transcript")
        try await Self.run(
            executable: ffmpegURL,
            arguments: Self.ffmpegArguments(input: fileURL, output: wavURL),
            timeout: 45
        )
        let wavSize = (try? FileManager.default.attributesOfItem(atPath: wavURL.path)[.size] as? NSNumber)?.intValue ?? 0
        guard FileManager.default.isReadableFile(atPath: wavURL.path), wavSize > 44 else {
            throw LocalWhisperError.audioConversionFailed
        }
        try await Self.run(
            executable: cliURL,
            arguments: Self.whisperArguments(
                model: modelURL, audio: wavURL, language: language, prompt: prompt, outputBase: outputBase
            ),
            timeout: Self.timeout
        )

        let transcriptURL = outputBase.appendingPathExtension("txt")
        guard FileManager.default.isReadableFile(atPath: transcriptURL.path) else {
            throw LocalWhisperError.transcriptionFailed
        }
        let transcript = try String(contentsOf: transcriptURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else { throw LocalWhisperError.emptyTranscript }
        return transcript
    }

    static func ffmpegArguments(input: URL, output: URL) -> [String] {
        ["-nostdin", "-v", "error", "-y", "-i", input.path, "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", output.path]
    }

    static func whisperArguments(model: URL, audio: URL, language: String, prompt: String, outputBase: URL) -> [String] {
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

    private static func run(executable: URL, arguments: [String], timeout: TimeInterval) async throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let box = ProcessBox(process)

        try await Task.detached(priority: .utility) {
            do {
                try box.process.run()
                let deadline = Date().addingTimeInterval(timeout)
                while box.process.isRunning {
                    if Date() >= deadline {
                        Self.stop(box.process)
                        throw LocalWhisperError.timedOut
                    }
                    try await Task.sleep(for: .milliseconds(100))
                }
                guard box.process.terminationReason == .exit, box.process.terminationStatus == 0 else {
                    throw LocalWhisperError.processFailed
                }
            } catch {
                if box.process.isRunning { Self.stop(box.process) }
                throw error
            }
        }.value
    }

    private static func stop(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(2)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning {
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
        }
    }

    private static func resolveExecutable(_ configuredPath: String) -> URL? {
        let path = expandedPath(configuredPath)
        if path.contains("/") {
            return FileManager.default.isExecutableFile(atPath: path) ? URL(fileURLWithPath: path) : nil
        }
        for directory in ProcessInfo.processInfo.environment["PATH", default: ""].split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent(path)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    private static func detectedExecutable(named name: String) -> String? {
        ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)"].first {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    }

    private static func expandedPath(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }
}

private final class ProcessBox: @unchecked Sendable {
    let process: Process
    init(_ process: Process) { self.process = process }
}

private enum LocalWhisperError: LocalizedError {
    case cliUnavailable, ffmpegUnavailable, modelUnavailable, audioConversionFailed
    case transcriptionFailed, emptyTranscript, timedOut, processFailed

    var errorDescription: String? {
        switch self {
        case .cliUnavailable: "whisper-cli is missing or not executable."
        case .ffmpegUnavailable: "ffmpeg is missing or not executable."
        case .modelUnavailable: "The local Whisper model is missing or unreadable."
        case .audioConversionFailed: "ffmpeg did not create a valid 16 kHz mono WAV file."
        case .transcriptionFailed: "whisper-cli did not create a transcript file."
        case .emptyTranscript: "whisper-cli returned an empty transcript."
        case .timedOut: "Local transcription exceeded its time limit."
        case .processFailed: "A local transcription tool failed."
        }
    }
}
