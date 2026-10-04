import Combine
import Foundation

/// File overview:
/// Declares the shared state and dependency graph for Cotabby's inline-completion orchestrator.
/// The behavior now lives in `SuggestionCoordinator+*.swift` files so maintainers can read the
/// state machine by concern instead of scrolling through one monolithic source file.
///
/// Swift does not offer a "type-private across multiple files" access level. Because this
/// coordinator is split across extension files, coordinator-owned mutable state uses module
/// visibility and is protected by convention: other types should observe these properties, not
/// mutate them.
@MainActor
final class SuggestionCoordinator: ObservableObject {
    /// Coordinator-owned state machine values. Tests inspect these directly, but no UI subscribes
    /// to them, so keeping them as plain properties avoids unrelated menu re-renders.
    var state: SuggestionDebugState = .idle
    var overlayState: OverlayState = .hidden(reason: "Overlay idle.")
    var latestGenerationNumber: UInt64?
    /// True while the latest focus snapshot carried host-owned marked text (system inline
    /// prediction or IME composition); see `SuggestionCoordinator+HostMarkedText.swift`.
    var isHoldingForHostMarkedText = false
    /// Work id of a generation re-issued from the word boundary after a seam misspelling, so the
    /// retry's own result is judged once and never retried again.
    @Published var visualContextStatus: VisualContextStatus = .idle
    @Published var latestVisualContextText: String?
    @Published var totalTabAcceptedWordCount: Int = 0

    // Core collaborators. The coordinator depends on capability-shaped protocols here so its
    // orchestration logic stays separated from concrete service implementations.
    let permissionManager: any SuggestionPermissionProviding
    /// Provides the initial Low Power Mode state and subsequent transitions.
    let lowPowerModeProvider: any SuggestionLowPowerModeProviding
    let focusModel: any SuggestionFocusProviding
    let inputMonitor: any SuggestionInputMonitoring
    let overlayController: any SuggestionOverlayControlling
    let suggestionInserter: any SuggestionInserting
    let suggestionEngine: any SuggestionGenerating
    let suggestionSettings: any SuggestionSettingsProviding
    let clipboardContextProvider: any ClipboardContextProviding
    let clipboardRelevanceFilter: any ClipboardRelevanceFiltering
    let visualContextCoordinator: any VisualContextCoordinating
    let interactionState: SuggestionInteractionState
    let workController: SuggestionWorkController
    let configuration: SuggestionConfiguration
    let userDefaults: UserDefaults
    let overlayPresenter: SuggestionOverlayPresenter
    let logger: SuggestionDebugLogger
    /// Drives the typo gate before each prediction. Owned at app scope (constructed once in
    /// `CotabbyAppEnvironment`) so the underlying `NSSpellChecker` document tag persists across the
    /// coordinator's lifetime instead of churning per keystroke.
    let spellChecker: CurrentWordSpellChecker
    /// Always-on quality counters (shown / suppressed / accepted). The router counts generation
    /// outcomes; the coordinator owns the display-time and acceptance events only it can see.
    let qualityMetricsStore: SuggestionQualityMetricsStore
    /// Durable memory of the phrases this writer finishes typing. The coordinator is the only writer:
    /// it is the one place that sees the focused field's text over time, which is what commit
    /// detection needs. Read on every request build so a phrase learned a minute ago is already in
    /// play.
    let phraseMemoryStore: PhraseMemoryStore
    /// The writer's word habits (see `PersonalWordStore`); fed alongside phrase memory.
    let personalWordStore: PersonalWordStore
    /// Opt-in outcome log (see `SuggestionUsageLog`); inert until the user switches it on.
    let suggestionUsageLog: SuggestionUsageLog
    /// Frequency-ranked correction source (SymSpell). Used first for the correction word, with
    /// `spellChecker` as the fallback while its index is still loading or when it has no suggestion.
    let symSpellCorrector: SymSpellCorrector
    /// Chooses at most one enabled SymSpell language from the text surrounding the typo. Ambiguous
    /// contexts return nil so correction ranking falls back to the system spell checker.
    let spellingLanguageResolver: SpellingLanguageResolver

    /// Optional first-look hook the emoji picker installs to observe the keystroke stream. Called at
    /// the very top of `handleInputEvent`, before any suggestion logic. Returns `true` when an emoji
    /// capture is involved with this key, in which case the coordinator stands down so ghost text does
    /// not compete with the picker. It never consumes keys here (the listen-only observer cannot);
    /// consumption happens through `InputMonitor.emojiCaptureKeyDecider`.
    var emojiInputObserver: ((CapturedInputEvent) -> Bool)?

