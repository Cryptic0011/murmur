import SwiftUI

struct DependencySetupCard: View {
    @ObservedObject var setup: DependencySetupCoordinator
    let showActions: Bool

    var body: some View {
        MurmurCard(title: "Dependency Setup", subtitle: "Murmur prepares local models and fallback services automatically.") {
            VStack(alignment: .leading, spacing: 14) {
                if setup.snapshot.usesWhisperLocal {
                    setupRow(title: "Whisper", value: setup.snapshot.whisper.detail, state: setup.snapshot.whisper)
                }
                if setup.snapshot.usesGroqAPI {
                    setupRow(title: "Groq API", value: setup.snapshot.groq.detail, state: setup.snapshot.groq)
                }
                if setup.snapshot.usesOllama {
                    setupRow(title: "Ollama", value: setup.snapshot.ollama.detail, state: setup.snapshot.ollama)
                }
                if setup.snapshot.usesAppleIntelligence {
                    setupRow(
                        title: "Apple Intelligence",
                        value: setup.snapshot.appleIntelligence.detail,
                        state: setup.snapshot.appleIntelligence
                    )
                }

                if showActions {
                    HStack(spacing: 10) {
                        Button(setup.snapshot.isRunning ? "Preparing…" : "Retry Setup") {
                            setup.retry()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(setup.snapshot.isRunning)

                        if setup.snapshot.usesOllama, setup.snapshot.ollama.isActionRequired {
                            Button("Install Ollama") {
                                setup.openOllamaDownload()
                            }
                            .buttonStyle(.bordered)
                        }

                        if setup.snapshot.usesGroqAPI, setup.snapshot.groq.isActionRequired {
                            Button("Open Groq Keys") {
                                setup.openGroqKeys()
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            }
        }
    }

    private func setupRow(title: String, value: String, state: DependencySetupState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: state.symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color(state.tint))
                Text(title)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                Spacer()
                if state.isRunning {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            Text(value)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)

            if let progress = state.progressValue {
                ProgressView(value: progress)
                    .tint(Color(state.tint))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.black.opacity(0.05))
        )
    }
}
