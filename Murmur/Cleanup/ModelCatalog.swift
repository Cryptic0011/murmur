import Foundation

/// Shared live catalog for hosted cleanup and transcription model pickers.
enum ModelCatalog {
    static func ids(endpoint: URL, apiKey: String, session: URLSession, timeout: TimeInterval = 10) async throws -> [String] {
        guard OpenAICompatibleProvider.isTransportSecure(endpoint) else {
            throw OpenAICompatibleProvider.ProviderError.insecureEndpoint
        }
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = timeout
        if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw OpenAICompatibleProvider.ProviderError.badStatus(
                (response as? HTTPURLResponse)?.statusCode ?? 0, message: nil
            )
        }
        struct Model: Decodable { let id: String; let active: Bool? }
        struct Catalog: Decodable { let data: [Model] }
        return try JSONDecoder().decode(Catalog.self, from: data).data
            .filter { $0.active != false && !$0.id.isEmpty }.map(\.id).sorted()
    }

    static func isTranscription(_ id: String) -> Bool { id.lowercased().contains("whisper") }

    static func isCleanup(_ id: String) -> Bool {
        // ponytail: name-based filtering; use capability metadata when providers expose it consistently.
        !["whisper", "tts", "orpheus", "guard", "embed", "compound", "distil"].contains {
            id.lowercased().contains($0)
        }
    }

    static func replacement(in ids: [String], transcription: Bool = false) -> String? {
        let available = ids.filter { transcription ? isTranscription($0) : isCleanup($0) }
        let preferred = transcription ? ["whisper-large-v3-turbo", "whisper-large-v3"] :
            ["openai/gpt-oss-20b", "gpt-oss-20b", "openai/gpt-oss-120b", "gpt-oss-120b"]
        // Cleanup only switches to a known-good chat model: the first listed id could be a
        // completion-only or pricier model. Every listed Whisper id transcribes.
        return preferred.first(where: available.contains) ?? (transcription ? available.first : nil)
    }

    static func isMissingModel(status: Int, message: String?) -> Bool {
        guard [400, 404, 410].contains(status), let message else { return false }
        let lower = message.lowercased()
        return lower.contains("model") &&
            ["does not exist", "not found", "decommission", "deprecated", "no longer"].contains {
                lower.contains($0)
            }
    }
}
