import AVFoundation

/// Keep long Groq takes within one Whisper window. Cuts in confirmed silence need no overlap;
/// other cuts keep three seconds of context on both sides and align their shared text.
struct AudioChunks {
    struct Part {
        let url: URL
        /// The interval to keep, relative to this part's audio (excluding its overlap).
        let from: TimeInterval
        let until: TimeInterval
        /// Meter-based speech estimate in the owned core, excluding repeated overlap audio.
        let voicedDuration: TimeInterval
    }

    let parts: [Part]
    private let directory: URL?

    func remove() {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    static func prepare(_ source: URL) throws -> AudioChunks {
        let input = try AVAudioFile(forReading: source, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = input.processingFormat
        let rate = format.sampleRate
        let duration = Double(input.length) / rate
        guard duration > 30 else {
            return AudioChunks(parts: [Part(url: source, from: 0, until: duration, voicedDuration: duration)], directory: nil)
        }

        // Share the recorder's root so launch/quit cleanup also removes copies left by a crash.
        let directory = AudioRecorder.directory
            .appendingPathComponent("chunks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        do {
            // The recorder produces 16 kHz mono. Sampling energy every 50 ms lets us move cuts
            // into pauses; overlap still protects words when someone speaks without pausing.
            guard format.channelCount == 1,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate * 0.05))
            else { throw SkrybaError.recordingFailed }
            var levels: [Float] = []
            while input.framePosition < input.length {
                try Task.checkCancellation()
                try input.read(into: buffer)
                guard buffer.frameLength > 0, let samples = buffer.floatChannelData?[0] else {
                    throw SkrybaError.recordingFailed
                }
                var energy: Float = 0
                for index in 0..<Int(buffer.frameLength) { energy += samples[index] * samples[index] }
                levels.append(energy / Float(buffer.frameLength))
            }

            let cuts = boundaries(duration: duration, levels: levels)
            let quiet = cuts.map { isQuietBoundary(at: $0, levels: levels) }
            var parts: [Part] = []
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: rate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
            ]
            for index in 0..<cuts.count - 1 {
                try Task.checkCancellation()
                let start = max(0, cuts[index] - (quiet[index] ? 0 : 3))
                let end = min(duration, cuts[index + 1] + (quiet[index + 1] ? 0 : 3))
                let url = directory.appendingPathComponent("\(index).wav")
                let output = try AVAudioFile(forWriting: url, settings: settings,
                                             commonFormat: format.commonFormat, interleaved: false)
                input.framePosition = AVAudioFramePosition((start * rate).rounded())
                let lastFrame = min(input.length, AVAudioFramePosition((end * rate).rounded()))
                while input.framePosition < lastFrame {
                    try Task.checkCancellation()
                    let count = AVAudioFrameCount(min(AVAudioFramePosition(buffer.frameCapacity), lastFrame - input.framePosition))
                    try input.read(into: buffer, frameCount: count)
                    guard buffer.frameLength > 0 else { throw SkrybaError.recordingFailed }
                    try output.write(from: buffer)
                }
                let firstWindow = max(0, Int(cuts[index] / 0.05))
                let lastWindow = min(levels.count, Int(cuts[index + 1] / 0.05))
                let voiced = Double(levels[firstWindow..<lastWindow].count { $0 >= 0.0001 }) * 0.05 // -40 dBFS
                parts.append(Part(url: url, from: cuts[index] - start, until: cuts[index + 1] - start, voicedDuration: voiced))
            }
            return AudioChunks(parts: parts, directory: directory)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    /// Require 450 ms below -55 dBFS, well below the recorder's speech threshold. A soft syllable
    /// or a brief dip isn't enough: uncertain cuts must keep their overlap and alignment guard.
    static func isQuietBoundary(at time: TimeInterval, levels: [Float]) -> Bool {
        let center = Int(time / 0.05)
        let lower = center - 4
        let upper = center + 4
        guard lower >= 0, upper < levels.count else { return false }
        return levels[lower...upper].allSatisfy { $0.isFinite && $0 >= 0 && $0 < 0.0000031622777 }
    }

    /// Roughly 20 seconds per part, with cuts moved at most a second toward the quietest 150 ms.
    /// Even with six seconds of overlap, every upload stays below Whisper's 30-second window.
    static func boundaries(duration: TimeInterval, levels: [Float]) -> [TimeInterval] {
        let count = Int(ceil(duration / 20))
        guard count > 1 else { return [0, duration] }
        var cuts: [TimeInterval] = [0]
        for index in 1..<count {
            let ideal = duration * Double(index) / Double(count)
            let lower = max(1, Int((ideal - 1) / 0.05))
            let upper = min(levels.count - 2, Int((ideal + 1) / 0.05))
            guard lower <= upper else { cuts.append(ideal); continue }
            let candidates = lower...upper
            let best = candidates.min { left, right in
                let a = levels[left - 1] + levels[left] + levels[left + 1]
                let b = levels[right - 1] + levels[right] + levels[right + 1]
                return a == b ? abs(Double(left) * 0.05 - ideal) < abs(Double(right) * 0.05 - ideal) : a < b
            }
            cuts.append(best.map { (Double($0) + 0.5) * 0.05 } ?? ideal)
        }
        return cuts + [duration]
    }
}
