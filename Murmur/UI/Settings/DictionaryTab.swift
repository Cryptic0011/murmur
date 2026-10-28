import SwiftUI

struct DictionaryTab: View {
    @ObservedObject var settings: SettingsStore
    @State private var vocabularyDraft: String = ""
    @State private var selectedRuleID: UUID?
    @State private var showAddRule = false
    @State private var newFind = ""
    @State private var newReplace = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            MurmurCard(
                title: "Vocabulary",
                subtitle: "Names, jargon, and product terms the transcriber should recognize. Biases speech-to-text toward these spellings."
            ) {
                VStack(alignment: .leading, spacing: 10) {
                    TextEditor(text: $vocabularyDraft)
                        .font(.system(size: 13, design: .monospaced))
                        .frame(minHeight: 120)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.murmurRowFill)
                        )

                    Text("Separate terms with commas or new lines, e.g. “Murmur, Groq, WhisperKit, Supabase”.")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)

                    HStack(spacing: 10) {
                        Button("Save Vocabulary") {
                            settings.customVocabulary = vocabularyDraft
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(vocabularyDraft == settings.customVocabulary)

                        if vocabularyDraft == settings.customVocabulary, !settings.vocabularyTerms.isEmpty {
                            Text("\(settings.vocabularyTerms.count) term\(settings.vocabularyTerms.count == 1 ? "" : "s") active")
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .foregroundStyle(.secondary)
                        }
                    }

                    Toggle("Auto-correct near misses", isOn: Binding(
                        get: { settings.fuzzyVocabularyCorrection },
                        set: { settings.fuzzyVocabularyCorrection = $0 }
                    ))
                    .toggleStyle(.switch)
                    Text("Transcript words one letter off from a vocabulary term are corrected to the exact spelling — “murmer” becomes “Murmur” without a replacement rule.")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            MurmurCard(
                title: "Replacements",
                subtitle: "Find-and-replace rules applied to every transcript. Case-insensitive, whole words."
            ) {
                Table(settings.replacementRules, selection: $selectedRuleID) {
                    TableColumn("When Murmur hears", value: \.find)
                    TableColumn("Replace with", value: \.replace)
                }
                .frame(minHeight: 220)
            }

            HStack {
                Button("Add Replacement") {
                    newFind = ""
                    newReplace = ""
                    showAddRule = true
                }
                Button("Remove Selected") { removeSelected() }
                    .disabled(selectedRuleID == nil)
                Spacer()
            }
        }
        .onAppear { vocabularyDraft = settings.customVocabulary }
        .sheet(isPresented: $showAddRule) { addRuleSheet }
    }

    private var addRuleSheet: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Add Replacement")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                Text("Fix a word the transcriber keeps getting wrong.")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            TextField("When Murmur hears (e.g. “murmer”)", text: $newFind)
                .textFieldStyle(.roundedBorder)
            TextField("Replace with (e.g. “Murmur”)", text: $newReplace)
                .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button("Cancel") { showAddRule = false }
                Button("Add") { addRule() }
                    .buttonStyle(.borderedProminent)
                    .disabled(newFind.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 460)
    }

    private func addRule() {
        let rule = ReplacementRule(
            find: newFind.trimmingCharacters(in: .whitespaces),
            replace: newReplace.trimmingCharacters(in: .whitespaces)
        )
        settings.replacementRules.append(rule)
        selectedRuleID = rule.id
        showAddRule = false
    }

    private func removeSelected() {
        guard let selectedRuleID else { return }
        settings.replacementRules.removeAll { $0.id == selectedRuleID }
        self.selectedRuleID = nil
    }
}
