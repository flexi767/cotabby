import Foundation

/// Raises the confidence bar in an app after the writer keeps ignoring suggestions there, and drops
/// it again the moment they take one.
///
/// A fixed floor is a blunt tool: measured on this Mac, -1.5 withheld about half of all real
/// completions, good ones included. But a run of ignored suggestions in one app is evidence that the
/// model is guessing badly *there, right now* (an unfamiliar thread, a language switch, a code
/// block). Showing fewer, surer suggestions for a while is cheaper for the writer than showing more
/// noise; one acceptance says the model has found its footing, so the bar resets at once.
///
/// Pure value type: the coordinator owns one instance, feeds it finished outcomes, and asks it for
/// the floor when building each request. It holds per-app counters only, never text.
///
/// Off by default (hidden key `cotabbyAdaptiveConfidenceFloorEnabled`). The thresholds below are
/// placeholders until the opt-in usage log has recorded enough (confidence, outcome) pairs to pick
/// them: `scripts/usage_log_to_eval_cases.py` prints acceptance by confidence bucket for that.
struct AdaptiveConfidenceFloor: Equatable {
    struct Configuration: Equatable {
        /// Consecutive ignored suggestions in one app before the floor rises.
        var ignoresBeforeRaising = 3
        /// The floor applied while raised (mean token log-probability).
        var raisedFloor = -1.5
        /// How long a raise lasts without an acceptance.
        var holdSeconds: TimeInterval = 300

        static let `default` = Configuration()
    }

    static let enabledDefaultsKey = "cotabbyAdaptiveConfidenceFloorEnabled"

    var configuration: Configuration = .default
    private var appStates: [String: AppState] = [:]

    private struct AppState: Equatable {
        var consecutiveIgnores = 0
        var raisedUntil: Date?
    }

    /// The floor to apply for a request in `bundleIdentifier`, or nil for "use the global one".
    func floor(for bundleIdentifier: String, now: Date) -> Double? {
        guard let until = appStates[bundleIdentifier]?.raisedUntil, now < until else { return nil }
        return configuration.raisedFloor
    }

    /// Feeds one finished suggestion outcome. Only shown suggestions carry a signal: a suppressed
    /// one was never seen, and an abandoned one (nothing typed) says nothing about its quality.
    mutating func record(_ outcome: SuggestionUsageRecord.Outcome, bundleIdentifier: String, now: Date) {
        var state = appStates[bundleIdentifier] ?? AppState()
        switch outcome {
        case .accepted, .acceptedPartially, .typedThrough:
            state = AppState()
        case .ignored:
            state.consecutiveIgnores += 1
            if state.consecutiveIgnores >= configuration.ignoresBeforeRaising {
                state.raisedUntil = now.addingTimeInterval(configuration.holdSeconds)
            }
        case .abandoned, .suppressed:
            return
        }
        appStates[bundleIdentifier] = state
    }
}
