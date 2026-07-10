import Foundation

/// One provider for every OpenAI-compatible chat-completions cleanup backend
/// (Groq, Cerebras) — they differ only by endpoint and display name.
actor OpenAICompatibleProvider: CleanupProvider {
    nonisolated let displayName: String

    enum ProviderError: Error, LocalizedError, Equatable {
        case badStatus(Int, message: String?)
        case missingAPIKey
        case insecureEndpoint
        case decodeFailed
        case rejectedByGuard

        var errorDescription: String? {
            switch self {
            case let .badStatus(code, message):
                if let message, !message.isEmpty { return "\(message) (HTTP \(code))" }
                return "Cleanup API returned HTTP \(code)."
            case .missingAPIKey: return "No API key is saved for this provider."
            case .insecureEndpoint:
                return "Remote custom endpoints must use HTTPS. Plain HTTP is allowed only for localhost."
            case .decodeFailed: return "Cleanup API returned an unreadable response."
            case .rejectedByGuard: return "Cleanup output failed validation."
            }
        }
    }

    private let chatEndpoint: URL
    private let modelsEndpoint: URL
    private let apiKey: String
    private let model: String
    private let requiresKey: Bool
    private let urlSession: URLSession

    init(
        displayName: String,
        chatEndpoint: URL,
        modelsEndpoint: URL,
        apiKey: String,
        model: String,
        requiresKey: Bool = true,
        timeout: TimeInterval = 5.0
    ) {
        self.displayName = displayName
        self.chatEndpoint = chatEndpoint
        self.modelsEndpoint = modelsEndpoint
        self.apiKey = apiKey
        self.model = model
        self.requiresKey = requiresKey
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = timeout
        self.urlSession = URLSession(configuration: cfg)
    }

    static func groq(apiKey: String, model: String) -> OpenAICompatibleProvider {
        OpenAICompatibleProvider(
            displayName: "Groq",
            chatEndpoint: URL(string: "https://api.groq.com/openai/v1/chat/completions")!,
            modelsEndpoint: URL(string: "https://api.groq.com/openai/v1/models")!,
            apiKey: apiKey,
            model: model
        )
    }

    static func cerebras(apiKey: String, model: String) -> OpenAICompatibleProvider {
        OpenAICompatibleProvider(
            displayName: "Cerebras",
            chatEndpoint: URL(string: "https://api.cerebras.ai/v1/chat/completions")!,
            modelsEndpoint: URL(string: "https://api.cerebras.ai/v1/models")!,
            apiKey: apiKey,
            model: model
        )
    }

    /// Any OpenAI-compatible server the user points at: LM Studio, OpenRouter,
    /// llama.cpp, LiteLLM, together.ai, … Local servers often need no key.
    static func custom(apiKey: String, baseURL: String, model: String) -> OpenAICompatibleProvider {
        var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        let root = URL(string: base) ?? URL(string: "http://localhost:1234/v1")!
        return OpenAICompatibleProvider(
            displayName: "Custom endpoint",
            chatEndpoint: root.appendingPathComponent("chat/completions"),
            modelsEndpoint: root.appendingPathComponent("models"),
            apiKey: apiKey,
            model: model,
            requiresKey: false,
            timeout: 15.0 // local servers on modest hardware are slower than Groq/Cerebras
        )
    }

    func clean(text: String, mode: CleanupMode, context: CleanupContext) async throws -> String {
        guard !apiKey.isEmpty || !requiresKey else { throw ProviderError.missingAPIKey }
        guard Self.isTransportSecure(chatEndpoint) else { throw ProviderError.insecureEndpoint }

        let client = OpenAICompatibleChatClient(
            endpoint: chatEndpoint,
            bearerToken: apiKey,
            session: urlSession
        )

        // Cleanup output is roughly input-sized; a bounded generation makes a
        // runaway model fail fast instead of streaming until the timeout.
        let wordCount = text.split(whereSeparator: \.isWhitespace).count
        let maxTokens = max(256, wordCount * 4)

        let content: String
        do {
            content = try await client.cleanupRequest(
                model: model,
                temperature: 0.2,
                messages: [
                    .init(role: "system", content: PromptBuilder.systemPrompt(for: mode, context: context)),
                    .init(role: "user", content: PromptBuilder.transcriptMessage(text)),
                    .init(role: "assistant", content: PromptBuilder.assistantPrefill),
                ],
                maxCompletionTokens: maxTokens
            )
        } catch let OpenAICompatibleChatClient.ClientError.badStatus(code, message) {
            throw ProviderError.badStatus(code, message: message)
        } catch OpenAICompatibleChatClient.ClientError.decodeFailed {
            throw ProviderError.decodeFailed
        }

        let unwrapped = CleanupOutputGuard.unwrapTags(content)
        guard let sanitized = CleanupOutputGuard.sanitize(candidate: unwrapped, original: text, mode: mode) else {
            throw ProviderError.rejectedByGuard
        }
        return sanitized
    }

    func warmUp() async {
        guard Self.isTransportSecure(modelsEndpoint) else { return }
        var req = URLRequest(url: modelsEndpoint)
        req.httpMethod = "GET"
        req.timeoutInterval = 3
        if !apiKey.isEmpty {
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        _ = try? await urlSession.data(for: req)
    }

    static func isTransportSecure(_ endpoint: URL) -> Bool {
        if endpoint.scheme?.lowercased() == "https" { return true }
        guard endpoint.scheme?.lowercased() == "http" else { return false }
        guard let host = endpoint.host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

    static func customEndpointWarning(baseURL: String) -> String? {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let endpoint = URL(string: trimmed), endpoint.host != nil else {
            return "Enter a complete endpoint URL."
        }
        return isTransportSecure(endpoint)
            ? nil
            : "Remote endpoints must use HTTPS to protect transcripts and API keys."
    }
}

extension OpenAICompatibleProvider: WarmableCleanupProvider {}
