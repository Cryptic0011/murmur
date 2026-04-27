import Foundation
import Testing
@testable import Murmur

@Suite("CodexCLIProvider")
struct CodexCLIProviderTests {
    @Test("runs Codex exec with model, prompt, and output file")
    func runsCodexExec() async throws {
        let dir = try makeTempDirectory()
        let argsURL = dir.appendingPathComponent("args.txt")
        let stdinURL = dir.appendingPathComponent("stdin.txt")
        let scriptURL = dir.appendingPathComponent("codex")
        try writeExecutable(
            at: scriptURL,
            """
            #!/bin/zsh
            print -r -- "$*" > "\(argsURL.path)"
            cat > "\(stdinURL.path)"
            output_path=""
            while [[ $# -gt 0 ]]; do
              if [[ "$1" == "--output-last-message" ]]; then
                shift
                output_path="$1"
              fi
              shift
            done
            print -r -- "<cleaned>Hello there.</cleaned>" > "$output_path"
            """
        )

        let provider = CodexCLIProvider(
            executablePath: scriptURL.path,
            model: "gpt-5.4-mini",
            timeout: 2,
            requiresAuthentication: false
        )

        let cleaned = try await provider.clean(text: "hello there um", mode: .light)
        #expect(cleaned == "Hello there.")

        let args = try String(contentsOf: argsURL, encoding: .utf8)
        #expect(args.contains("exec"))
        #expect(args.contains("--skip-git-repo-check"))
        #expect(args.contains("--ephemeral"))
        #expect(args.contains("--sandbox read-only"))
        #expect(args.contains("--model gpt-5.4-mini"))

        let stdin = try String(contentsOf: stdinURL, encoding: .utf8)
        #expect(stdin.contains("<transcript>"))
        #expect(stdin.contains("hello there um"))
        #expect(stdin.contains("<cleaned>"))
    }

    @Test("reports process failures with useful detail")
    func reportsProcessFailures() async throws {
        let dir = try makeTempDirectory()
        let scriptURL = dir.appendingPathComponent("codex")
        try writeExecutable(
            at: scriptURL,
            """
            #!/bin/zsh
            print -ru2 -- "unknown model gpt-nope"
            exit 2
            """
        )

        let provider = CodexCLIProvider(
            executablePath: scriptURL.path,
            model: "gpt-nope",
            timeout: 2,
            requiresAuthentication: false
        )

        do {
            _ = try await provider.clean(text: "hello there", mode: .light)
            Issue.record("Expected Codex CLI failure")
        } catch {
            #expect(error.localizedDescription.contains("rejected the selected model"))
        }
    }

    @Test("times out stalled Codex exec")
    func timesOutStalledExec() async throws {
        let dir = try makeTempDirectory()
        let scriptURL = dir.appendingPathComponent("codex")
        try writeExecutable(
            at: scriptURL,
            """
            #!/bin/zsh
            sleep 2
            """
        )

        let provider = CodexCLIProvider(
            executablePath: scriptURL.path,
            model: "gpt-5.4-mini",
            timeout: 0.1,
            requiresAuthentication: false
        )

        do {
            _ = try await provider.clean(text: "hello there", mode: .light)
            Issue.record("Expected Codex CLI timeout")
        } catch {
            #expect(error.localizedDescription.contains("timed out"))
        }
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("murmur-codex-provider-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeExecutable(at url: URL, _ contents: String) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

}