    /// Primary language of the active keyboard layout, read at each request build so a writer who
    /// switches layouts to switch languages gets that language's prompt hint and token budget.
    /// Installed by `CotabbyAppEnvironment`; the default keeps tests and previews layout-agnostic.
    var keyboardLanguageCodeProvider: () -> String? = { nil }

    static let totalTabAcceptedWordCountDefaultsKey = "cotabbyTotalAcceptedWordCount"

    // Combine subscriptions are the coordinator's remaining direct mutable bookkeeping.
    // Async work and active-session storage now live in dedicated collaborators below.
    var cancellables = Set<AnyCancellable>()
    var settingsSnapshot: SuggestionSettingsSnapshot
    /// Last completed round trip per backend, retained across keystrokes. Keeping this separate lets
    /// a slow HTTP backend retain an appropriate debounce without leaking that latency into the
    /// in-process engines.
    var lastLatencyByEngine: [SuggestionEngineKind: Int] = [:]
    // Synchronous input/focus callbacks cannot directly `await`, so resets are represented as a
    // barrier task that the next generation must cross before it can ask the runtime for output.
    var cacheResetSequence: UInt64 = 0
    var pendingCacheReset: (sequence: UInt64, task: Task<Void, Never>)?
    /// One accepted clipboard-relevance verdict per (field session, pasteboard state). The verdict
    /// used to be re-evaluated against the live prefix on every request, and because the clipboard
    /// section precedes the typed prefix in the prompt, every flip rewrote the prompt HEAD and
    /// collapsed the engine's reusable common prefix back to zero (a full re-prefill). A pinned
    /// non-nil verdict keeps the prompt head stable for the field session; a nil verdict keeps
    /// re-evaluating because adding nothing to the prompt cannot destabilize the head, and the
    /// clipboard may only become relevant once more text is typed. A new copy (change count) or a
    /// field switch (focus sequence) always re-evaluates. See `pinnedClipboardContext`.
    struct ClipboardPrefaceMemo {
        let focusSequence: UInt64
        let changeCount: Int
        let value: String?
    }

    var clipboardPrefaceMemo: ClipboardPrefaceMemo?
    /// Coalescing and monotonic-render state for engine partials. The coordinator owns scheduling
    /// and presentation; the value owns the stream's pure state transitions.
    var suggestionStreamingState = SuggestionStreamingState()

    /// Debug-only, text-free input-to-presentation timing; no separate persistent metrics store.
    var suggestionPresentationTiming = SuggestionPresentationTiming()

    /// Pure interaction policies live for the coordinator's lifetime; the only extra task owns a
    /// delayed stream presentation. Work IDs and cancellation protect it when typing resumes.
    var typingCadence = TypingCadence()
    var dismissalMemory = SuggestionDismissalMemory()
    var delayedStreamPresentation: Task<Void, Never>?

    /// One ordinary on-device request may survive matching keys before it becomes visible.
    /// The value owns text reconciliation; this timer bounds how long the model/AX may lag.
    var typingPrediction: TypingPredictionCandidate?
    var typingPredictionExpiry: Task<Void, Never>?

