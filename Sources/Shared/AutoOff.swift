import Foundation

/// Auto-off timer logic (pure, unit-testable).
///
/// Keep-awake is a convenience, not a safety mechanism, so the countdown lives
/// in the app — if the app dies the helper watchdog restores sleep anyway.
public enum AutoOff {
    /// Selectable durations (minutes). `0` means "no auto-off" (stay on until off).
    public static let presetMinutes = [15, 30, 60, 120, 240]

    /// What picking a duration should do.
    ///
    /// "Keep awake for 15 minutes" is one intention, and asking someone to
    /// perform it as two steps — flip the switch, then find the timer — is
    /// asking them to do the app's bookkeeping. So choosing a duration turns
    /// keep-awake on if it isn't already.
    public enum Request: Equatable {
        /// Auto mode decides activation from power and safety; a countdown would
        /// disarm the feature out from under it, so the control does nothing
        /// while that's on. (The UI disables it and says why rather than letting
        /// it look live.)
        case ignoredInAutoMode
        /// "No limit" — drop any countdown. Deliberately does *not* turn
        /// keep-awake off: removing the time limit is not the same request as
        /// stopping, and the master toggle is right there for stopping.
        case cancelTimer
        /// Already on, so there's nothing to switch — just (re)start the count.
        case armTimer(minutes: Int)
        /// Off, and a duration was asked for. Turn it on; the countdown starts
        /// when the write is confirmed, so a refusal on safety grounds leaves no
        /// timer running for a state that never happened.
        case enableThenArmTimer(minutes: Int)
    }

    public static func request(minutes: Int, isEnabled: Bool, autoModeOn: Bool) -> Request {
        if autoModeOn { return .ignoredInAutoMode }
        guard minutes > 0 else { return .cancelTimer }
        return isEnabled ? .armTimer(minutes: minutes) : .enableThenArmTimer(minutes: minutes)
    }

    /// Label for the duration control, e.g. `No limit`, `15 min`, `1 hour`.
    public static func durationLabel(minutes: Int) -> String {
        minutes > 0 ? optionLabel(minutes: minutes) : L10n.tr("No limit")
    }

    /// When a timer started `minutes` ago from `start` should fire.
    public static func deadline(from start: Date, minutes: Int) -> Date {
        start.addingTimeInterval(TimeInterval(minutes) * 60)
    }

    /// Seconds left until `deadline` (never negative).
    public static func remaining(deadline: Date, now: Date) -> TimeInterval {
        max(0, deadline.timeIntervalSince(now))
    }

    /// True once `now` has reached or passed `deadline`.
    public static func isExpired(deadline: Date, now: Date) -> Bool {
        now >= deadline
    }

    /// Countdown like `1:05:09` (with hours) or `9:42` (under an hour).
    public static func formatCountdown(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }

    /// Menu label for a duration, e.g. `15 min`, `1 hour`, `2 hours`.
    public static func optionLabel(minutes: Int) -> String {
        guard minutes % 60 == 0 else { return L10n.format("%d min", minutes) }
        let h = minutes / 60
        return h == 1 ? L10n.tr("1 hour") : L10n.format("%d hours", h)
    }
}
