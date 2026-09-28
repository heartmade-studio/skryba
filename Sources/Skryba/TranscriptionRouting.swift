/// The optional Cloudflare route is used only after Groq is absent or has failed, and only when
/// the user enabled it and supplied both required credentials.
enum TranscriptionRoute: String, Equatable {
    case groq
    case localWhisper
    case cloudflare
}

enum TranscriptionProvider: String, CaseIterable, Identifiable {
    case groq
    case localWhisper

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .groq: "Groq Whisper (cloud)"
        case .localWhisper: "Local Whisper (whisper.cpp)"
        }
    }
}

enum TranscriptionRouting {
    /// Sequential provider execution used by production and measurable with injected providers in tests.
    @MainActor
    static func firstSuccessful<Value>(
        routes: [TranscriptionRoute],
        onAttempt: (TranscriptionRoute) -> Void = { _ in },
        onRejectedResult: (TranscriptionRoute) -> Void = { _ in },
        onProviderError: (TranscriptionRoute) -> Void = { _ in },
        operation: (TranscriptionRoute) async throws -> Value,
        accepts: (Value) -> Bool
    ) async -> (route: TranscriptionRoute, value: Value)? {
        for route in routes {
            onAttempt(route)
            do {
                let value = try await operation(route)
                if accepts(value) { return (route, value) }
                onRejectedResult(route)
            } catch {
                onProviderError(route)
                continue
            }
        }
        return nil
    }

    static func providers(
        primary: TranscriptionProvider,
        groqConfigured: Bool,
        localFallbackEnabled: Bool,
        cloudflareEnabled: Bool,
        cloudflareConfigured: Bool,
        allowCloudFallbackWhenLocal: Bool
    ) -> [TranscriptionRoute] {
        let cloudflareAvailable = cloudflareEnabled && cloudflareConfigured
        switch primary {
        case .groq:
            var result: [TranscriptionRoute] = groqConfigured ? [.groq] : []
            if localFallbackEnabled { result.append(.localWhisper) }
            if cloudflareAvailable { result.append(.cloudflare) }
            return result
        case .localWhisper:
            guard allowCloudFallbackWhenLocal else { return [.localWhisper] }
            var result: [TranscriptionRoute] = [.localWhisper]
            if groqConfigured { result.append(.groq) }
            if cloudflareAvailable { result.append(.cloudflare) }
            return result
        }
    }
}