    /// Monotonic cancellation token for the "wait until the host publishes typed text to AX" loop.
    ///
    /// Keystrokes can arrive faster than Chromium publishes contenteditable updates. Without this
    /// token, every key starts its own delayed polling chain and those chains stack up, each doing
    /// synchronous `refreshNow()` calls on the main actor. Bumping the token makes older chains
    /// no-op before they can perform another expensive AX read.
    var hostPublishPollGeneration: UInt64 = 0
    /// Suppresses single-poll `Supported → Blocked → Supported` flicker on the same focused element
    /// so the overlay does not tear down and rebuild on every transient AX redraw. See
    /// `FocusCapabilityFlickerGate` for the rationale and the reproduction (Apple Calendar event
    /// editor).
    var capabilityFlickerGate = FocusCapabilityFlickerGate()
    /// Correlation ID for the most recently built `SuggestionRequest`. Stamped onto every
    /// state-transition log line so all events tied to one suggestion (debounce → generating →
    /// ready → accepted/rejected) can be joined with a single `jq` filter on `request_id`.
    /// `nil` between sessions; replaced when `+Prediction` builds the next request.
    var latestRequestID: String?
    /// The text before the caret the request now in flight was built from. A base model's
    /// completion is exact text following it, so `GhostSpaceBoundary` reads the model's own word
    /// boundary against it (see `SuggestionResult.spacingIsExact`). Kept beside `latestRequestID`
    /// because both describe the in-flight request, and every reader is already guarded by the
    /// work-id check that makes "in flight" meaningful.
    var latestRequestPrecedingText: String?
    /// The last request handed to the engine, kept so an unusable completion can be retried once
    /// with its opening token banned (see `UnusableCompletionRetryPolicy`). The policy only uses it
    /// while its generation still matches the live field.
    var latestDispatchedRequest: SuggestionRequest?
    /// Per-app confidence bar raised after ignored suggestions (see `AdaptiveConfidenceFloor`).
    /// Fed from `suggestionUsageLog`'s finished outcomes, consulted when each request is built.
    var adaptiveConfidenceFloor = AdaptiveConfidenceFloor()
    /// Digit runs inserted by accepting suggestions since the last commit. A number in the committed
    /// text that contains one of these came (at least partly) from the model, so it must never
    /// become a known number (see `KnownPhoneNumbers`).
    var acceptedDigitRunsSinceCommit: [String] = []
    /// Digits of the latest offer amount computed by `VATCounterpartRule`. Derived from the writer's
    /// own entry in the other field, so `PhoneNumberGuard` treats it like a known number.
    var trustedComputedAmountDigits: String?
    /// The offer field being edited, if any: its value when focus arrived and its latest value, so
    /// the other field can be filled when the writer leaves it (see `VATCounterpartRule`).
    var offerFieldSession: OfferFieldSession?
    /// The email address the writer just entered, offered again where a form asks to repeat it.
    var recentEmailMemory = RecentEmailMemory()

    struct OfferFieldSession {
        let elementIdentifier: String
        let reading: FormCounterpartReading
        let valueAtFocus: String
        var latestValue: String
    }
    /// True once the continuation of the active suggestion has been prefetched, so the extra
    /// generation happens at most once per suggestion however many characters are typed through it.
    /// Cleared whenever the session is torn down or replaced.
    var hasPrefetchedContinuation = false
    /// Set when a full acceptance commits its final chunk; consumed by the next `apply`. Lets the
    /// coordinator drop a regeneration that only re-proposes the just-accepted tail before the host
    /// publishes the insert, the Chromium AX-publish race that otherwise loops accept/regenerate/
    /// accept on the last word. See `SuggestionSessionReconciler.isStaleAcceptanceEcho`.
    var lastAcceptedTail: AcceptedSuggestionTail?

    /// Wall-clock moment of the most recent committed acceptance. The stability gate uses its age
    /// to scope the backward-drift hold: only geometry read shortly after our own insert can be
    /// the stale-frame kind, so older backward corrections stay re-anchorable.
    var lastAcceptanceAt: Date?

    /// Bounded string-only memory of recent suggestions for instant re-show on rollback and
    /// re-entry (see `SuggestionAnchorCache`). `cotabbyAnchorReuseDisabled` is the kill switch.
    var suggestionAnchorCache = SuggestionAnchorCache()
    static let anchorReuseDisabledDefaultsKey = "cotabbyAnchorReuseDisabled"
    /// Hidden kill switch for the instant suggestions (`PhraseFastPath`, `PersonalWordModel`); they
    /// are on whenever phrase memory ("Learn from what I type") is.
    static let phraseFastPathDisabledDefaultsKey = "cotabbyPhraseFastPathDisabled"
    static let speculativePrefetchDisabledDefaultsKey = "cotabbySpeculativePrefetchDisabled"
    /// Hidden kill switch for `UnusableCompletionRetryPolicy`; the retry is on unless this is set.
    static let unusableCompletionRetryDisabledDefaultsKey = "cotabbyUnusableCompletionRetryDisabled"
    static let continuationPrefetchDisabledDefaultsKey = "cotabbyContinuationPrefetchDisabled"

    /// Expected post-acceptance context. A speculative result may predate the live generation
    /// only when both its writing session and exact text match. A matching draft in a different
    /// conversation must never receive this exemption. The host-publish poll shares that rule.
    var pendingSpeculativeContext: FocusedInputContext?

    /// One bounded next-word request can outlive consumption of its source word. It has its own
    /// work identity so accepting a correction does not cancel the answer being prepared for it.
    /// Normal edits, dismissal, focus changes, and settings changes cancel both work controllers.
    let continuationWorkController = SuggestionWorkController()
    var preparedContinuation: PreparedContinuation?

