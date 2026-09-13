import AppKit
import SwiftUI
import Foundation
import OSLog

/// The user-facing keep-awake mode shown in the popover's picker. Backed by
/// the persisted auto/armed/charging fields; see `AppState.keepAwakeMode`.
enum KeepAwakeMode: String, CaseIterable, Identifiable {
    case always
    case onlyWhileCharging
    case off

    var id: String { rawValue }

    var label: String {
        switch self {
        case .always: return "Always"
        case .onlyWhileCharging: return "Only while charging"
        case .off: return "Off"
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    private static let logger = Logger(
        subsystem: LidlessIdentity.diagnosticSubsystem(
            appBundleID: Bundle.main.bundleIdentifier
        ),
        category: "reconciliation"
    )
    @Published var isEnabled = false
    @Published var helperInstalled = false
    @Published var helperNeedsApproval = false
    @Published var batteryDescription = ""
    /// Current battery charge (0–100) and whether on AC power. Drives the
    /// popover status strip (icon + "Battery 74%").
    @Published var batteryPercent = 0
    @Published var batteryOnAC = false
    @Published var lastError: String?

    /// Explains a toggle that moved by itself. Its own channel, so an external
    /// change and a safety pause can both be on screen at once.
    @Published var externalNotice: String?

    /// A terminal write/read-back failure, separate from policy and helper notes.
    @Published var verificationNotice: String?

    /// True when using the privileged helper; false when on the M1 admin-prompt fallback.
    @Published var usingHelper = false

    /// User-tunable safety preferences (persisted).
    @Published var settings: SafetySettings = .default

    /// Auto-mode master-toggle intent (persisted): whether the user wants
    /// keep-awake armed. In auto mode the *live* state (`isEnabled`) is derived
    /// from `armed` gated by power + safety — see `reconcile()`. Unused in manual
    /// mode, where the toggle drives `isEnabled` directly; it's (re-)seeded on the
    /// way into auto mode rather than tracked continuously.
    @Published var armed = false

    /// The currently-unmet checks to surface in the popover's auto-mode warning,
    /// or empty when there's nothing to warn about. Non-empty only when auto mode
    /// is on, the feature is armed, but keep-awake isn't live right now.
    var autoWarningReasons: [SafetyReason] {
        guard settings.autoEnableWhenCharging, armed, !isEnabled else { return [] }
        return SafetyEvaluator.allUnmetReasons(battery: currentBattery,
                                               thermalSerious: thermalSerious(),
                                               settings: settings)
    }

    /// The three user-facing modes. Replaces the old trio of a master toggle,
    /// the auto-enable switch, and "Only while charging": all three expressed
    /// one binary outcome, and their combinations were hard to predict.
    var keepAwakeMode: KeepAwakeMode {
        if settings.autoEnableWhenCharging {
            guard armed else { return .off }
            return settings.onlyWhileCharging ? .onlyWhileCharging : .always
        }
        // Legacy manual builds had no mode concept; the live state stands in.
        return isEnabled ? .always : .off
    }

    /// Switch modes. Maps onto the persisted auto/armed/charging fields, so the
    /// reconciler, safety checks, and helper need no changes.
    func setKeepAwakeMode(_ mode: KeepAwakeMode) {
        switch mode {
        case .off:
            if settings.autoEnableWhenCharging {
                setArmed(false)
            } else {
                setEnabled(false, origin: .user)
            }
        case .always, .onlyWhileCharging:
            let onlyCharging = mode == .onlyWhileCharging
            if settings.autoEnableWhenCharging {
                if settings.onlyWhileCharging != onlyCharging {
                    var s = settings
                    s.onlyWhileCharging = onlyCharging
                    updateSettings(s)
                } else if !armed {
                    setArmed(true)
                }
            } else {
                var s = settings
                s.autoEnableWhenCharging = true
                s.onlyWhileCharging = onlyCharging
                updateSettings(s) // entering auto mode arms and reconciles
                if !armed { setArmed(true) }
            }
        }
    }

    /// Launch-at-login state (the app itself).
    @Published var launchAtLogin = false

    /// Auto-off timer: minutes after which keep-awake turns itself off
    /// (`0` = never). Persisted.
    @Published var autoOffMinutes = 0
    /// When the active auto-off timer will fire; nil when not counting down.
    @Published var autoOffDeadline: Date?
    /// Human countdown (e.g. `1:05:09`) shown while a timer is active.
    @Published var autoOffRemaining = ""

    /// Whether the user has finished first-run onboarding (persisted).
    @Published var onboardingComplete = false

    private let helper = HelperManager()
    /// Reads the flag on every path — `pmset -g` needs no privileges — and also
    /// writes it when the helper isn't installed.
    private let power = PowerManager()
    private let battery = BatteryMonitor()
    private let store: SettingsStore
    private let loginItem = LoginItemManager()
    private lazy var onboarding = OnboardingController(state: self)

    /// The app's Sparkle updater. Owned here rather than by `LidlessApp` so the
    /// settings window controller below can hand it to `SettingsView`.
    let updater: UpdaterController

    private lazy var settingsWindow = SettingsWindowController(
        contentSize: SettingsView.preferredSize
    ) { [weak self] in
        guard let self else { return AnyView(EmptyView()) }
        return AnyView(
            SettingsView()
                .environmentObject(self)
                .environmentObject(self.updater)
        )
    }

    /// Marketing version shown in the menu.
    var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }
    private var batteryTimer: Timer?
    private var heartbeatTimer: Timer?
    private var autoOffTimer: Timer?

    /// Last-known "helper is usable" value, so we can detect it flipping on at
    /// runtime (right after the user approves it) and prompt a restart.
    private var helperWasUsable = false
    /// True once the system flag has been read successfully this session.
    private var hasConfirmedState = false
    /// Target owned by the current bounded write operation. Its mutation token
    /// rejects late replies after a newer safety decision supersedes it.
    private var activeWriteTarget: Bool?
    private var sampledBattery = BatteryInfo.unknown
    /// Rejects async state replies that have been superseded.
    private var sync = StateSync()
    /// Rejects an entire stale power sample before UI or policy effects.
    private var powerSamples = PowerSampleGeneration()
    /// Polling can recover display state but cannot authorize charging-gated ON.
    private var powerNotificationsActive = false
    private var onboardingActive = false
    private var didBecomeActiveObserver: NSObjectProtocol?

    init() {
        let store = SettingsStore()
        if Bundle.main.bundleIdentifier == LidlessIdentity.productionAppBundleID {
            store.migrateLegacyPreferencesIfNeeded()
        }
        self.store = store
        // Sparkle may schedule a check while it starts. Constructing its
        // controller only after migration ensures it sees the upstream user's
        // automatic-check preference on this first launch.
        updater = UpdaterController()
        settings = store.load()
        armed = store.loadArmed()
        autoOffMinutes = store.loadAutoOffMinutes()
        onboardingComplete = store.loadOnboardingComplete()
        launchAtLogin = loginItem.isEnabled
        refreshHelperStatus()
        refreshHelperRegistrationIfUpdated()
        helperWasUsable = usingHelper
        // Subscribe before the first sample. Without this live source, polling is
        // recovery-only and charging-gated activation stays fail-closed.
        powerNotificationsActive = battery.start { [weak self] in
            Task { @MainActor in self?.handlePowerSourceChange() }
        }
        if !powerNotificationsActive {
            let message = "Power-source notifications are unavailable; keep-awake was disabled."
            lastError = message
            setEnabled(false, note: message, origin: .safety)
        }
        refreshState()
        refreshBattery { [weak self] info in
            self?.reconcile(supersedeInFlight: false,
                            sample: info,
                            trigger: "startup")
        }
        // Independent repair backstop for missed notifications and flag drift.
        batteryTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        // Re-check the helper whenever the app comes forward — e.g. when the user
        // returns from approving it in System Settings — so we notice it being
        // enabled without requiring a manual restart.
        didBecomeActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.recheckHelper()
                // Also re-read the flag: it may have been changed from a Terminal
                // the user was just in. `recheckHelper` only refreshes on the rare
                // helper unusable→usable transition.
                self?.refreshState()
            }
        }
        // First launch shows onboarding once (persisted so closing it early won't
        // re-nag). A relaunch triggered mid-onboarding resumes the flow instead.
        if store.loadResumeOnboarding() {
            store.saveResumeOnboarding(false)
            DispatchQueue.main.async { [weak self] in self?.showOnboarding() }
        } else if !onboardingComplete {
            onboardingComplete = true
            store.saveOnboardingComplete(true)
            DispatchQueue.main.async { [weak self] in self?.showOnboarding() }
        }
    }

    deinit {
        battery.stop()
        batteryTimer?.invalidate()
        heartbeatTimer?.invalidate()
        autoOffTimer?.invalidate()
        if let didBecomeActiveObserver {
            NotificationCenter.default.removeObserver(didBecomeActiveObserver)
        }
    }

    // MARK: Onboarding

    /// Present the first-run setup window (also reachable from Settings).
    func showOnboarding() {
        onboardingActive = true
        onboarding.show()
    }

    /// Mark onboarding done, persist it, and close the window.
    func completeOnboarding() {
        onboardingActive = false
        onboardingComplete = true
        store.saveOnboardingComplete(true)
        store.saveResumeOnboarding(false)
        onboarding.close()
    }

    // MARK: Settings

    /// Present the Settings window from the menu-bar popover.
    func showSettings() {
        settingsWindow.show()
    }

    func updateSettings(_ new: SafetySettings) {
        let wasAuto = settings.autoEnableWhenCharging
        settings = new
        store.save(new)
        if new.autoEnableWhenCharging {
            if !wasAuto {
                // Opting into auto mode *is* the request to have keep-awake on, so
                // arm it rather than inheriting the current live state — otherwise
                // switching on "Automatically enable when charging" while
                // keep-awake happens to be off (the very case this feature exists
                // for) would visibly do nothing. Also drop any manual auto-off
                // countdown, which would just fight auto mode's own activation.
                armed = true
                store.saveArmed(armed)
                cancelAutoOff()
            }
            reconcileNow()
        } else if let pending = autoWrite.inFlightTarget {
            // Leaving auto mode owns the pending result. Clear its coordinator
            // claim now, then settle from one fresh asynchronous power sample.
            autoWrite.clear()
            refreshBattery { [weak self] info in
                guard let self, !self.settings.autoEnableWhenCharging else { return }
                let conditions = SafetySnapshot(
                    battery: info,
                    thermalSerious: self.thermalSerious()
                )
                let settled = AutoEnablePolicy.handoffToManual(
                    pendingTarget: pending,
                    conditions: conditions,
                    settings: self.settings
                )
                self.setEnabled(settled,
                                note: nil,
                                origin: .auto,
                                conditions: conditions)
            }
        } else {
            // Leaving auto mode hands activation back to the user, so the auto-off
            // countdown becomes applicable again — re-arm it if one is configured
            // and keep-awake is currently on.
            if wasAuto, isEnabled { armAutoOff() }
            evaluateSafety()
        }
    }

    /// Set the auto-mode armed intent, persist it, and reconcile the live state.
    private func setArmed(_ on: Bool) {
        armed = on
        store.saveArmed(on)
        reconcileNow()
    }

    /// Auto mode: derive the live keep-awake state from `armed` gated by the
    /// enabled safety checks, flipping only the live state (never the `armed`
    /// intent). When conditions aren't met the feature stays armed and the
    /// popover's warning explains why it isn't currently active.
    ///
    /// The poll's entry point. No-ops when auto mode is off, when the effective
    /// state already matches, or while an earlier write is still outstanding or
    /// has already concluded this turn — see `autoWrite`. `origin: .auto` because
    /// this fires unprompted on the timer and must stay silent.
    func reconcile() {
        reconcile(supersedeInFlight: false, trigger: "state")
    }

    /// User intent and power notifications may supersede an older in-flight
    /// target. In particular, an unplug must issue a corrective off immediately.
    private func reconcileNow() {
        reconcile(supersedeInFlight: true, trigger: "settings")
    }

    private func reconcile(supersedeInFlight: Bool,
                           sample: BatteryInfo? = nil,
                           trigger: String) {
        guard settings.autoEnableWhenCharging else { return }
        guard supersedeInFlight || autoWrite.mayWrite else { return }
        guard let battery = sample else {
            refreshBattery { [weak self] info in
                self?.reconcile(supersedeInFlight: supersedeInFlight,
                                sample: info,
                                trigger: trigger)
            }
            return
        }
        let conditions = SafetySnapshot(battery: battery,
                                        thermalSerious: thermalSerious())
        let effective = AutoEnablePolicy.effectiveState(pendingTarget: autoWrite.inFlightTarget,
                                                        live: isEnabled)
        guard let target = AutoEnablePolicy.target(armed: armed,
                                                   currentlyEnabled: effective,
                                                   battery: conditions.battery,
                                                   thermalSerious: conditions.thermalSerious,
                                                   settings: settings) else { return }
        if target && !PowerNotificationPolicy.allowsChargingGatedEnable(
            subscriptionActive: powerNotificationsActive,
            signedHelperAvailable: helperInstalled
        ) {
            autoWrite.clear()
            lastError = powerNotificationsActive
                ? "The signed helper is required for automatic charging activation."
                : "Power-source notifications are unavailable; automatic activation is disabled."
            return
        }
        Self.logger.notice(
            "desired_state trigger=\(trigger, privacy: .public) armed=\(self.armed, privacy: .public) power=\(battery.powerState.rawValue, privacy: .public) effective=\(effective, privacy: .public) desired=\(target, privacy: .public)"
        )
        autoWrite.issued(target: target)
        setEnabled(target, note: nil, origin: .auto, conditions: conditions)
    }

    /// The claim on auto mode's outstanding write. Held across the helper's async
    /// round trip, so a reply that reads back wrong can't immediately provoke
    /// another write. See `AutoWriteCoordinator`.
    private var autoWrite = AutoWriteCoordinator()

    /// The exact last sample, including `.unknown`; display booleans must never
    /// erase uncertainty before a safety decision.
    private var currentBattery: BatteryInfo { sampledBattery }

    /// "Keep awake for N minutes" — the whole gesture, in one call.
    ///
    /// Turns keep-awake on when it isn't already, because that is plainly what
    /// asking for fifteen minutes of it means. Making someone flip the switch
    /// first and *then* set a duration is making them do the bookkeeping.
    ///
    /// Note the ordering when it has to enable: the duration is persisted first,
    /// then the write goes out, and the countdown is armed from the write's
    /// confirmation (via `updateAutoOff(for:)`). So if the safety policy refuses
    /// — flat battery, running hot — no timer is left counting down for a state
    /// the Mac never entered.
    func keepAwakeFor(minutes: Int) {
        autoOffMinutes = minutes
        store.saveAutoOffMinutes(minutes)
        if settings.autoEnableWhenCharging {
            // Always mode: the countdown disarms the intent; reconcile turns
            // the flag off. "No limit" just drops the countdown.
            setArmed(true)
            if minutes > 0 { armAutoOff() } else { cancelAutoOff() }
            return
        }
        let request = AutoOff.request(minutes: minutes,
                                      isEnabled: isEnabled,
                                      autoModeOn: settings.autoEnableWhenCharging)
        guard request != .ignoredInAutoMode else { return }
        switch request {
        case .ignoredInAutoMode:
            break
        case .cancelTimer:
            cancelAutoOff()
        case .armTimer:
            armAutoOff()
        case .enableThenArmTimer:
            setEnabled(true, origin: .user)
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        if let err = loginItem.setEnabled(enabled) {
            lastError = err
            launchAtLogin = loginItem.isEnabled
        } else {
            // status can lag right after register/unregister; trust the action.
            launchAtLogin = enabled
        }
    }

    private func thermalSerious() -> Bool {
        let state = ProcessInfo.processInfo.thermalState
        return state == .serious || state == .critical
    }

    /// Auto-disable when the live state, or an in-flight enable, violates policy.
    func evaluateSafety(using sample: BatteryInfo? = nil,
                        trigger: String = "safety") {
        guard isEnabled || activeWriteTarget == true else { return }
        guard let info = sample else {
            refreshBattery { [weak self] fresh in
                self?.evaluateSafety(using: fresh, trigger: trigger)
            }
            return
        }
        if let reason = SafetyEvaluator.reasonToDisable(battery: info,
                                                        thermalSerious: thermalSerious(),
                                                        settings: settings) {
            Self.logger.notice(
                "desired_state trigger=\(trigger, privacy: .public) power=\(info.powerState.rawValue, privacy: .public) desired=false reason=\(String(describing: reason), privacy: .public)"
            )
            setEnabled(false, note: reason.message, origin: .safety)
        }
    }

    // MARK: Helper lifecycle

    func refreshHelperStatus() {
        helperInstalled = helper.isEnabled
        helperNeedsApproval = helper.requiresApproval
        usingHelper = helperInstalled
    }

    /// The app's current build number (`CFBundleVersion`).
    private var currentBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
    }

    private func storeCurrentHelperBuild() {
        store.saveLastHelperBuild(currentBuild)
    }

    /// After an app update the helper binary is re-signed and its launchd job can
    /// keep a stale launch record, so the daemon fails to start (EX_CONFIG) and
    /// XPC calls hang — the toggle then silently does nothing. On the first launch
    /// of a new build, probe the registered daemon; only if it's unreachable do we
    /// rebuild its registration (which may require re-approval). Healthy updates
    /// are left untouched, so they don't needlessly prompt for approval.
    private func refreshHelperRegistrationIfUpdated() {
        guard !currentBuild.isEmpty else { return }
        guard store.loadLastHelperBuild() != currentBuild else { return }
        storeCurrentHelperBuild()
        guard helper.isEnabled else { return }
        helper.checkReachable { [weak self] reachable in
            guard let self, !reachable else { return }
            self.repairHelper()
        }
    }

    /// Re-read helper status; if it just became usable (the user approved it while
    /// the app was running), pick up its keep-awake state and prompt a restart so
    /// the app fully switches onto the privileged helper.
    func recheckHelper() {
        let wasUsable = helperWasUsable
        refreshHelperStatus()
        helperWasUsable = usingHelper
        guard !wasUsable, usingHelper else { return }
        refreshState()
        promptRestartAfterHelperEnabled()
    }

    /// Tell the user the helper is now active and offer to relaunch. The privileged
    /// XPC connection is most reliable from a fresh launch, so a restart is the
    /// simplest way to finish setup.
    private func promptRestartAfterHelperEnabled() {
        // If this happened mid-onboarding, resume the flow after the relaunch.
        if onboardingActive { store.saveResumeOnboarding(true) }

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Background helper enabled"
        alert.informativeText = "Restart Lidless to finish connecting to the background helper."
        alert.addButton(withTitle: "Restart Now")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            relaunch()
        }
    }

    /// Spawn a fresh instance of the app, then terminate this one.
    private func relaunch() {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NSApp.terminate(nil)
        }
    }

    func installHelper() {
        // If the daemon is already registered and just awaiting approval, don't
        // re-register (that throws once pending and would swallow the open) —
        // just take the user to Login Items.
        if helper.requiresApproval {
            openLoginItems()
            return
        }
        do {
            try helper.register()
            let wasUsable = helperWasUsable
            refreshHelperStatus()
            helperWasUsable = usingHelper
            if helper.requiresApproval {
                lastError = "Approve Lidless in System Settings ▸ Login Items."
                helper.openLoginItemsSettings()
            } else {
                lastError = nil
                // Rare: registered and immediately usable (already approved). Treat
                // it as the same enable transition the approval path would hit.
                if !wasUsable, usingHelper {
                    refreshState()
                    promptRestartAfterHelperEnabled()
                }
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Open System Settings ▸ Login Items so the user can approve the helper.
    /// Kept separate from `installHelper()` so re-registration can never swallow
    /// the open.
    func openLoginItems() {
        lastError = "Approve Lidless in System Settings ▸ Login Items."
        helper.openLoginItemsSettings()
        refreshHelperStatus()
    }

    // MARK: State

    /// Read the real `SleepDisabled` flag and bring the UI into step with it.
    ///
    /// Always read directly rather than asking the helper: the XPC reply is a
    /// plain `Bool`, so a `pmset` failure inside the daemon would arrive as a
    /// confident "off". Reading needs no privileges, so there's nothing to gain
    /// by routing it through root — and an unknown stays an unknown.
    func refreshState() {
        let token = sync.beginRead()
        power.isSleepDisabled { [weak self] observed in
            self?.applyObserved(observed, token)
        }
    }

    private func applyObserved(_ observed: Bool?, _ token: StateSync.ReadToken) {
        guard sync.shouldApply(token) else { return }   // superseded by a newer read or a write

        // The bounded write operation performs its own mandatory read-back.
        // Periodic reads cannot reinterpret an intermediate attempt as drift.
        guard activeWriteTarget == nil else { return }

        switch StateReconciler.reconcile(shown: isEnabled,
                                         hasBaseline: hasConfirmedState,
                                         observed: observed) {
        case .unknown:
            break                                       // keep the last-known state
        case .inSync:
            hasConfirmedState = true                    // no side effects, by construction
        case .adopt(let enabled):
            hasConfirmedState = true
            adoptSystemState(enabled)
        case .drift(let change):
            hasConfirmedState = true
            // Set before adopting: adopting `true` can synchronously trip a safety
            // pause, and the notice should already be in place when it does.
            externalNotice = change.message
            adoptSystemState(change.nowEnabled)
        }
    }

    /// Bring `isEnabled` in line with reality *without* touching the flag, running
    /// the side effects `setEnabled` would have run for this state.
    ///
    /// Only ever reached for a real transition — `reconcile` returns `.inSync`
    /// when the values already agree — so the 30-second poll can't re-arm the
    /// auto-off timer or restart the heartbeat on every pass.
    private func adoptSystemState(_ enabled: Bool, reconcileAfter: Bool = true) {
        isEnabled = enabled
        sync.beginMutation()
        manageHeartbeat()
        updateAutoOff(for: enabled)
        guard reconcileAfter else { return }
        if settings.autoEnableWhenCharging {
            reconcile()
        } else if enabled {
            evaluateSafety()
        }
    }

    /// User flipped the toggle: `.user` origin so any failure or refusal surfaces
    /// a visible alert (not just the easy-to-miss inline note).
    func toggle() { setEnabled(!isEnabled, origin: .user) }

    /// Set keep-awake through one bounded request plus mandatory read-back. The
    /// helper owns all helper-backed retries; the app never queues a second
    /// enable behind work that may still be running.
    func setEnabled(_ target: Bool,
                    note: String? = nil,
                    origin: SetOrigin = .user,
                    conditions: SafetySnapshot? = nil,
                    deadline: ProcessDeadline? = nil) {
        // Created at public request entry unless a power notification supplies
        // its earlier deadline for the entire notification-to-verification path.
        let operationDeadline = deadline ??
            ProcessDeadline(after: SafetyTiming.maximumUnplugResponse)
        if StateReconciler.clearsExternalNotice(origin) { externalNotice = nil }
        if origin != .auto { autoWrite.clear() }

        verificationNotice = nil
        let token = sync.beginMutation()
        activeWriteTarget = target
        Self.logger.notice(
            "write_started target=\(target, privacy: .public) origin=\(String(describing: origin), privacy: .public)"
        )

        guard target, conditions == nil else {
            beginWrite(target: target,
                       token: token,
                       origin: origin,
                       resultMessage: note,
                       conditions: conditions,
                       deadline: operationDeadline)
            return
        }
        refreshBattery(deadline: operationDeadline.capped(to: SafetyTiming.readTimeout)) {
            [weak self] info in
            guard let self else { return }
            self.beginWrite(
                target: target,
                token: token,
                origin: origin,
                resultMessage: note,
                conditions: SafetySnapshot(battery: info,
                                           thermalSerious: self.thermalSerious()),
                deadline: operationDeadline
            )
        }
    }

    private func beginWrite(target: Bool,
                            token: StateSync.MutationToken,
                            origin: SetOrigin,
                            resultMessage: String?,
                            conditions: SafetySnapshot?,
                            deadline: ProcessDeadline) {
        guard sync.shouldApply(token), activeWriteTarget == target else { return }
        if target,
           let checked = conditions,
           let blocker = SafetyEvaluator.reasonToDisable(
               battery: checked.battery,
               thermalSerious: checked.thermalSerious,
               settings: settings
           ) {
            activeWriteTarget = nil
            if origin == .auto { autoWrite.clear() }
            lastError = blocker.message
            Self.logger.error(
                "write_refused target=true reason=\(String(describing: blocker), privacy: .public)"
            )
            if origin == .user {
                presentFailureAlert(target: target, message: blocker.blockedMessage)
            }
            return
        }

        Self.logger.info(
            "write_attempt target=\(target, privacy: .public) path=\(self.helperInstalled ? "helper" : "authorization", privacy: .public)"
        )
        if helperInstalled {
            let helperDeadline = deadline
                .reserving(SafetyTiming.readTimeout)
                .capped(to: SafetyTiming.helperReplyTimeout)
            helper.setKeepAwake(target, deadline: helperDeadline) { [weak self] ok, error in
                self?.verifyWrite(target: target,
                                  token: token,
                                  origin: origin,
                                  resultMessage: resultMessage,
                                  writeSucceeded: ok,
                                  latestError: error,
                                  correctionAllowed: true,
                                  helperBacked: true,
                                  deadline: deadline)
            }
        } else {
            let authorizationDeadline = deadline
                .reserving(SafetyTiming.readTimeout)
                .capped(to: SafetyTiming.authorizationTimeout)
            power.setSleepDisabled(target, deadline: authorizationDeadline) {
                [weak self] result in
                switch result {
                case .success:
                    self?.verifyWrite(target: target,
                                      token: token,
                                      origin: origin,
                                      resultMessage: resultMessage,
                                      writeSucceeded: true,
                                      latestError: nil,
                                      correctionAllowed: true,
                                      helperBacked: false,
                                      deadline: deadline)
                case .failure(let failure):
                    let terminalAuthorizationDecision =
                        failure == .cancelled || failure == .denied
                    self?.verifyWrite(target: target,
                                      token: token,
                                      origin: origin,
                                      resultMessage: resultMessage,
                                      writeSucceeded: false,
                                      latestError: failure.message,
                                      correctionAllowed: !terminalAuthorizationDecision,
                                      helperBacked: false,
                                      deadline: deadline)
                }
            }
        }
    }

    private func verifyWrite(target: Bool,
                             token: StateSync.MutationToken,
                             origin: SetOrigin,
                             resultMessage: String?,
                             writeSucceeded: Bool,
                             latestError: String?,
                             correctionAllowed: Bool,
                             helperBacked: Bool,
                             deadline: ProcessDeadline) {
        guard sync.shouldApply(token), activeWriteTarget == target else {
            Self.logger.info(
                "write_callback_ignored target=\(target, privacy: .public) reason=superseded"
            )
            return
        }
        power.isSleepDisabled(deadline: deadline.capped(to: SafetyTiming.readTimeout)) {
            [weak self] observed in
            self?.finishWrite(target: target,
                              token: token,
                              origin: origin,
                              resultMessage: resultMessage,
                              writeSucceeded: writeSucceeded,
                              observed: observed,
                              latestError: latestError,
                              correctionAllowed: correctionAllowed,
                              helperBacked: helperBacked)
        }
    }

    private func finishWrite(target: Bool,
                             token: StateSync.MutationToken,
                             origin: SetOrigin,
                             resultMessage: String?,
                             writeSucceeded: Bool,
                             observed: Bool?,
                             latestError: String?,
                             correctionAllowed: Bool,
                             helperBacked: Bool) {
        guard sync.shouldApply(token), activeWriteTarget == target else {
            Self.logger.info(
                "write_callback_ignored target=\(target, privacy: .public) reason=superseded"
            )
            return
        }

        let observedText = observed.map { $0 ? "true" : "false" } ?? "unknown"
        Self.logger.info(
            "write_verification target=\(target, privacy: .public) command_ok=\(writeSucceeded, privacy: .public) observed=\(observedText, privacy: .public)"
        )
        let decision = VerifiedWritePolicy.decision(
            target: target,
            attempt: VerifiedWritePolicy.maximumAttempts,
            writeSucceeded: writeSucceeded,
            observed: observed
        )

        if case .verified = decision {
            activeWriteTarget = nil
            autoWrite.resolved()
            isEnabled = target
            hasConfirmedState = true
            verificationNotice = nil
            lastError = resultMessage
            manageHeartbeat()
            updateAutoOff(for: target)
            Self.logger.notice(
                "write_terminal outcome=verified target=\(target, privacy: .public)"
            )
            return
        }

        guard case .terminal(let failure) = decision else { return }
        activeWriteTarget = nil
        autoWrite.resolved()
        let message = writeFailureMessage(target: target,
                                          failure: failure,
                                          underlying: latestError)
        verificationNotice = message
        lastError = message
        if let observed {
            hasConfirmedState = true
            adoptSystemState(observed, reconcileAfter: false)
        } else {
            hasConfirmedState = false
        }
        Self.logger.error(
            "write_terminal outcome=failed target=\(target, privacy: .public) failure=\(String(describing: failure), privacy: .public)"
        )

        // Every uncertain helper enable is followed by OFF regardless of a
        // momentary read-back. Timed-out XPC messages remain executable.
        if correctionAllowed,
           VerifiedWritePolicy.requiresFailClosedCorrection(
               target: target,
               writeSucceeded: writeSucceeded,
               observed: observed
           ) {
            Self.logger.fault("fail_closed_disable_started")
            setEnabled(false, note: message, origin: .safety)
            return
        }
        if origin == .user {
            if helperBacked {
                presentHelperFailureAlert(message: message)
            } else {
                presentFailureAlert(target: target, message: message)
            }
        }
    }

    private func writeFailureMessage(target: Bool,
                                     failure: VerifiedWriteFailure,
                                     underlying: String?) -> String {
        switch failure {
        case .writeFailed:
            return underlying ?? (target
                ? "Couldn’t apply keep-awake."
                : "Couldn’t restore normal sleep.")
        case .readFailed:
            return target
                ? "Couldn’t verify keep-awake; Lidless is restoring normal sleep."
                : "Couldn’t verify that normal sleep was restored."
        case .mismatch(let actual):
            return "SleepDisabled read back as \(actual ? 1 : 0), not \(target ? 1 : 0)."
        }
    }

    /// Pop a blocking alert when a user-initiated toggle can't be applied, so the
    /// reason is impossible to miss. The inline `lastError` note still persists in
    /// the popover after the alert is dismissed.
    private func presentFailureAlert(target: Bool, message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = target ? "Couldn’t keep your Mac awake" : "Couldn’t turn keep-awake off"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// The helper is registered but didn't respond — almost always a stale
    /// registration after an app update (launchd refuses to launch the new
    /// binary). Offer a one-click reinstall, which re-registers and refreshes
    /// that record.
    private func presentHelperFailureAlert(message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn’t keep your Mac awake"
        alert.informativeText = "\(message)\n\nThis usually happens after an update. Reinstalling the background helper fixes it."
        alert.addButton(withTitle: "Reinstall Helper…")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            repairHelper()
        }
    }

    /// Re-register the privileged helper to refresh launchd's record, then report
    /// the outcome. Used both automatically (after a detected app update) and from
    /// the failure alert's "Reinstall Helper" action.
    func repairHelper() {
        helper.reregister { [weak self] error in
            guard let self else { return }
            self.refreshHelperStatus()
            self.storeCurrentHelperBuild()
            if let error {
                self.lastError = error.localizedDescription
            } else if self.helper.requiresApproval {
                self.lastError = "Approve Lidless in System Settings ▸ Login Items, then try the switch again."
                self.helper.openLoginItemsSettings()
            } else {
                self.lastError = "Background helper reinstalled — try the switch again."
            }
        }
    }

    // MARK: Heartbeat (keeps the helper watchdog satisfied)

    private func manageHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        guard isEnabled, helperInstalled else { return }
        helper.heartbeat()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.helper.heartbeat() }
        }
    }

    /// Arm when keep-awake turns on, cancel when it turns off.
    private func updateAutoOff(for enabled: Bool) {
        if enabled { armAutoOff() } else { cancelAutoOff() }
    }

    private func armAutoOff() {
        cancelAutoOff()
        // Manual mode only runs a countdown while actually on. In auto mode the
        // countdown disarms the intent at expiry, so it arms regardless of the
        // live state (a safety pause while armed just leaves it waiting).
        guard settings.autoEnableWhenCharging || isEnabled, autoOffMinutes > 0 else { return }
        let deadline = AutoOff.deadline(from: Date(), minutes: autoOffMinutes)
        autoOffDeadline = deadline
        refreshAutoOffRemaining()
        // One repeating timer drives both the countdown label and the firing,
        // and only runs while a timer is actually armed.
        autoOffTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.autoOffTick() }
        }
    }

    private func cancelAutoOff() {
        autoOffTimer?.invalidate()
        autoOffTimer = nil
        autoOffDeadline = nil
        autoOffRemaining = ""
    }

    private func refreshAutoOffRemaining() {
        guard let deadline = autoOffDeadline else { autoOffRemaining = ""; return }
        autoOffRemaining = AutoOff.formatCountdown(AutoOff.remaining(deadline: deadline, now: Date()))
    }

    private func autoOffTick() {
        guard let deadline = autoOffDeadline else { return }
        if AutoOff.isExpired(deadline: deadline, now: Date()) {
            let minutes = autoOffMinutes
            cancelAutoOff()
            let note = "Auto-off: \(AutoOff.optionLabel(minutes: minutes)) elapsed."
            if settings.autoEnableWhenCharging {
                // Always mode: disarm the intent; reconcile drops the flag.
                setArmed(false)
                lastError = note
            } else {
                setEnabled(false, note: note, origin: .autoOff)
            }
        } else {
            refreshAutoOffRemaining()
        }
    }

    // MARK: Battery + safety guard

    func tick() {
        recheckHelper()
        autoWrite.advanceTick()
        refreshState()
        refreshBattery { [weak self] info in
            guard let self else { return }
            if self.settings.autoEnableWhenCharging {
                self.reconcile(supersedeInFlight: false,
                               sample: info,
                               trigger: "periodic")
            } else {
                self.evaluateSafety(using: info, trigger: "periodic")
            }
        }
    }

    private func handlePowerSourceChange() {
        // The one absolute deadline begins at notification entry and covers the
        // initial parallel reads, helper reply, and final independent read-back.
        let deadline = ProcessDeadline(after: SafetyTiming.maximumUnplugResponse)
        let generation = powerSamples.begin()
        let previous = sampledBattery.powerState
        let readToken = sync.beginRead()
        samplePowerAndFlag(deadline: deadline) { [weak self] info, observedGlobal in
            guard let self, self.powerSamples.shouldApply(generation) else {
                return
            }
            self.applyBatterySample(info)
            if info.powerState != previous {
                Self.logger.notice(
                    "power_transition trigger=notification previous=\(previous.rawValue, privacy: .public) observed=\(info.powerState.rawValue, privacy: .public)"
                )
            }

            let thermal = self.thermalSerious()
            let safetyReason = SafetyEvaluator.reasonToDisable(
                battery: info,
                thermalSerious: thermal,
                settings: self.settings
            )
            let policyRequiresOff: Bool
            if self.settings.autoEnableWhenCharging {
                policyRequiresOff = !self.armed || !AutoEnablePolicy.canActivate(
                    battery: info,
                    thermalSerious: thermal,
                    settings: self.settings
                )
            } else {
                policyRequiresOff = safetyReason != nil
            }

            if PowerCallbackPolicy.requiresCorrectiveOff(
                policyRequiresOff: policyRequiresOff,
                shownEnabled: self.isEnabled,
                activeWriteTarget: self.activeWriteTarget,
                observedGlobal: observedGlobal
            ) {
                Self.logger.notice(
                    "desired_state trigger=power_notification power=\(info.powerState.rawValue, privacy: .public) desired=false"
                )
                self.setEnabled(false,
                                note: safetyReason?.message,
                                origin: .safety,
                                conditions: SafetySnapshot(battery: info,
                                                           thermalSerious: thermal),
                                deadline: deadline)
                return
            }

            // Even when the UI says off, consume the real flag observation so a
            // delivered power callback repairs display/global drift immediately.
            self.applyObserved(observedGlobal, readToken)
            if self.settings.autoEnableWhenCharging {
                self.reconcile(supersedeInFlight: true,
                               sample: info,
                               trigger: "power_notification")
            } else {
                self.evaluateSafety(using: info, trigger: "power_notification")
            }
        }
    }

    private func samplePowerAndFlag(
        deadline: ProcessDeadline,
        completion: @escaping (BatteryInfo, Bool?) -> Void
    ) {
        var batteryResult: BatteryInfo?
        var observedResult: Bool?
        var observedFinished = false
        let finishIfReady = {
            guard let info = batteryResult, observedFinished else { return }
            completion(info, observedResult)
        }
        battery.read(deadline: deadline.capped(to: SafetyTiming.readTimeout)) { info in
            batteryResult = info
            finishIfReady()
        }
        power.isSleepDisabled(deadline: deadline.capped(to: SafetyTiming.readTimeout)) {
            observed in
            observedResult = observed
            observedFinished = true
            finishIfReady()
        }
    }

    func refreshBattery(completion: @escaping (BatteryInfo) -> Void) {
        refreshBattery(deadline: ProcessDeadline(after: SafetyTiming.readTimeout),
                       completion: completion)
    }

    private func refreshBattery(deadline: ProcessDeadline,
                                completion: @escaping (BatteryInfo) -> Void) {
        let generation = powerSamples.begin()
        battery.read(deadline: deadline) { [weak self] info in
            guard let self, self.powerSamples.shouldApply(generation) else {
                return
            }
            self.applyBatterySample(info)
            completion(info)
        }
    }

    private func applyBatterySample(_ info: BatteryInfo) {
        sampledBattery = info
        batteryPercent = info.percent
        batteryOnAC = info.onAC
        batteryDescription = info.powerState == .unknown
            ? "Power status unavailable"
            : "\(info.source) · \(info.percent)%"
    }
}
