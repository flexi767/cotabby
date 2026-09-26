import SwiftUI

/// File overview:
/// "Context" detail pane of the Settings window. It leads with a live preview: a real, native text
/// field that the running app completes in exactly as it does anywhere else. Typing in it drives the
/// production focus -> suggestion -> overlay pipeline end to end, so the gray suggestion, Tab to
/// accept, and Esc to dismiss are the real thing, not an in-app reimplementation. Below it sits the
/// Extended Context editor (a free-form blob folded into every prompt) with its cost warning
/// co-located, then a short "how this is used" note.
///
/// Why the field is real (the redesign):
/// the preview previously hand-rolled an `NSTextView` that mirrored a SwiftUI binding and rendered a
/// ghost run inside its own editable storage. That reconciliation raced with live keystrokes and
/// corrupted typed text, so the box felt unnatural to type in. The field is now plain and inert:
/// `FocusTracker` lifts its "never complete in our own UI" rule for this one element (keyed on
/// `ContextLivePreview.accessibilityIdentifier`), and the real overlay draws the suggestion at the
/// caret. The text view owns its string outright, so nothing competes with the user's typing.
///
/// Why a dedicated pane (not Writing): the Writing pane carries name and language personalization.
/// Extended Context is a different shape (long-form, free markdown, and noticeably more expensive on
/// the token budget), so it keeps its own pane with room for the cost-of-use warning.
///
/// The Extended Context editor binds through `SuggestionSettingsModel.setExtendedContext`, which
/// length-caps the value on write. Whitespace is intentionally NOT trimmed in the setter so the user
/// can type a trailing space; `SuggestionRequestFactory` does the once-per-request trim instead.
struct ContextPaneView: View {
    @ObservedObject var suggestionSettings: SuggestionSettingsModel
    /// Counts and the forget control for the learned-phrase memory. Observed rather than passed as
    /// closures so the labels update the moment a phrase is learned or the memory is cleared.
    @ObservedObject var phraseMemoryStore: PhraseMemoryStore

    private static let previewEditorMinHeight: CGFloat = 132
    private static let extendedContextEditorMinHeight: CGFloat = 220

    var body: some View {
        SettingsPaneScaffold {
            livePreviewSection
            learnedPhrasesSection
            extendedContextSection
            howThisIsUsedSection
        }
    }

    // MARK: - Live preview

    private var livePreviewSection: some View {
        Section("Live preview") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Type below and Cotabby completes as you go, using the same engine and settings " +
                    "it uses everywhere. Press Tab to accept the gray suggestion, Esc to dismiss.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                ContextLivePreviewField()
                    .frame(minHeight: Self.previewEditorMinHeight)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color(nsColor: .textBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                    )
                    .accessibilityLabel("Live preview input")

                // The active engine, so the user knows which backend they're exercising. The live
                // suggestion, latency, and accept cues come from the real overlay, not this pane.
                Text(suggestionSettings.snapshot.selectedEngine.displayLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("Nothing here is saved or shared; it only exercises the on-device model.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 6)
            .settingsItem(.contextLivePreview)
        }
    }

    // MARK: - Learned phrases

    /// The counterpart to Extended Context: where that is context the user writes by hand, this is
    /// context Cotabby assembles by watching what they actually type. Both land in the same prompt,
    /// so they belong in the same pane — and the "forget" control belongs next to the counter that
    /// shows there is something to forget.
    private var learnedPhrasesSection: some View {
        Section("Learned phrases") {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: phraseMemoryBinding) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Learn phrases I type often")
                        Text("When you finish a message, Cotabby remembers its sentences. A phrase " +
                            "has to show up at least twice before it is ever used in a suggestion.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                HStack {
                    Text(learnedPhraseCountLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()

                    Spacer(minLength: 0)

                    Button("Forget Learned Phrases", role: .destructive) {
                        phraseMemoryStore.forgetAll()
                    }
                    .disabled(phraseMemoryStore.phraseCount == 0)
                }
            }
            .padding(.vertical, 6)
            .settingsItem(.learnedPhrases)
        }
    }

