import AVFoundation
import Testing
@testable import Skryba

struct AudioChunksTests {
    @Test(arguments: [30.1, 61.0, 129.5, 300.0])
    func partsStayWithinOneWindowAndCoverTheWholeTake(_ duration: Double) {
        let levels = Array(repeating: Float(0.1), count: Int(ceil(duration / 0.05)))
        let cuts = AudioChunks.boundaries(duration: duration, levels: levels)
        #expect(cuts.first == 0)
        #expect(cuts.last == duration)
        for index in 0..<cuts.count - 1 {
            #expect(cuts[index + 1] > cuts[index])
            #expect(min(duration, cuts[index + 1] + 3) - max(0, cuts[index] - 3) < 30)
        }
    }

    @Test func prefersPausesWithoutLettingALongPauseGrowTheWindow() {
        var levels = Array(repeating: Float(0.1), count: 800)
        // The midpoint is 20 seconds; a quiet interval starts at 19.4 seconds.
        for index in 388...394 { levels[index] = 0 }
        let cuts = AudioChunks.boundaries(duration: 40, levels: levels)
        #expect(cuts[1] > 19.4 && cuts[1] < 19.75)
    }

    @Test func onlySustainedVeryQuietAudioAllowsAnUnpaddedCut() {
        var levels = Array(repeating: Float(0.01), count: 960)
        for index in 478...482 { levels[index] = 0 }
        #expect(!AudioChunks.isQuietBoundary(at: 24, levels: levels))
        for index in 475...485 { levels[index] = 0.000001 }
        #expect(AudioChunks.isQuietBoundary(at: 24, levels: levels))
        levels[480] = 0.00001 // -50 dBFS: could still be quiet speech.
        #expect(!AudioChunks.isQuietBoundary(at: 24, levels: levels))
    }

    @Test func confirmedPauseProducesConsecutiveAudioWithoutOverlap() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("pause.wav")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        do {
            let file = try AVAudioFile(forWriting: source, settings: format.settings)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000))
            buffer.frameLength = buffer.frameCapacity
            let samples = try #require(buffer.floatChannelData?[0])
            for second in 0..<40 {
                for index in 0..<16_000 {
                    samples[index] = (19...20).contains(second) ? 0 : Float(sin(Double(index) * 0.1)) * 0.2
                }
                try file.write(from: buffer)
            }
        }
        let chunks = try AudioChunks.prepare(source)
        defer { chunks.remove() }
        #expect(chunks.parts.count == 2)
        #expect(chunks.parts[1].from == 0)
        var total = 0.0
        for part in chunks.parts {
            let file = try AVAudioFile(forReading: part.url)
            let duration = Double(file.length) / file.processingFormat.sampleRate
            #expect(abs(part.until - duration) < 0.001)
            total += duration
        }
        #expect(abs(total - 40) < 0.001)
    }

    @Test func writesOverlappingWAVsAndRemovesOnlyItsTemporaryCopies() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("take.wav")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        do {
            let file = try AVAudioFile(forWriting: source, settings: format.settings)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000))
            buffer.frameLength = buffer.frameCapacity
            let samples = try #require(buffer.floatChannelData?[0])
            for index in 0..<16_000 { samples[index] = Float(sin(Double(index) * 0.1)) * 0.2 }
            for _ in 0..<65 { try file.write(from: buffer) }
        }
        let chunks = try AudioChunks.prepare(source)
        defer { chunks.remove() }
        #expect(chunks.parts.count == 4)
        var keptDuration = 0.0
        for (index, part) in chunks.parts.enumerated() {
            let file = try AVAudioFile(forReading: part.url)
            let duration = Double(file.length) / file.processingFormat.sampleRate
            #expect(duration < 30)
            #expect(file.fileFormat.commonFormat == .pcmFormatInt16)
            #expect(part.from >= 0 && part.until <= duration + 0.001)
            #expect(index == 0 ? part.from == 0 : part.from == 3)
            keptDuration += part.until - part.from
        }
        #expect(abs(keptDuration - 65) < 0.001)
        chunks.remove()
        #expect(chunks.parts.allSatisfy { !FileManager.default.fileExists(atPath: $0.url.path) })
        #expect(FileManager.default.fileExists(atPath: source.path))
        let short = try AudioChunks.prepare(sourceForShortTake(in: directory, format: format))
        #expect(short.parts.count == 1)
        short.remove()
        #expect(FileManager.default.fileExists(atPath: short.parts[0].url.path))
    }

    private func sourceForShortTake(in directory: URL, format: AVAudioFormat) throws -> URL {
        let url = directory.appendingPathComponent("short.wav")
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000))
        buffer.frameLength = buffer.frameCapacity
        try file.write(from: buffer)
        return url
    }

    @Test func aacChunksContainExactlyTheSameSamplesAsContinuousDecoding() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("take.m4a")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        do {
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1, AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            ]
            let output = try AVAudioFile(forWriting: source, settings: settings,
                                         commonFormat: .pcmFormatFloat32, interleaved: false)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000))
            buffer.frameLength = buffer.frameCapacity
            let samples = try #require(buffer.floatChannelData?[0])
            for second in 0..<51 {
                for index in 0..<16_000 {
                    samples[index] = Float(sin(2 * .pi * Double(220 + second * 17) * Double(index) / 16_000)) * 0.2
                }
                try output.write(from: buffer)
            }
        }
        let input = try AVAudioFile(forReading: source, commonFormat: .pcmFormatFloat32, interleaved: false)
        let reference = try #require(AVAudioPCMBuffer(pcmFormat: input.processingFormat,
                                                     frameCapacity: AVAudioFrameCount(input.length)))
        try input.read(into: reference)
        let original = try #require(reference.floatChannelData?[0])
        let chunks = try AudioChunks.prepare(source)
        defer { chunks.remove() }
        #expect(chunks.parts.count == 3)
        var coreStart = 0.0
        for part in chunks.parts {
            let file = try AVAudioFile(forReading: part.url, commonFormat: .pcmFormatFloat32, interleaved: false)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                      frameCapacity: AVAudioFrameCount(file.length)))
            try file.read(into: buffer)
            let actual = try #require(buffer.floatChannelData?[0])
            let start = Int(((coreStart - part.from) * 16_000).rounded())
            #expect(start >= 0 && start + Int(buffer.frameLength) <= Int(reference.frameLength))
            var largestError: Float = 0
            for index in 0..<Int(buffer.frameLength) {
                largestError = max(largestError, abs(actual[index] - original[start + index]))
            }
            // Only the PCM16 output quantisation may differ; no seek offset or missing samples.
            #expect(largestError < 0.00004)
            coreStart += part.until - part.from
        }
    }
}
