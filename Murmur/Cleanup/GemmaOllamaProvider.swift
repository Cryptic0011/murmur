import Foundation

actor GemmaOllamaProvider: CleanupProvider {
    nonisolated let displayName = "Gemma (local)"

    enum OllamaError: Error { case unreachable, badStatus(Int), decodeFailed }

    private let endpoint: URL
    private let model: String
    private let urlSession: URLSession

    init(endpoint: URL = URL(string: "http://localhost:11434")!, model: String, timeout: TimeInterval = 8.0) {
        self.endpoint = endpoint
        self.model = model
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = timeout
        self.urlSession = URLSession(configuration: cfg)
    }

    func clean(text: String, mode: CleanupMode) async throws -> String {
        if !(await Self.isReachable(endpoint: endpoint)) {
            _ = await Self.ensureRunning(endpoint: endpoint)
        }

        var req = URLRequest(url: endpoint.appendingPathComponent("api/chat"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        struct Body: Encodable {
            let model: String
            let stream: Bool
            let messages: [OpenAICompatibleChatClient.Message]
            let options: [String: Double]
        }
        let body = Body(
            model: model,
            stream: false,
            messages: [
                .init(role: "system", content: PromptBuilder.systemPrompt(for: mode)),
                .init(role: "user", content: "<transcript>\n\(text)\n</transcript>"),
                .init(role: "assistant", content: PromptBuilder.assistantPrefill),
            ],
            options: ["temperature": 0.2]
        )
        req.httpBody = try JSONEncoder().encode(body)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await urlSession.data(for: req)
        } catch {
            throw OllamaError.unreachable
        }
        guard let http = response as? HTTPURLResponse else { throw OllamaError.badStatus(0) }
        guard (200..<300).contains(http.statusCode) else { throw OllamaError.badStatus(http.statusCode) }

        struct Wire: Decodable { let message: Msg; struct Msg: Decodable { let content: String } }
        let wire = try JSONDecoder().decode(Wire.self, from: data)
        let unwrapped = CleanupOutputGuard.unwrapTags(wire.message.content)
        guard let sanitized = CleanupOutputGuard.sanitize(candidate: unwrapped, original: text, mode: mode) else {
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
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return false }
            let tags = try JSONDecoder().decode(TagsResponse.self, from: data)
            return tags.models.contains {
                $0.name == model || $0.model == model
            }
        } catch {
            return false
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
        launchServerIfInstalled()

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

    private static func launchServerIfInstalled() {
        guard let executable = ollamaExecutablePath() else { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-lc",
            "nohup '\(executable.replacingOccurrences(of: "'", with: "'\\''"))' serve >/tmp/murmur-ollama.log 2>&1 &"
        ]

        let nullDevice = FileHandle(forWritingAtPath: "/dev/null")
        process.standardOutput = nullDevice
        process.standardError = nullDevice

        do {
            try process.run()
        } catch {
            return
        }
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
        let reachable = await Self.isReachable(endpoint: endpoint)
        if !reachable {
            _ = await Self.ensureRunning(endpoint: endpoint)
        }
        _ = await Self.isModelAvailable(model: model, endpoint: endpoint)
    }
}

extension GemmaOllamaProvider: WarmableCleanupProvider {}
