import AppKit
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
    /// Word habits learned under the same switch; observed for the count and cleared with "forget".
    @ObservedObject var personalWordStore: PersonalWordStore
    /// The opt-in outcome log. Observed here so the toggle and record count stay live.
    @ObservedObject var suggestionUsageLog: SuggestionUsageLog

    private static let previewEditorMinHeight: CGFloat = 132
    private static let extendedContextEditorMinHeight: CGFloat = 220

    var body: some View {
        SettingsPaneScaffold {
            livePreviewSection
            learnedPhrasesSection
            usageLogSection
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

                Text(Self.livePreviewPrivacyNote(for: suggestionSettings.snapshot.selectedEngine))
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
                        Text("Learn from what I type")
                        Text("Off unless you turn it on. While it is on, Cotabby remembers the " +
                            "sentences of messages you finish and which words you tend to write " +
                            "next, and gives suggestions you accept extra weight. A phrase has to show " +
                            "up at least twice, and a word habit several times, before it is suggested; " +
                            "then it appears as you type, without waiting for the model. Switching it " +
                            "off stops both the learning and the suggesting, and keeps what was learned.")
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

                    Button("Forget What Was Learned", role: .destructive) {
                        phraseMemoryStore.forgetAll()
                        personalWordStore.forgetAll()
                    }
                    .disabled(phraseMemoryStore.phraseCount == 0 && personalWordStore.wordCount == 0)
                }
            }
            .padding(.vertical, 6)
            .settingsItem(.learnedPhrases)
        }
    }

    /// Opt-in outcome log controls. A section of its own, beside learned phrases, because both are
    /// records of the writer's own typing and both need an obvious off switch and delete button.
    private var usageLogSection: some View {
        Section("Suggestion usage log") {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: usageLogBinding) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Keep a private record of suggestions")
                        Text("Off unless you turn it on. While it is on, Cotabby writes down each " +
                            "suggestion, whether you took it, and the next words you typed, so " +
                            "suggestion quality can be measured on your real writing. It stays in a " +
                            "file on this Mac and is never sent anywhere. Password fields, terminals, " +
                            "and code editors are never recorded.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                HStack {
                    Text(usageLogCountLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()

                    Spacer(minLength: 0)

                    Button("Show in Finder") {
                        if let url = suggestionUsageLog.fileURL {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }
                    }
                    .disabled(suggestionUsageLog.recordCount == 0)

                    Button("Delete Log", role: .destructive) {
                        suggestionUsageLog.deleteAll()
                    }
                    .disabled(suggestionUsageLog.recordCount == 0)
                }
            }
            .padding(.vertical, 6)
            .settingsItem(.suggestionUsageLog)
        }
    }

    /// The preview drives the real pipeline, so its privacy note must follow the selected engine.
    /// Apple Intelligence and Open Source keep the typed text on this Mac; a configured endpoint,
    /// which may be on the LAN or the internet, receives it exactly as it would from any field.
    /// Cotabby can only speak for itself: what the endpoint retains is that server's policy.
    static func livePreviewPrivacyNote(for engine: SuggestionEngineKind) -> String {
        switch engine {
        case .appleIntelligence, .llamaOpenSource:
            return "Nothing here is saved or shared; it only exercises the on-device model."
        case .openAICompatible:
            return "Cotabby doesn't save this text, but like any other field it's sent to your configured endpoint, "
                + "which may keep it."
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
                    "Stored locally on this Mac. Included in requests to your selected " +
                        "engine, including a configured endpoint."
                )
                bulletLine(
                    "Phrase learning is off until you switch it on, and nothing is recorded while " +
                        "it is off."
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

    private var usageLogBinding: Binding<Bool> {
        Binding(
            get: { suggestionUsageLog.isEnabled },
            set: { suggestionUsageLog.setEnabled($0) }
        )
    }

    private var usageLogCountLabel: String {
        let count = suggestionUsageLog.recordCount
        guard count > 0 else {
            return suggestionUsageLog.isEnabled ? "Nothing recorded yet." : "Nothing recorded."
        }
        let summary = "\(count) suggestion\(count == 1 ? "" : "s") recorded."
        return suggestionUsageLog.isEnabled ? summary : summary + " Paused."
    }

    private var phraseMemoryBinding: Binding<Bool> {
        Binding(
            get: { suggestionSettings.isPhraseMemoryEnabled },
            set: { suggestionSettings.setPhraseMemoryEnabled($0) }
        )
    }

    /// Both numbers, because they answer different questions: how much has been observed, and how
    /// much of it has repeated often enough to actually influence a suggestion. The off states are
    /// spelled out separately so an empty counter never reads as "this is broken".
    private var learnedPhraseCountLabel: String {
        let stored = phraseMemoryStore.phraseCount
        let isEnabled = suggestionSettings.isPhraseMemoryEnabled
        guard stored > 0 else {
            return isEnabled ? "Nothing learned yet." : "Nothing learned. Turn this on to start."
        }
        let words = personalWordStore.wordCount
        let summary = "\(stored) phrase\(stored == 1 ? "" : "s") remembered, "
            + "\(phraseMemoryStore.eligiblePhraseCount) seen often enough to be used; "
            + "\(words) word\(words == 1 ? "" : "s") in your vocabulary."
        return isEnabled ? summary : summary + " Paused."
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
