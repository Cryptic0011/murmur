import Foundation
import OSLog

actor GeminiCLIProvider: CleanupProvider {
    nonisolated let displayName = "Gemini CLI"

    enum GeminiCLIError: Error, LocalizedError {
        case notInstalled
        case notAuthenticated
        case processFailed(Int32, String)
        case emptyResponse
        case timeout

        var errorDescription: String? {
            switch self {
            case .notInstalled:
                return "Gemini CLI is not installed. Run `brew install gemini-cli` or `npm i -g @google/gemini-cli`."
            case .notAuthenticated:
                return "Gemini CLI is not authenticated. Run `gemini` in a terminal and complete OAuth sign-in."
            case .processFailed(let code, let stderr):
                return "Gemini CLI exited with code \(code): \(stderr)"
            case .emptyResponse:
                return "Gemini CLI returned an empty response."
            case .timeout:
                return "Gemini CLI timed out."
            }
        }
    }

    private let executablePath: String?
    private let model: String
    private let timeout: TimeInterval
    private let log = Logger(subsystem: "com.murmur.app", category: "gemini-cli")

    init(executablePath: String? = nil, model: String, timeout: TimeInterval = 30.0) {
        self.executablePath = executablePath
        self.model = model
        self.timeout = timeout
    }

    func clean(text: String, mode: CleanupMode) async throws -> String {
        guard let exec = executablePath ?? Self.geminiExecutablePath() else {
            throw GeminiCLIError.notInstalled
        }
        guard Self.isAuthenticated() else {
            throw GeminiCLIError.notAuthenticated
        }

        let prompt = """
        \(PromptBuilder.systemPrompt(for: mode))

        <transcript>
        \(text)
        </transcript>

        Begin your reply with <cleaned> and end it with </cleaned>. Output nothing else.
        """

        let started = Date()
        let content = try await runGemini(executable: exec, prompt: prompt)
        log.info("Gemini CLI cleanup in \(Date().timeIntervalSince(started))s")

        let unwrapped = CleanupOutputGuard.unwrapTags(content)
        guard let sanitized = CleanupOutputGuard.sanitize(candidate: unwrapped, original: text, mode: mode) else {
            throw GeminiCLIError.emptyResponse
        }
        return sanitized
    }

    private func runGemini(executable: String, prompt: String) async throws -> String {
        let timeoutSeconds = timeout
        let modelName = model

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            let process = Process()
            let stdinPipe = Pipe()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()

            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = [
                "--prompt", "",
                "--model", modelName,
                "--output-format", "text",
                "--approval-mode", "yolo",
            ]
            process.standardInput = stdinPipe
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            process.currentDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory())

            var env = ProcessInfo.processInfo.environment
            if env["HOME"] == nil { env["HOME"] = NSHomeDirectory() }
            let extraPath = "/opt/homebrew/bin:/usr/local/bin:\(NSHomeDirectory())/.local/bin"
            env["PATH"] = env["PATH"].map { "\(extraPath):\($0)" } ?? extraPath
            process.environment = env

            let didTimeOut = LockedBool()

            do {
                try process.run()
            } catch {
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

                if didTimeOut.value {
                    cont.resume(throwing: GeminiCLIError.timeout)
                } else if proc.terminationStatus == 0 {
                    cont.resume(returning: outString)
                } else {
                    let detail = errString.isEmpty ? outString : errString
                    cont.resume(throwing: GeminiCLIError.processFailed(proc.terminationStatus, detail))
                }
            }
        }
    }

    static func geminiExecutablePath() -> String? {
        let home = NSHomeDirectory()
        let candidates = [
            "/opt/homebrew/bin/gemini",
            "/usr/local/bin/gemini",
            "\(home)/.local/bin/gemini",
            "\(home)/.npm-global/bin/gemini",
            "/opt/homebrew/opt/node/bin/gemini",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func isInstalled() -> Bool {
        geminiExecutablePath() != nil
    }

    static func isAuthenticated() -> Bool {
        let home = NSHomeDirectory()
        return FileManager.default.fileExists(atPath: "\(home)/.gemini/oauth_creds.json")
    }

    func warmUp() async {
        _ = Self.geminiExecutablePath()
    }
}

extension GeminiCLIProvider: WarmableCleanupProvider {}

private final class LockedBool: @unchecked Sendable {
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