    /// Pure state for the bounded "keep owning Tab" window after a final-chunk acceptance. The
    /// coordinator continues to own the timer and input-monitor effects around these transitions.
    var postExhaustionAcceptanceState = PostExhaustionAcceptanceState()
    /// Extra attempts already spent on the current press of the accept key (see `retryInsistently`).
    var insistentRetryCount = 0

    /// Watches the focused field's text across focus events for the moment the writer finished with
    /// it (sent it, or moved on), which is the only moment `phraseMemoryStore` learns from.
    var typedTextCommitDetector = TypedTextCommitDetector()

    init(
        permissionManager: any SuggestionPermissionProviding,
        lowPowerModeProvider: any SuggestionLowPowerModeProviding,
        focusModel: any SuggestionFocusProviding,
        inputMonitor: any SuggestionInputMonitoring,
        overlayController: any SuggestionOverlayControlling,
        suggestionInserter: any SuggestionInserting,
        suggestionEngine: any SuggestionGenerating,
        suggestionSettings: any SuggestionSettingsProviding,
        clipboardContextProvider: any ClipboardContextProviding,
        clipboardRelevanceFilter: any ClipboardRelevanceFiltering,
        visualContextCoordinator: any VisualContextCoordinating,
        interactionState: SuggestionInteractionState,
        workController: SuggestionWorkController,
        configuration: SuggestionConfiguration,
        spellChecker: CurrentWordSpellChecker,
        symSpellCorrector: SymSpellCorrector,
        spellingLanguageResolver: SpellingLanguageResolver = SpellingLanguageResolver(),
        qualityMetricsStore: SuggestionQualityMetricsStore,
        // Not defaulted: a default argument is evaluated in the caller's nonisolated context, and
        // this store is main-actor isolated like the coordinator itself.
        phraseMemoryStore: PhraseMemoryStore,
        personalWordStore: PersonalWordStore,
        suggestionUsageLog: SuggestionUsageLog,
        userDefaults: UserDefaults = .standard
    ) {
        let storedTotalTabAcceptedWordCount = userDefaults.integer(
            forKey: Self.totalTabAcceptedWordCountDefaultsKey)

        self.permissionManager = permissionManager
        self.lowPowerModeProvider = lowPowerModeProvider
        self.focusModel = focusModel
        self.inputMonitor = inputMonitor
        self.overlayController = overlayController
        self.suggestionInserter = suggestionInserter
        self.suggestionEngine = suggestionEngine
        self.suggestionSettings = suggestionSettings
        self.clipboardContextProvider = clipboardContextProvider
        self.clipboardRelevanceFilter = clipboardRelevanceFilter
        self.visualContextCoordinator = visualContextCoordinator
        self.interactionState = interactionState
        self.workController = workController
        self.configuration = configuration
        self.spellChecker = spellChecker
        self.symSpellCorrector = symSpellCorrector
        self.spellingLanguageResolver = spellingLanguageResolver
        self.qualityMetricsStore = qualityMetricsStore
        self.phraseMemoryStore = phraseMemoryStore
        self.personalWordStore = personalWordStore
        self.suggestionUsageLog = suggestionUsageLog
        self.userDefaults = userDefaults
        settingsSnapshot = suggestionSettings.snapshot
        // These collaborators isolate "how overlay/logging works" from "when the coordinator
        // wants to show state," which keeps the coordinator closer to orchestration code.
        overlayPresenter = SuggestionOverlayPresenter(overlayController: overlayController)
        logger = SuggestionDebugLogger()
        totalTabAcceptedWordCount = max(storedTotalTabAcceptedWordCount, 0)
        visualContextStatus = visualContextCoordinator.status
        latestVisualContextText = visualContextCoordinator.latestExcerpt

        overlayState = overlayController.state

        focusModel.snapshotPublisher
            .sink { [weak self] snapshot in
                self?.handleFocusSnapshotChange(snapshot)
            }
            .store(in: &cancellables)

        permissionManager.inputMonitoringGrantedPublisher
            .sink { [weak self] _ in
                self?.handlePermissionChange()
            }
            .store(in: &cancellables)

        permissionManager.screenRecordingGrantedPublisher
            .sink { [weak self] _ in
                self?.handlePermissionChange()
            }
            .store(in: &cancellables)

        lowPowerModeProvider.lowPowerModeChanges
            .sink { [weak self] _ in
                self?.handleLowPowerModeChange()
            }
            .store(in: &cancellables)

        // The monitor and overlay controller are callback-driven. The coordinator translates those
        // callbacks back into its state-machine methods.
        inputMonitor.onEvent = { [weak self] event in
            self?.handleInputEvent(event) ?? false
        }

        inputMonitor.onIdleAcceptKey = { [weak self] in
            self?.requestSuggestionForIdleAcceptKey()
        }

        inputMonitor.onSuppressedSyntheticInput = { [weak self] in
            self?.handleSuppressedSyntheticInput()
        }

        // Fail-open preflight for the active accept tap. The tap should only route a matching key
        // into the coordinator while there is visible suggestion UI. We deliberately do not require
        // `.ready` or even an active session here: a background refresh can move `state`, and if the
        // session has gone stale the coordinator still needs one chance to hide the stale overlay
        // before the tap passes the original key through.
        inputMonitor.shouldConsumeAcceptKeyProvider = { [weak self] in
            guard let self else { return false }
            // Keep owning the accept key through the brief post-acceptance regeneration window too,
            // even though the overlay is hidden then. Otherwise a fast follow-up Tab in that gap
            // falls through to the host app as a real Tab and focus jumps out of the field — the
            // "rapid Tab breaks, slow Tab is fine" report. See `armPostExhaustionAcceptance`.
            guard self.overlayState.isVisible || self.postExhaustionAcceptanceState.isArmed else { return false }
            return true
        }

        overlayController.onStateChange = { [weak self] state in
            guard let self else { return }
            self.overlayState = state
            // Only sit in the synchronous keystroke critical path while a suggestion is actually
            // visible. With the overlay hidden, Cotabby observes via a listen-only tap that does
            // not gate event delivery to other apps (issue #328).
            switch state {
            case .visible:
                self.inputMonitor.setAcceptInterceptionActive(true)
                self.focusModel.setTracksGeometryClosely(true, reason: "suggestion")
            case .hidden:
                self.inputMonitor.setAcceptInterceptionActive(false)
                self.focusModel.setTracksGeometryClosely(false, reason: "suggestion")
                // A hidden overlay ends any post-exhaustion Tab-ownership window. Every teardown and
                // abort path hides the overlay, so ending the window here is the single catch-all
                // that returns the accept key to the host (and cancels the backstop timer) once the
                // window is genuinely over. The `.exhausted` accept re-arms *after* its own
                // `hideOverlay` call, so this never cancels a window that was just opened.
                self.clearPostExhaustionAcceptanceWindow()
            }
        }

        visualContextCoordinator.onStateChange = { [weak self] status, excerpt in
            guard let self else { return }
            let lostContext = self.latestVisualContextText != nil && excerpt == nil
            self.visualContextStatus = status
            self.latestVisualContextText = excerpt
            // Expired or invalidated screen text must not survive indirectly in a visible tail,
            // cached completion, or late result. New requests can use the live draft immediately.
            if lostContext {
                self.suggestionAnchorCache = SuggestionAnchorCache()
                self.cancelPredictionWork()
                self.clearSuggestion()
                self.hideOverlay(reason: "Overlay hidden because screen context was invalidated.")
                if case .disabled = self.state { return }
                self.state = .idle
            }
        }

        visualContextCoordinator.onInjectedContextReady = { [weak self] identity in
            guard let self, self.focusModel.snapshot.context?.identity == identity else { return }
            // A host may expose identical URL/title/geometry for two chats. Changed screen text
            // is then our next navigation signal. Retire visible tails as well as cached/async
            // work; keeping an old tail stable would let it outlive arbitrarily many refreshes.
            self.suggestionAnchorCache = SuggestionAnchorCache()
            self.clipboardPrefaceMemo = nil
            self.cancelPredictionWork()
            self.clearSuggestion()
            self.hideOverlay(reason: "Overlay hidden because screen context changed.")
            self.schedulePredictionForCurrentFocusIfPossible(matching: identity)
        }
        visualContextCoordinator.refreshContextProvider = { [weak self] in
            self?.currentVisualRefreshContext()
        }

        suggestionSettings.snapshotPublisher
            .dropFirst()
            .sink { [weak self] snapshot in
                self?.handleSuggestionSettingsChange(snapshot)
            }
            .store(in: &cancellables)
    }

    /// Exposes the latest cancellation token for the split extension files.
    var currentWorkID: UInt64 {
        workController.currentWorkID
    }
}
