import Foundation
import OSLog

actor CodexCLIProvider: CleanupProvider {
    nonisolated let displayName = "ChatGPT via Codex CLI"

    enum ModelCatalog {
        static let recommended = "gpt-5.4-mini"
        static let options = [
            "gpt-5.4-mini",
            "gpt-5.4",
            "gpt-5.3-codex",
            "gpt-5.2",
        ]
    }

    enum CodexCLIError: Error, LocalizedError {
        case notInstalled
        case notAuthenticated
        case processFailed(Int32, String)
        case emptyResponse
        case timeout

        var errorDescription: String? {
            switch self {
            case .notInstalled:
                return "Codex CLI is not installed. Run `npm i -g @openai/codex`."
            case .notAuthenticated:
                return "Codex CLI is not authenticated. Run `codex login` and choose Sign in with ChatGPT."
            case .processFailed(let code, let stderr):
                return Self.failureMessage(code: code, detail: stderr)
            case .emptyResponse:
                return "Codex CLI did not produce a final cleanup response. Update Codex CLI or try a different model."
            case .timeout:
                return "Codex CLI timed out while cleaning text. Try a faster model or raise the provider timeout."
            }
        }

        private static func failureMessage(code: Int32, detail: String) -> String {
            let cleaned = detail.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = cleaned.lowercased()
            if lower.contains("unexpected argument") || lower.contains("unrecognized option") || lower.contains("unknown option") {
                return "Codex CLI changed its command-line options. Update Murmur's Codex provider or install a compatible Codex CLI."
            }
            if lower.contains("model") && (lower.contains("not found") || lower.contains("unknown") || lower.contains("unsupported")) {
                return "Codex CLI rejected the selected model. Choose a different Codex model in provider settings."
            }
            if lower.contains("unauthorized") || lower.contains("401") || lower.contains("not logged in") || lower.contains("login") {
                return "Codex CLI could not use your ChatGPT sign-in. Run `codex login status`, then `codex login` if needed."
            }
            let suffix = cleaned.isEmpty ? "No error details were returned." : cleaned
            return "Codex CLI exited with code \(code): \(suffix)"
        }
    }

    enum AuthenticationStatus: Equatable, Sendable {
        case notInstalled(String)
        case authenticated(String)
        case notAuthenticated(String)
        case unavailable(String)

        var isAuthenticated: Bool {
            if case .authenticated = self { return true }
            return false
        }

        var detail: String {
            switch self {
            case .notInstalled(let detail),
                 .authenticated(let detail),
                 .notAuthenticated(let detail),
                 .unavailable(let detail):
                return detail
            }
        }
    }

    private let executablePath: String?
    private let model: String
    private let timeout: TimeInterval
    private let requiresAuthentication: Bool
    private let log = Logger(subsystem: "com.murmur.app", category: "codex-cli")

    init(
        executablePath: String? = nil,
        model: String,
        timeout: TimeInterval = 45.0,
        requiresAuthentication: Bool = true
    ) {
        self.executablePath = executablePath
        self.model = model
        self.timeout = timeout
        self.requiresAuthentication = requiresAuthentication
    }

    func clean(text: String, mode: CleanupMode) async throws -> String {
        guard let exec = executablePath ?? Self.codexExecutablePath() else {
            throw CodexCLIError.notInstalled
        }
        guard !requiresAuthentication || Self.isAuthenticated() else {
            throw CodexCLIError.notAuthenticated
        }

        let prompt = """
        \(PromptBuilder.systemPrompt(for: mode))

        <transcript>
        \(text)
        </transcript>

        Begin your reply with <cleaned> and end it with </cleaned>. Output nothing else.
        """

        let started = Date()
        let content = try await runCodex(executable: exec, prompt: prompt)
        log.info("Codex CLI cleanup in \(Date().timeIntervalSince(started))s")

        let unwrapped = CleanupOutputGuard.unwrapTags(content)
        guard let sanitized = CleanupOutputGuard.sanitize(candidate: unwrapped, original: text, mode: mode) else {
            throw CodexCLIError.emptyResponse
        }
        return sanitized
    }

    private func runCodex(executable: String, prompt: String) async throws -> String {
        let timeoutSeconds = timeout
        let modelName = model

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            let process = Process()
            let stdinPipe = Pipe()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            let outputURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("murmur-codex-\(UUID().uuidString).txt")

            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = [
                "exec",
                "--skip-git-repo-check",
                "--ephemeral",
                "--sandbox", "read-only",
                "--output-last-message", outputURL.path,
                "--model", modelName,
                "-",
            ]
            process.standardInput = stdinPipe
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            process.currentDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory())

            var env = ProcessInfo.processInfo.environment
            Self.prepareEnvironment(&env)
            process.environment = env

            let didTimeOut = CodexLockedBool()

            do {
                try process.run()
            } catch {
                try? FileManager.default.removeItem(at: outputURL)
                cont.resume(throwing: error)
                return
            }

            if let data = prompt.data(using: .utf8) {
                try? stdinPipe.fileHandleForWriting.write(contentsOf: data)
            }
            try? stdinPipe.fileHandleForWriting.close()

            let timeoutTask = Task { [weak process] in
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                guard !Task.isCancelled, let proc = process, proc.isRunning else { return }
                didTimeOut.set(true)
                proc.terminate()
            }

            process.terminationHandler = { proc in
                timeoutTask.cancel()
                let outData = (try? stdoutPipe.fileHandleForReading.readToEnd()) ?? Data()
                let errData = (try? stderrPipe.fileHandleForReading.readToEnd()) ?? Data()
                let outString = String(data: outData, encoding: .utf8) ?? ""
                let errString = String(data: errData, encoding: .utf8) ?? ""
                let outputString = (try? String(contentsOf: outputURL, encoding: .utf8)) ?? ""
                try? FileManager.default.removeItem(at: outputURL)

                if didTimeOut.value {
                    cont.resume(throwing: CodexCLIError.timeout)
                } else if proc.terminationStatus == 0 {
                    cont.resume(returning: outputString.isEmpty ? outString : outputString)
                } else {
                    let detail = errString.isEmpty ? outString : errString
                    cont.resume(throwing: CodexCLIError.processFailed(proc.terminationStatus, detail))
                }
            }
        }
    }

    static func codexExecutablePath() -> String? {
        let home = NSHomeDirectory()
        let candidates = [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "\(home)/.local/bin/codex",
            "\(home)/.npm-global/bin/codex",
            "/opt/homebrew/opt/node/bin/codex",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func isInstalled() -> Bool {
        codexExecutablePath() != nil
    }

    static func isAuthenticated() -> Bool {
        authFileIndicatesAuthenticated()
    }

    static func authenticationStatus(timeout: TimeInterval = 3.0) async -> AuthenticationStatus {
        guard let executable = codexExecutablePath() else {
            return .notInstalled("Install the Codex CLI (`npm i -g @openai/codex`).")
        }

        do {
            let result = try await runCodexStatus(executable: executable, timeout: timeout)
            let detail = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = detail.lowercased()

            if result.status == 0 {
                if lower.contains("logged in using chatgpt") {
                    return .authenticated("Codex CLI reports: \(firstLine(detail)).")
                }
                if lower.contains("logged in") {
                    return .authenticated("Codex CLI is logged in. For ChatGPT OAuth, confirm `codex login status` says ChatGPT.")
                }
                return .unavailable("Codex CLI status was unclear: \(firstLine(detail)).")
            }

            if authFileIndicatesAuthenticated() {
                return .authenticated("OAuth credentials were found, but `codex login status` returned: \(firstLine(detail)).")
            }
            return .notAuthenticated(detail.isEmpty ? "Run `codex login` and choose Sign in with ChatGPT." : firstLine(detail))
        } catch {
            if authFileIndicatesAuthenticated() {
                return .authenticated("OAuth credentials were found, but `codex login status` could not be checked.")
            }
            return .unavailable("Codex CLI status check failed: \(error.localizedDescription)")
        }
    }

    private static func authFileIndicatesAuthenticated() -> Bool {
        guard let data = try? Data(contentsOf: authURL()),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return false
        }

        if (object["auth_mode"] as? String)?.lowercased() == "chatgpt" {
            return true
        }
        return object["tokens"] != nil
    }

    private static func runCodexStatus(
        executable: String,
        timeout: TimeInterval
    ) async throws -> (status: Int32, output: String) {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(status: Int32, output: String), Error>) in
            let process = Process()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()

            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = ["login", "status"]
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            process.currentDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory())

            var env = ProcessInfo.processInfo.environment
            prepareEnvironment(&env)
            process.environment = env

            let didTimeOut = CodexLockedBool()

            do {
                try process.run()
            } catch {
                cont.resume(throwing: error)
                return
            }

            let timeoutTask = Task { [weak process] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard !Task.isCancelled, let proc = process, proc.isRunning else { return }
                didTimeOut.set(true)
                proc.terminate()
            }

            process.terminationHandler = { proc in
                timeoutTask.cancel()
                let outData = (try? stdoutPipe.fileHandleForReading.readToEnd()) ?? Data()
                let errData = (try? stderrPipe.fileHandleForReading.readToEnd()) ?? Data()
                let outString = String(data: outData, encoding: .utf8) ?? ""
                let errString = String(data: errData, encoding: .utf8) ?? ""
                if didTimeOut.value {
                    cont.resume(throwing: CodexCLIError.timeout)
                } else {
                    let detail = [outString, errString]
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                        .joined(separator: "\n")
                    cont.resume(returning: (proc.terminationStatus, detail))
                }
            }
        }
    }

    private static func firstLine(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let line = trimmed.split(whereSeparator: \.isNewline).first else {
            return "No status detail returned"
        }
        return String(line)
    }

    private static func prepareEnvironment(_ env: inout [String: String]) {
        if env["HOME"] == nil { env["HOME"] = NSHomeDirectory() }
        let extraPath = "/opt/homebrew/bin:/usr/local/bin:\(NSHomeDirectory())/.local/bin:\(NSHomeDirectory())/.npm-global/bin"
        env["PATH"] = env["PATH"].map { "\(extraPath):\($0)" } ?? extraPath
        env["CODEX_HOME"] = env["CODEX_HOME"] ?? "\(NSHomeDirectory())/.codex"
    }

    static func authURL() -> URL {
        if let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"], !codexHome.isEmpty {
            return URL(fileURLWithPath: codexHome).appendingPathComponent("auth.json")
        }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/auth.json")
    }

    func warmUp() async {
        _ = Self.codexExecutablePath()
    }
}

extension CodexCLIProvider: WarmableCleanupProvider {}

private final class CodexLockedBool: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false

    var value: Bool {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    func set(_ newValue: Bool) {
        lock.lock(); defer { lock.unlock() }
        storage = newValue
    }
}
