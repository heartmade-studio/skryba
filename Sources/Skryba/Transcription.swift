/// A transcript together with the path that actually produced it, not just the selected provider.
struct Transcription {
    enum Source {
        case cloud(Settings.TranscriptionProvider)
        case local, localFallback
    }

    let text: String
    let source: Source

    func cleanupModel(using configured: TextCleanup.Model?, skipLocalFallback: Bool) -> TextCleanup.Model? {
        switch source {
        case .local:
            nil // Local as the primary provider never sends text to the cloud.
        case .localFallback:
            skipLocalFallback ? nil : configured
        case .cloud(let provider):
            // Settings may have changed during the upload. Never send text to another cloud.
            configured.flatMap { $0.provider == provider ? $0 : nil }
        }
    }
}
