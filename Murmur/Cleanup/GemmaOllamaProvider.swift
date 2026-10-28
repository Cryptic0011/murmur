import Foundation

actor GemmaOllamaProvider: CleanupProvider {
    nonisolated let displayName = "Ollama (local)"

    enum OllamaError: Error { case unreachable, badStatus(Int), decodeFailed, truncated }

    private let endpoint: URL
    private let model: String
    private let urlSession: URLSession
    private nonisolated let baseTimeout: TimeInterval
    /// Skips the per-dictation probe while a recent request proved the server is up.
    private var reachableUntil: Date?

    /// - Parameter timeout: base seconds for one cleanup; longer dictations get more (see `timeBudget`).
    init(endpoint: URL = URL(string: "http://localhost:11434")!, model: String, timeout: TimeInterval = 8.0) {
        self.endpoint = endpoint
        self.model = model
        self.baseTimeout = timeout
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = 60 // hard cap; each request sets its own budget
        self.urlSession = URLSession(configuration: cfg)
    }

    nonisolated func timeBudget(wordCount: Int) -> TimeInterval {
        // ponytail: ~20 words/s on modest Macs with the model resident; a cold multi-GB load
        // after keep_alive expires can still overrun and fall back once.
        min(baseTimeout + Double(wordCount) * 0.05, 30)
    }

    func clean(text: String, mode: CleanupMode, context: CleanupContext) async throws -> String {
        // Never launch or wait for a server here: DependencySetupCoordinator owns starting Ollama,
        // and a dictation that polls for one that may never appear stalls the paste.
        if (reachableUntil ?? .distantPast) < Date() {
            guard await Self.isReachable(endpoint: endpoint) else { throw OllamaError.unreachable }
            reachableUntil = Date().addingTimeInterval(60)
        }

        // Counts each Han/kana character, like the orchestrator, so CJK budgets aren't one "word".
        let wordCount = DictationOrchestrator.wordCount(text)
        let budget = timeBudget(wordCount: wordCount)
        var req = URLRequest(url: endpoint.appendingPathComponent("api/chat"))
        req.httpMethod = "POST"
        req.timeoutInterval = budget
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        struct Body: Encodable {
            let model: String
            let stream: Bool
            let messages: [OpenAICompatibleChatClient.Message]
            // Without this, each request resets the model's residency to
            // Ollama's 5-minute default and the warmUp 30m TTL is lost.
            let keepAlive: String
            let options: [String: Double]

            enum CodingKeys: String, CodingKey {
                case model, stream, messages, options
                case keepAlive = "keep_alive"
            }
        }
        let body = Body(
            model: model,
            stream: false,
            messages: [
                .init(role: "system", content: PromptBuilder.systemPrompt(for: mode, context: context)),
                .init(role: "user", content: PromptBuilder.transcriptMessage(text, fieldText: context.fieldText)),
                .init(role: "assistant", content: PromptBuilder.assistantPrefill),
            ],
            keepAlive: "30m",
            options: [
                "temperature": 0.2,
                // Bound generation to roughly input size so a runaway model fails
                // fast instead of running into the session timeout.
                "num_predict": Double(max(256, wordCount * 4)),
            ]
        )
        req.httpBody = try JSONEncoder().encode(body)

        let (data, status): (Data, Int)
        do {
            let session = urlSession
            let request = req
            (data, status) = try await withCleanupTimeout(seconds: budget) {
                let (data, response) = try await session.data(for: request)
                return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
            }
        } catch {
            reachableUntil = nil
            throw OllamaError.unreachable
        }
        guard (200..<300).contains(status) else { throw OllamaError.badStatus(status) }

        struct Wire: Decodable {
            struct Msg: Decodable { let content: String? }
            let message: Msg?
            let doneReason: String?
            enum CodingKeys: String, CodingKey {
                case message
                case doneReason = "done_reason"
            }
        }
        guard let wire = try? JSONDecoder().decode(Wire.self, from: data) else { throw OllamaError.decodeFailed }
        // num_predict reached: the cleanup stops mid-dictation.
        if wire.doneReason == "length" { throw OllamaError.truncated }
        let unwrapped = CleanupOutputGuard.unwrapTags(wire.message?.content ?? "")
        guard let sanitized = CleanupOutputGuard.sanitize(
            candidate: unwrapped, original: text, mode: mode, vocabulary: context.vocabulary
        ) else {
            throw OllamaError.decodeFailed
        }
        return sanitized
    }

    static func isReachable(endpoint: URL = URL(string: "http://localhost:11434")!) async -> Bool {
        var req = URLRequest(url: endpoint.appendingPathComponent("api/tags"))
        req.timeoutInterval = 0.5
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            return (resp as? HTTPURLResponse)?.statusCode == 200
        } catch { return false }
    }

    static func isModelAvailable(
        model: String,
        endpoint: URL = URL(string: "http://localhost:11434")!
    ) async -> Bool {
        await installedModels(endpoint: endpoint).contains(model)
    }

    /// Names of models currently installed in the local Ollama instance
    /// (empty when Ollama is unreachable).
    static func installedModels(
        endpoint: URL = URL(string: "http://localhost:11434")!
    ) async -> [String] {
        struct TagsResponse: Decodable {
            struct Model: Decodable {
                let name: String
                let model: String?
            }
            let models: [Model]
        }

        var req = URLRequest(url: endpoint.appendingPathComponent("api/tags"))
        req.timeoutInterval = 2
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }
            let tags = try JSONDecoder().decode(TagsResponse.self, from: data)
            var seen = Set<String>()
            return tags.models
                .flatMap { [$0.name, $0.model].compactMap { $0 } }
                .filter { seen.insert($0).inserted }
        } catch {
            return []
        }
    }

    static func pullModel(
        model: String,
        endpoint: URL = URL(string: "http://localhost:11434")!,
        progress: @Sendable @escaping (String, Double?) -> Void
    ) async throws -> Bool {
        struct PullBody: Encodable {
            let name: String
            let stream: Bool
        }
        struct PullEvent: Decodable {
            let status: String?
            let completed: Double?
            let total: Double?
            let error: String?
        }

        var req = URLRequest(url: endpoint.appendingPathComponent("api/pull"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(PullBody(name: model, stream: true))

        let (bytes, response) = try await URLSession.shared.bytes(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return false
        }

        for try await line in bytes.lines {
            guard !line.isEmpty else { continue }
            let data = Data(line.utf8)
            let event = try JSONDecoder().decode(PullEvent.self, from: data)
            if let error = event.error {
                progress(error, nil)
                return false
            }

            let detail = event.status ?? "Downloading \(model)…"
            let ratio: Double?
            if let completed = event.completed, let total = event.total, total > 0 {
                ratio = min(max(completed / total, 0), 1)
            } else {
                ratio = nil
            }
            progress(detail, ratio)
        }

        return await isModelAvailable(model: model, endpoint: endpoint)
    }

    static func ensureRunning(
        endpoint: URL = URL(string: "http://localhost:11434")!,
        waitTimeout: TimeInterval = 20
    ) async -> Bool {
        if await isReachable(endpoint: endpoint) { return true }
        // Nothing was launched, so there is no server worth polling for.
        guard launchServerIfInstalled() else { return false }

        let deadline = Date().addingTimeInterval(waitTimeout)
        while Date() < deadline {
            if await isReachable(endpoint: endpoint) { return true }
            do {
                try await Task.sleep(nanoseconds: 500_000_000)
            } catch {
                return false
            }
        }
        return await isReachable(endpoint: endpoint)
    }

    /// Starts `ollama serve` in the background; false when Ollama isn't installed or the launch failed.
    private static func launchServerIfInstalled() -> Bool {
        guard let executable = ollamaExecutablePath() else { return false }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-lc",
            "nohup \(shellQuoted(executable)) serve >\(shellQuoted(serverLogPath())) 2>&1 &"
        ]

        // FileHandle would leak an fd per launch attempt; NullDevice doesn't.
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            return true
        } catch {
            return false
        }
    }

    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The per-user log folder rather than a predictable path in world-writable /tmp.
    private static func serverLogPath() -> String {
        let logs = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Murmur", isDirectory: true)
        guard (try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)) != nil else {
            return "/dev/null"
        }
        return logs.appendingPathComponent("ollama.log").path
    }

    static func ollamaExecutablePath() -> String? {
        let candidates = [
            "/usr/local/bin/ollama",
            "/opt/homebrew/bin/ollama",
            "/Applications/Ollama.app/Contents/Resources/ollama",
        ]

        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func warmUp() async {
        // Never launch from here: DependencySetupCoordinator owns starting the server, and
        // it warms the model once its setup run finds it ready.
        guard await Self.isReachable(endpoint: endpoint) else { return }
        reachableUntil = Date().addingTimeInterval(60)
        // /api/tags does not load the model into memory — send a tiny chat request
        // with keep_alive so the first real cleanup skips the multi-second load.
        struct WarmBody: Encodable {
            let model: String
            let stream: Bool
            let messages: [OpenAICompatibleChatClient.Message]
            let keepAlive: String
            let options: [String: Double]

            enum CodingKeys: String, CodingKey {
                case model, stream, messages, options
                case keepAlive = "keep_alive"
            }
        }
        var req = URLRequest(url: endpoint.appendingPathComponent("api/chat"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 30
        req.httpBody = try? JSONEncoder().encode(WarmBody(
            model: model,
            stream: false,
            messages: [.init(role: "user", content: "hi")],
            keepAlive: "30m",
            options: ["num_predict": 1]
        ))
        _ = try? await URLSession.shared.data(for: req)
    }
}

extension GemmaOllamaProvider: WarmableCleanupProvider {}
