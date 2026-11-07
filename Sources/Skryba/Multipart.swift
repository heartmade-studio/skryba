import Foundation

/// The multipart/form-data upload that Groq and OpenAI transcription share: text fields, then the
/// audio file. Recordings are AAC in M4A; Groq's long-take parts are PCM WAV.
struct Multipart {
    let boundary = "Skryba-\(UUID().uuidString)"
    private var body = Data()

    var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    mutating func field(_ name: String, _ value: String) {
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
    }

    /// Adds the audio and the closing boundary, and returns the finished body.
    mutating func finish(withAudio file: URL) throws -> Data {
        let wav = file.pathExtension.lowercased() == "wav"
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.\(wav ? "wav" : "m4a")\"\r\n")
        append("Content-Type: \(wav ? "audio/wav" : "audio/mp4")\r\n\r\n")
        body.append(try Data(contentsOf: file))
        append("\r\n--\(boundary)--\r\n")
        return body
    }

    private mutating func append(_ string: String) {
        body.append(Data(string.utf8))
    }
}
