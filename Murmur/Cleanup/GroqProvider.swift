import Foundation

actor GroqProvider: CleanupProvider {
    nonisolated let displayName = "Groq"

    enum GroqError: Error { case badStatus(Int), missingAPIKey, decodeFailed }

    private let apiKey: String
    private let model: String
    private let timeout: TimeInterval
    private let urlSession: URLSession

    init(apiKey: String, model: String, timeout: TimeInterval = 5.0) {
        self.apiKey = apiKey
        self.model = model
        self.timeout = timeout
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = timeout
        self.urlSession = URLSession(configuration: cfg)
    }

    func clean(text: String, mode: CleanupMode) async throws -> String {
        guard !apiKey.isEmpty else { throw GroqError.missingAPIKey }

        let client = OpenAICompatibleChatClient(
            endpoint: URL(string: "https://api.groq.com/openai/v1/chat/completions")!,
            bearerToken: apiKey,
            session: urlSession
        )

        let content: String
        do {
            content = try await client.cleanupRequest(
                model: model,
                temperature: 0.2,
                messages: [
                    .init(role: "system", content: PromptBuilder.systemPrompt(for: mode)),
                    .init(role: "user", content: "<transcript>\n\(text)\n</transcript>"),
                    .init(role: "assistant", content: PromptBuilder.assistantPrefill),
                ]
            )
        } catch OpenAICompatibleChatClient.ClientError.badStatus(let code) {
            throw GroqError.badStatus(code)
        } catch OpenAICompatibleChatClient.ClientError.decodeFailed {
            throw GroqError.decodeFailed
        }

        let unwrapped = CleanupOutputGuard.unwrapTags(content)
        guard let sanitized = CleanupOutputGuard.sanitize(candidate: unwrapped, original: text, mode: mode) else {
            throw GroqError.decodeFailed
        }
        return sanitized
    }

    func warmUp() async {
        var req = URLRequest(url: URL(string: "https://api.groq.com/openai/v1/models")!)
        req.httpMethod = "GET"
        req.timeoutInterval = 3
        if !apiKey.isEmpty {
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        _ = try? await urlSession.data(for: req)
    }
}

extension GroqProvider: WarmableCleanupProvider {}
