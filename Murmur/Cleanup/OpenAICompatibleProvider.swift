import Foundation
import OSLog

/// One provider for every OpenAI-compatible chat-completions cleanup backend
/// (Groq, Cerebras) — they differ only by endpoint and display name.
actor OpenAICompatibleProvider: CleanupProvider {
    nonisolated let displayName: String

    enum ProviderError: Error, LocalizedError, Equatable {
        case badStatus(Int, message: String?)
        case missingAPIKey
        case insecureEndpoint
        case decodeFailed
        case truncated
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
            case .truncated: return "Cleanup output was cut off before it finished."
            case .rejectedByGuard: return "Cleanup output failed validation."
            }
        }
    }

    /// Wall-clock allowance for one clean() call. A retry only starts while at least half of it
    /// is left: after a slow failure the fallback (or LocalCleanup) is the faster path to a paste.
    private struct Budget: Sendable {
        let total: TimeInterval
        let deadline: Date
        init(_ total: TimeInterval) {
            self.total = total
            deadline = Date().addingTimeInterval(total)
        }
        var remaining: TimeInterval { max(0, deadline.timeIntervalSinceNow) }
        var allowsRetry: Bool { remaining >= total / 2 }
    }

    private let log = Logger(subsystem: "com.murmur.app", category: "cloud-cleanup")
    private let chatEndpoint: URL
    private let modelsEndpoint: URL
    private let apiKey: String
    private var model: String
    private let onModelReplaced: (@Sendable (String, String) async -> Void)?
    private let requiresKey: Bool
    private let isCustomEndpoint: Bool
    private let urlSession: URLSession
    private nonisolated let baseTimeout: TimeInterval
    private nonisolated let secondsPerWord: TimeInterval

    /// - Parameters:
    ///   - timeout: base seconds for one cleanup; longer dictations get a little more (see `timeBudget`).
    ///   - isCustomEndpoint: a user-typed endpoint — never swaps in another model and never
    ///     warms up a remote host (the Base URL may be half typed).
    init(
        displayName: String,
        chatEndpoint: URL,
        modelsEndpoint: URL,
        apiKey: String,
        model: String,
        requiresKey: Bool = true,
        timeout: TimeInterval = 5.0,
        session: URLSession? = nil,
        isCustomEndpoint: Bool = false,
        onModelReplaced: (@Sendable (String, String) async -> Void)? = nil
    ) {
        self.displayName = displayName
        self.chatEndpoint = chatEndpoint
        self.modelsEndpoint = modelsEndpoint
        self.apiKey = apiKey
        self.model = model
        self.onModelReplaced = onModelReplaced
        self.requiresKey = requiresKey
        self.isCustomEndpoint = isCustomEndpoint
        self.baseTimeout = timeout
        // Local servers generate far slower than Groq/Cerebras.
        self.secondsPerWord = Self.isLoopback(chatEndpoint) ? 0.05 : 0.015
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = timeout * 3 // hard cap; each request also gets the remaining budget
        self.urlSession = session ?? URLSession(configuration: cfg)
    }

    static func groq(apiKey: String, model: String, onModelReplaced: (@Sendable (String, String) async -> Void)? = nil) -> OpenAICompatibleProvider {
        OpenAICompatibleProvider(
            displayName: "Groq",
            chatEndpoint: URL(string: "https://api.groq.com/openai/v1/chat/completions")!,
            modelsEndpoint: URL(string: "https://api.groq.com/openai/v1/models")!,
            apiKey: apiKey,
            model: model,
            onModelReplaced: onModelReplaced
        )
    }

    static func cerebras(apiKey: String, model: String, onModelReplaced: (@Sendable (String, String) async -> Void)? = nil) -> OpenAICompatibleProvider {
        OpenAICompatibleProvider(
            displayName: "Cerebras",
            chatEndpoint: URL(string: "https://api.cerebras.ai/v1/chat/completions")!,
            modelsEndpoint: URL(string: "https://api.cerebras.ai/v1/models")!,
            apiKey: apiKey,
            model: model,
            onModelReplaced: onModelReplaced
        )
    }

    /// Any OpenAI-compatible server the user points at: LM Studio, OpenRouter,
    /// llama.cpp, LiteLLM, together.ai, … Local servers often need no key.
    static func custom(apiKey: String, baseURL: String, model: String, onModelReplaced: (@Sendable (String, String) async -> Void)? = nil) -> OpenAICompatibleProvider {
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
            timeout: isLoopback(root) ? 12.0 : 8.0, // local servers on modest hardware are slower than Groq/Cerebras
            isCustomEndpoint: true,
            onModelReplaced: onModelReplaced
        )
    }

    nonisolated func timeBudget(wordCount: Int) -> TimeInterval {
        // ponytail: linear in length (output ≈ 1.3 tokens per word), capped at 3× the base.
        min(baseTimeout + Double(wordCount) * secondsPerWord, baseTimeout * 3)
    }

    func clean(text: String, mode: CleanupMode, context: CleanupContext) async throws -> String {
        let budget = Budget(timeBudget(wordCount: DictationOrchestrator.wordCount(text)))
        do {
            guard !apiKey.isEmpty || !requiresKey else { throw ProviderError.missingAPIKey }
            guard Self.isTransportSecure(chatEndpoint) else { throw ProviderError.insecureEndpoint }

            let content: String
            do {
                content = try await requestWithRetry(text: text, mode: mode, context: context, budget: budget)
            } catch let ProviderError.badStatus(status, message) {
                // A user-chosen custom model is never swapped for whatever the server lists.
                guard !isCustomEndpoint, budget.allowsRetry,
                      ModelCatalog.isMissingModel(status: status, message: message),
                      let ids = try? await listModels(timeout: min(3, budget.remaining)),
                      let replacement = ModelCatalog.replacement(in: ids), replacement != model else {
                    throw ProviderError.badStatus(status, message: message)
                }
                try Task.checkCancellation()
                content = try await request(text: text, mode: mode, context: context, model: replacement, budget: budget)
                // Only adopt the replacement once it has actually worked.
                let old = model
                model = replacement
                await onModelReplaced?(old, replacement)
            }

            if let sanitized = CleanupOutputGuard.sanitize(
                candidate: CleanupOutputGuard.unwrapTags(content), original: text, mode: mode, vocabulary: context.vocabulary
            ) { return sanitized }

            // Give Groq a conservative correction attempt before abandoning cloud cleanup.
            guard chatEndpoint.host == "api.groq.com", budget.allowsRetry else { throw ProviderError.rejectedByGuard }
            try Task.checkCancellation()
            log.notice("Groq output rejected; retrying with verbatim cleanup instructions")
            let corrected = try await request(text: text, mode: mode, context: context, budget: budget, conservative: true)
            guard let sanitized = CleanupOutputGuard.sanitize(
                candidate: CleanupOutputGuard.unwrapTags(corrected), original: text, mode: mode, vocabulary: context.vocabulary
            ) else { throw ProviderError.rejectedByGuard }
            return sanitized
        } catch {
            // Log categories only: never transcript text, API keys, or provider response bodies.
            if !Task.isCancelled, !(error is CancellationError) {
                let reason: String
                switch error {
                case let ProviderError.badStatus(code, _): reason = "HTTP \(code)"
                case ProviderError.rejectedByGuard: reason = "output validation rejected the cleanup"
                case ProviderError.missingAPIKey: reason = "missing API key"
                case ProviderError.decodeFailed: reason = "unreadable response"
                case ProviderError.truncated: reason = "output truncated at the token limit"
                default:
                    let failure = error as NSError
                    reason = "\(failure.domain) code \(failure.code)"
                }
                log.error("\(self.displayName, privacy: .public) cleanup failed: \(reason, privacy: .public)")
            }
            throw error
        }
    }

    private func requestWithRetry(text: String, mode: CleanupMode, context: CleanupContext, budget: Budget) async throws -> String {
        do {
            return try await request(text: text, mode: mode, context: context, budget: budget)
        } catch {
            try Task.checkCancellation()
            guard chatEndpoint.host == "api.groq.com", budget.allowsRetry else { throw error }
            let transient: Bool
            if let failure = error as? URLError {
                transient = [.timedOut, .networkConnectionLost, .cannotConnectToHost].contains(failure.code)
            } else if case let ProviderError.badStatus(status, _) = error {
                transient = (500...599).contains(status)
            } else {
                transient = false
            }
            guard transient else { throw error }
            log.notice("Groq transient request failure; retrying once")
            try await Task.sleep(for: .milliseconds(250))
            return try await request(text: text, mode: mode, context: context, budget: budget)
        }
    }

    private func request(
        text: String,
        mode: CleanupMode,
        context: CleanupContext,
        model: String? = nil,
        budget: Budget,
        conservative: Bool = false
    ) async throws -> String {
        let timeout = budget.remaining
        guard timeout > 0.25 else { throw URLError(.timedOut) }
        let model = model ?? self.model
        let reasoning = model.lowercased().contains("gpt-oss")
        var systemPrompt = PromptBuilder.systemPrompt(for: mode, context: context)
        if conservative {
            systemPrompt += "\nPreserve the transcript words verbatim, except um and uh. Only fix capitalization and punctuation. Do not add greetings, commentary, or answers. Return only <cleaned>the transcript</cleaned>."
        }
        let messages: [OpenAICompatibleChatClient.Message] = [
            .init(role: "system", content: systemPrompt),
            .init(role: "user", content: PromptBuilder.transcriptMessage(text, fieldText: context.fieldText)),
        ] + (reasoning ? [] : [.init(role: "assistant", content: PromptBuilder.assistantPrefill)])
        let maxTokens = max(256, DictationOrchestrator.wordCount(text) * 4) + (reasoning ? 768 : 0)
        let reasoningEffort: String? = reasoning ? "low" : nil
        let includeReasoning: Bool? = reasoning && chatEndpoint.host == "api.groq.com" ? false : nil
        let client = OpenAICompatibleChatClient(endpoint: chatEndpoint, bearerToken: apiKey, session: urlSession)
        do {
            return try await withCleanupTimeout(seconds: timeout) {
                try await client.cleanupRequest(
                    model: model, temperature: 0.2, messages: messages, maxCompletionTokens: maxTokens,
                    reasoningEffort: reasoningEffort, includeReasoning: includeReasoning, timeout: timeout
                )
            }
        } catch let OpenAICompatibleChatClient.ClientError.badStatus(code, message) {
            throw ProviderError.badStatus(code, message: message)
        } catch OpenAICompatibleChatClient.ClientError.decodeFailed {
            throw ProviderError.decodeFailed
        } catch OpenAICompatibleChatClient.ClientError.truncated {
            throw ProviderError.truncated
        } catch is CleanupTimeoutError {
            throw URLError(.timedOut)
        }
    }

    func listModels() async throws -> [String] {
        try await listModels(timeout: 10)
    }

    private func listModels(timeout: TimeInterval) async throws -> [String] {
        guard !apiKey.isEmpty || !requiresKey else { throw ProviderError.missingAPIKey }
        return try await ModelCatalog.ids(endpoint: modelsEndpoint, apiKey: apiKey, session: urlSession, timeout: timeout)
    }

    func warmUp() async {
        // applySettings warms on every settings change, including each keystroke in the Base URL
        // field; warming a remote custom endpoint would send the saved key to half-typed hosts.
        guard !isCustomEndpoint || Self.isLoopback(modelsEndpoint) else { return }
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
        guard let host = endpoint.host, !host.isEmpty else { return false }
        if endpoint.scheme?.lowercased() == "https" { return true }
        return endpoint.scheme?.lowercased() == "http" && isLoopback(endpoint)
    }

    static func isLoopback(_ endpoint: URL) -> Bool {
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