    // MARK: - Extended Context

    private var extendedContextSection: some View {
        Section("Extended Context") {
            VStack(alignment: .leading, spacing: 12) {
                // The cost warning lives next to the editor it describes (it used to be a pane-level
                // banner) so the trade-off is read right where the user is about to paste a big block.
                SettingsCalloutView(
                    callout: SettingsPaneCallout(
                        tone: .warning,
                        message: "Everything here is sent to the model on every keystroke. Long blocks " +
                            "slow down completions and may crowd out the surrounding text the model " +
                            "needs to continue accurately."
                    )
                )

                Text("Paste a glossary, jargon list, style guide excerpt, or any reference the model " +
                    "should keep in mind. Markdown structure (headings, bullet lists, examples) is " +
                    "preserved verbatim.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                TextEditor(text: editorBinding)
                    .font(.system(size: 13, design: .monospaced))
                    .frame(minHeight: Self.extendedContextEditorMinHeight)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color(nsColor: .textBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                    )
                    .accessibilityLabel("Extended context notes")

                HStack {
                    Text(characterCountLabel)
                        .font(.caption)
                        .foregroundStyle(isApproachingLimit ? .orange : .secondary)
                        .monospacedDigit()

                    Spacer(minLength: 0)

                    Button("Clear", role: .destructive) {
                        suggestionSettings.setExtendedContext("")
                    }
                    .disabled(suggestionSettings.extendedContext.isEmpty)
                }
            }
            .padding(.vertical, 6)
            .settingsItem(.extendedContext)
        }
    }

    private var howThisIsUsedSection: some View {
        Section("How this is used") {
            VStack(alignment: .leading, spacing: 8) {
                bulletLine(
                    "Sent on every suggestion as reference material, not as instructions."
                )
                bulletLine(
                    "Subordinate to Cotabby's base autocomplete rules, so it cannot override " +
                        "core behavior."
                )
                bulletLine(
                    "Capped at \(SuggestionSettingsModel.maximumExtendedContextCharacters) " +
                        "characters. Anything pasted beyond that is trimmed automatically."
                )
                bulletLine(
                    "Stored locally on this Mac. Nothing is uploaded; this only feeds the " +
                        "on-device model."
                )
                bulletLine(
                    "Learned phrases are never taken from password fields, terminals, or code " +
                        "editors, and anything shaped like a key, token, address, or long number " +
                        "is skipped."
                )
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.vertical, 6)
        }
    }

    // MARK: - Bindings & helpers

    private var phraseMemoryBinding: Binding<Bool> {
        Binding(
            get: { suggestionSettings.isPhraseMemoryEnabled },
            set: { suggestionSettings.setPhraseMemoryEnabled($0) }
        )
    }

    /// Both numbers, because they answer different questions: how much has been observed, and how
    /// much of it has repeated often enough to actually influence a suggestion.
    private var learnedPhraseCountLabel: String {
        let stored = phraseMemoryStore.phraseCount
        guard stored > 0 else {
            return "Nothing learned yet."
        }
        return "\(stored) phrase\(stored == 1 ? "" : "s") remembered, "
            + "\(phraseMemoryStore.eligiblePhraseCount) seen often enough to be used."
    }

    private var editorBinding: Binding<String> {
        Binding(
            get: { suggestionSettings.extendedContext },
            set: { suggestionSettings.setExtendedContext($0) }
        )
    }

    private var characterCountLabel: String {
        let current = suggestionSettings.extendedContext.count
        let maximum = SuggestionSettingsModel.maximumExtendedContextCharacters
        return "\(current) / \(maximum) characters"
    }

    /// Visual nudge when the user is within 10% of the cap so a long paste doesn't silently truncate
    /// without the user noticing the counter creeping toward the limit.
    private var isApproachingLimit: Bool {
        let current = suggestionSettings.extendedContext.count
        let maximum = SuggestionSettingsModel.maximumExtendedContextCharacters
        return current >= Int(Double(maximum) * 0.9)
    }

    @ViewBuilder
    private func bulletLine(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("•")
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
