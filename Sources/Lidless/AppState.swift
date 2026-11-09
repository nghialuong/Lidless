import AppKit
import SwiftUI
import Foundation

@MainActor
final class AppState: ObservableObject {
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

    /// Transient status of a write we haven't been able to confirm. Also its own
    /// channel, so clearing it can't disturb `lastError`.
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
                                               settings: settings,
                                               requirePower: true)
    }

    /// The value the main "Keep awake with lid closed" toggle should show: the
    /// armed intent in auto mode, the live state in manual mode.
    var masterToggleOn: Bool {
        settings.autoEnableWhenCharging ? armed : isEnabled
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

    /// Whether `/usr/local/bin/lidless` links to this app's bundled tool.
    @Published var commandLineToolInstalled = false

    private let helper = HelperManager()
    /// Reads the flag on every path — `pmset -g` needs no privileges — and also
    /// writes it when the helper isn't installed.
    private let power = PowerManager()
    private let battery = BatteryMonitor()
    private let store = SettingsStore()
    private let loginItem = LoginItemManager()
    private lazy var onboarding = OnboardingController(state: self)

    /// The app's Sparkle updater. Owned here rather than by `LidlessApp` so the
    /// settings window controller below can hand it to `SettingsView`.
    let updater = UpdaterController()

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
    /// True once the system flag has been read successfully this session. Set
    /// only by a read — a write's success reply is a claim, not a reading, and
    /// treating it as one would let an unconfirmed write masquerade as drift.
    private var hasConfirmedState = false
    /// The write currently awaiting confirmation, if any.
    private var pendingVerification: PendingVerification?
    /// Rejects async replies that have been superseded.
    private var sync = StateSync()
    /// True while the onboarding window is open and not yet completed.
    private var onboardingActive = false
    private var didBecomeActiveObserver: NSObjectProtocol?
    private var commandLineBridge: CommandLineBridge?

    init() {
        settings = store.load()
        armed = store.loadArmed()
        autoOffMinutes = store.loadAutoOffMinutes()
        onboardingComplete = store.loadOnboardingComplete()
        launchAtLogin = loginItem.isEnabled
        refreshHelperStatus()
        refreshHelperRegistrationIfUpdated()
        helperWasUsable = usingHelper
        refreshState()
        refreshBattery()
        // Auto mode owns the live state at launch: (re-)activate if armed and
        // conditions allow, or turn it off if a prior session left it on with
        // conditions since lapsed. `refreshState()` above reads the flag
        // synchronously, so `isEnabled` is already the real state to compare
        // against and there's nothing to force.
        //
        // Plainly `reconcile()`, not `reconcileNow()`: adopting the state that
        // read just established may already have dispatched a write, and clearing
        // that claim here would dispatch a second one for the same decision.
        reconcile()
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
        commandLineToolInstalled = CommandLineToolInstaller.isInstalled
        commandLineBridge = CommandLineBridge(
            appBundleID: Bundle.main.bundleIdentifier ?? "com.nghialuong.lidless"
        ) { [weak self] reply in
            guard let self else { return reply(false, "Lidless is shutting down.") }
            self.stopFromCommandLine(reply: reply)
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

    // MARK: Command-line tool

    /// `lidless off`. Goes through the master toggle, not a bare write, so auto
    /// mode is disarmed too — otherwise its next reconcile would turn keep-awake
    /// straight back on.
    ///
    /// Reads the flag first: if it was set behind the app's back, the UI still
    /// shows off, and auto mode would see nothing to undo. Adopting the real
    /// state before disarming makes the switch's own write clear it.
    ///
    /// Replies only once both halves hold — the flag reads back 0 and auto mode
    /// is disarmed — because the helper's write is asynchronous and the tool
    /// must not report off while keep-awake can still come back.
    func stopFromCommandLine(reply: @escaping (Bool, String?) -> Void) {
        refreshState()
        setMasterToggle(false)
        confirmStopped(deadline: Date().addingTimeInterval(LidlessCLI.appConfirmTimeout),
                       reply: reply)
    }

    private func confirmStopped(deadline: Date, reply: @escaping (Bool, String?) -> Void) {
        let disarmed = !(settings.autoEnableWhenCharging && armed)
        if disarmed, power.isSleepDisabled() == false {
            return reply(true, nil)
        }
        guard Date() < deadline else {
            return reply(false, lastError ?? "Keep-awake didn't read back as off in time.")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return reply(false, "Lidless is shutting down.") }
            self.confirmStopped(deadline: deadline, reply: reply)
        }
    }

    func installCommandLineTool() {
        do {
            try CommandLineToolInstaller.install()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        commandLineToolInstalled = CommandLineToolInstaller.isInstalled
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
            // Leaving auto mode with a write still travelling. Its target is where
            // the system is heading, so that's what manual mode inherits — but the
            // transition has to own that outcome with a write of its own, or the
            // auto reply lands afterwards and moves the state in a mode the user
            // has already left.
            //
            // Quiet origin deliberately: the user toggled a mode, not the switch,
            // so a modal about keep-awake would be about a write they never asked
            // for. It also can't be `.user` for a second reason — that origin
            // clears `externalNotice`, which this isn't entitled to do.
            //
            // The reply to this write runs `updateAutoOff`, and auto mode is off
            // in `settings` by now, so the countdown arms exactly as manual mode
            // expects.
            refreshBattery()
            let conditions = SafetySnapshot(battery: currentBattery,
                                            thermalSerious: thermalSerious())
            let settled = AutoEnablePolicy.handoffToManual(pendingTarget: pending,
                                                           conditions: conditions,
                                                           settings: settings)
            autoWrite.clear()
            // Same snapshot to decide and to write: whichever way `settled` went,
            // the check on the way out is guaranteed to permit it, so this write
            // always claims a mutation and always supersedes the auto reply.
            setEnabled(settled, note: nil, origin: .auto, conditions: conditions)
        } else {
            // Leaving auto mode hands activation back to the user, so the auto-off
            // countdown becomes applicable again — re-arm it if one is configured
            // and keep-awake is currently on.
            if wasAuto, isEnabled { armAutoOff() }
            evaluateSafety()
        }
    }

    /// The main toggle was flipped. In auto mode it sets the armed intent (and
    /// lets `reconcile()` gate the live state); in manual mode it directly turns
    /// keep-awake on/off, surfacing any failure/refusal as an alert.
    func setMasterToggle(_ on: Bool) {
        if settings.autoEnableWhenCharging {
            setArmed(on)
        } else {
            setEnabled(on, origin: .user)
        }
    }

    /// Set the auto-mode armed intent, persist it, and reconcile the live state.
    private func setArmed(_ on: Bool) {
        armed = on
        store.saveArmed(on)
        reconcileNow()
    }

    /// Auto mode: derive the live keep-awake state from `armed` gated by external
    /// power + safety, flipping only the live state (never the `armed` intent).
    /// When conditions aren't met the feature stays armed and the popover's
    /// warning explains why it isn't currently active.
    ///
    /// The poll's entry point. No-ops when auto mode is off, when the effective
    /// state already matches, or while an earlier write is still outstanding or
    /// has already concluded this turn — see `autoWrite`. `origin: .auto` because
    /// this fires unprompted on the timer and must stay silent.
    func reconcile() { reconcile(userDriven: false) }

    /// Reconcile now on behalf of something the user just did — arming, changing
    /// settings — where waiting for the next tick would read as the control doing
    /// nothing.
    ///
    /// Unlike the poll, this may write over a request still in flight, because
    /// the user has since said something newer. It does *not* simply drop the
    /// claim: dropping it loses the pending target, and the decision is then
    /// taken against a state the system has already left. Disarming while an
    /// "on" write is travelling would compare `false` against a still-`false`
    /// `isEnabled`, conclude there was nothing to do, and leave the earlier write
    /// to land unopposed — turning keep-awake on moments after the user turned it
    /// off. Deciding against the effective state instead yields a corrective
    /// write, which supersedes the old reply and, because the helper serialises,
    /// lands last.
    private func reconcileNow() { reconcile(userDriven: true) }

    /// Derive the live keep-awake state from `armed` gated by external power +
    /// safety, flipping only the live state (never the `armed` intent). When
    /// conditions aren't met the feature stays armed and the popover's warning
    /// explains why it isn't currently active.
    ///
    /// Refreshes the battery cache first so the decision and the warning list the
    /// popover renders from it are read off the same sample.
    private func reconcile(userDriven: Bool) {
        guard settings.autoEnableWhenCharging else { return }
        guard userDriven || autoWrite.mayWrite else { return }
        refreshBattery()
        // One sample, used to decide *and* handed to the write, so the check on
        // the way out can't disagree with the decision that authorised it. A
        // disagreement there would be a refusal, and a refusal claims no mutation
        // — leaving a superseded write in force.
        let conditions = SafetySnapshot(battery: currentBattery,
                                        thermalSerious: thermalSerious())
        let effective = AutoEnablePolicy.effectiveState(pendingTarget: autoWrite.inFlightTarget,
                                                        live: isEnabled)
        // No target means the outstanding write is already heading where we want
        // it to. Leave the claim standing rather than clearing it — clearing
        // would let the next tick dispatch a duplicate alongside a live request.
        guard let target = AutoEnablePolicy.target(armed: armed,
                                                   currentlyEnabled: effective,
                                                   battery: conditions.battery,
                                                   thermalSerious: conditions.thermalSerious,
                                                   settings: settings) else { return }
        autoWrite.issued(target: target)
        setEnabled(target, note: nil, origin: .auto, conditions: conditions)
    }

    /// The claim on auto mode's outstanding write. Held across the helper's async
    /// round trip, so a reply that reads back wrong can't immediately provoke
    /// another write. See `AutoWriteCoordinator`.
    private var autoWrite = AutoWriteCoordinator()

    /// The last-sampled battery state, refreshed by `refreshBattery()`. Shared by
    /// `reconcile()` and `autoWarningReasons` so the two can't disagree.
    private var currentBattery: BatteryInfo {
        BatteryInfo(percent: batteryPercent, onAC: batteryOnAC)
    }

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
        let request = AutoOff.request(minutes: minutes,
                                      isEnabled: isEnabled,
                                      autoModeOn: settings.autoEnableWhenCharging)
        guard request != .ignoredInAutoMode else { return }
        autoOffMinutes = minutes
        store.saveAutoOffMinutes(minutes)
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

    /// Auto-disable keep-awake if current conditions violate the safety policy.
    func evaluateSafety() {
        guard isEnabled else { return }
        let info = battery.read()
        if let reason = SafetyEvaluator.reasonToDisable(battery: info,
                                                        thermalSerious: thermalSerious(),
                                                        settings: settings) {
            // Pass the message through so it survives the async helper callback
            // (which would otherwise clear lastError on success).
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
        applyObserved(power.isSleepDisabled(), token)
    }

    private func applyObserved(_ observed: Bool?, _ token: StateSync.ReadToken) {
        guard sync.shouldApply(token) else { return }   // superseded by a newer read or a write

        // A write we haven't confirmed owns the interpretation until it resolves:
        // a disagreement here is our own write failing to hold, not somebody
        // else's doing, and mustn't be reported as an external change.
        if let pending = pendingVerification {
            switch StateReconciler.resolve(pending, observed: observed) {
            case .stillUnverified:
                break
            case .confirmed:
                autoWrite.resolved()
                pendingVerification = nil
                verificationNotice = nil
                hasConfirmedState = true
            case .writeMismatch(let actual):
                // Same ordering rule as `applyVerification`: settle the claim
                // before adopting, so the reconcile that adopting triggers can't
                // chase the mismatch with another write in this turn.
                autoWrite.resolved()
                pendingVerification = nil
                verificationNotice = StateReconciler.writeMismatchMessage(actual: actual)
                hasConfirmedState = true
                adoptSystemState(actual)
            }
            return
        }

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
    private func adoptSystemState(_ enabled: Bool) {
        isEnabled = enabled
        sync.beginMutation()            // supersede every read and write still in flight
        manageHeartbeat()
        updateAutoOff(for: enabled)
        // Auto mode owns the live state, so route through `reconcile()` rather
        // than the manual safety pass: adopting an outside change must be settled
        // by the same rule that set the state in the first place, or the toggle
        // visibly jumps and then falls back a tick later.
        if settings.autoEnableWhenCharging {
            reconcile()
        } else if enabled {
            evaluateSafety()
        }
    }

    /// User flipped the toggle: `.user` origin so any failure or refusal surfaces
    /// a visible alert (not just the easy-to-miss inline note).
    func toggle() { setEnabled(!isEnabled, origin: .user) }

    /// Set keep-awake. `note` is shown to the user on a successful change
    /// (used when an auto-pause or the auto-off timer disables it); nil clears
    /// any prior message. When `origin` is `.user` (the user flipped the toggle),
    /// a failure or policy refusal also pops a blocking alert so it can't go
    /// unnoticed; background callers pass their own origin to stay quiet.
    /// `conditions` is the sample a caller already made its decision from. The
    /// safety check below still runs — this is not a bypass — but it runs against
    /// those conditions rather than a fresh reading, so a decision and the write
    /// it authorises can't be judged against different worlds. Callers that have
    /// no decision to be consistent with (the user flipping the switch) omit it
    /// and get the fresh reading, which is what they want.
    func setEnabled(_ target: Bool,
                    note: String? = nil,
                    origin: SetOrigin = .user,
                    conditions: SafetySnapshot? = nil) {
        if StateReconciler.clearsExternalNotice(origin) { externalNotice = nil }
        // Any other origin takes the flag away from auto mode: its claim is void
        // and its reply, if one is still in flight, will be rejected as superseded
        // below. Leaving the claim standing would stall auto mode for a tick or
        // two on a reply that is never coming.
        if origin != .auto { autoWrite.clear() }

        // Refuse to enable if it would immediately violate the safety policy.
        // Returns before claiming a mutation, so nothing in flight is disturbed —
        // which is exactly why a caller correcting an outstanding write must pass
        // the conditions it decided from: a refusal here supersedes nothing.
        if target {
            let checked = conditions ?? SafetySnapshot(battery: battery.read(),
                                                       thermalSerious: thermalSerious())
            if let blocker = SafetyEvaluator.reasonToDisable(battery: checked.battery,
                                                             thermalSerious: checked.thermalSerious,
                                                             settings: settings) {
                lastError = blocker.message
                if origin == .user {
                    presentFailureAlert(target: target, message: blocker.blockedMessage)
                }
                // Nothing was dispatched, so release the claim rather than holding
                // it for a write that never happened.
                if origin == .auto { autoWrite.clear() }
                return
            }
        }
        let resultMessage = note

        // A new write supersedes any older one, along with its pending verification.
        pendingVerification = nil
        verificationNotice = nil
        let token = sync.beginMutation()

        if helperInstalled {
            helper.setKeepAwake(target) { [weak self] ok, err in
                guard let self, self.sync.shouldApply(token) else { return }   // superseded write
                if ok {
                    self.isEnabled = target
                    self.lastError = resultMessage
                    self.manageHeartbeat()
                    self.updateAutoOff(for: target)
                    // Deliberately not `hasConfirmedState`: the helper's success
                    // reply is a claim about the flag, not a reading of it.
                    self.pendingVerification = PendingVerification(target: target)
                    self.verifySetApplied(target: target)
                } else {
                    // The helper can fail without a message (e.g. a dropped XPC
                    // reply, or the daemon failing to launch after an update);
                    // surface it instead of letting the toggle silently no-op.
                    let message = err ?? "The background helper didn’t respond."
                    self.lastError = message
                    if origin == .user { self.presentHelperFailureAlert(message: message) }
                    self.recoverStateAfterFailedWrite()
                }
            }
        } else {
            do {
                try power.setSleepDisabled(target)
                isEnabled = target
                lastError = resultMessage
                updateAutoOff(for: target)
                pendingVerification = PendingVerification(target: target)
                verifySetApplied(target: target)
            } catch {
                lastError = error.localizedDescription
                if origin == .user { presentFailureAlert(target: target, message: error.localizedDescription) }
                recoverStateAfterFailedWrite()
            }
        }
    }

    /// After a write that reported failure we know nothing reliable about the
    /// flag — the write may still have landed. Go re-read it through the normal
    /// reconcile path rather than assigning `isEnabled` directly, so the token,
    /// baseline, and side effects all stay consistent.
    ///
    /// The baseline is dropped first so that read re-establishes it silently: if
    /// the flag did move, that was our own failed write, and blaming an external
    /// actor for it would be plainly wrong.
    private func recoverStateAfterFailedWrite() {
        // Resolve before re-reading: that read can adopt a state and ask auto mode
        // to reconcile, which must not turn into an immediate second attempt at
        // the write that just failed.
        autoWrite.resolved()
        hasConfirmedState = false
        refreshState()
    }

    /// The write reported success — read the flag back to see whether it landed.
    private func verifySetApplied(target: Bool) {
        let token = sync.beginRead()
        let observed = power.isSleepDisabled()
        guard sync.shouldApply(token) else { return }
        applyVerification(StateReconciler.verifyAfterSet(target: target, observed: observed),
                          target: target)
    }

    /// Verification never writes to `lastError`: it keeps its own channel so
    /// clearing a caveat can't wipe a safety note or a helper error.
    private func applyVerification(_ outcome: StateReconciler.VerifyOutcome, target: Bool) {
        // Whatever the outcome, auto mode's write is over. Resolving up front
        // matters most for `.mismatch`, where adopting the contradicting state
        // reconciles again: without this, that reconcile would dispatch a fresh
        // write, whose read-back could mismatch in turn, with no bound but the
        // stack. Deferring costs a tick and cannot loop.
        autoWrite.resolved()
        switch outcome {
        case .verified:
            pendingVerification = nil
            verificationNotice = nil
            hasConfirmedState = true
        case .unverified:
            // Keep `pendingVerification` — the next poll resolves it, and until
            // then the UI says plainly that the state isn't confirmed.
            verificationNotice = StateReconciler.unverifiedMessage(target: target)
        case .mismatch(let actual):
            pendingVerification = nil
            verificationNotice = StateReconciler.writeMismatchMessage(actual: actual)
            hasConfirmedState = true
            adoptSystemState(actual)
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

    // MARK: Auto-off timer

    /// Arm when keep-awake turns on, cancel when it turns off.
    private func updateAutoOff(for enabled: Bool) {
        if enabled { armAutoOff() } else { cancelAutoOff() }
    }

    private func armAutoOff() {
        cancelAutoOff()
        // Auto mode manages activation on its own; a countdown would disarm the
        // feature out from under it, so auto-off is inert while auto mode is on.
        guard isEnabled, autoOffMinutes > 0, !settings.autoEnableWhenCharging else { return }
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

    private func autoOffTick() {
        guard let deadline = autoOffDeadline else { return }
        if AutoOff.isExpired(deadline: deadline, now: Date()) {
            let minutes = autoOffMinutes
            cancelAutoOff()
            setEnabled(false,
                       note: "Auto-off: \(AutoOff.optionLabel(minutes: minutes)) elapsed.",
                       origin: .autoOff)
        } else {
            refreshAutoOffRemaining()
        }
    }

    private func refreshAutoOffRemaining() {
        guard let deadline = autoOffDeadline else { autoOffRemaining = ""; return }
        autoOffRemaining = AutoOff.formatCountdown(AutoOff.remaining(deadline: deadline, now: Date()))
    }

    // MARK: Battery + safety guard

    func tick() {
        // Backstop for the didBecomeActive observer: catch a helper approval even
        // if the app never lost/regained active state.
        recheckHelper()
        // Advance auto mode's write claim. A concluded write reopens here — this
        // is where its retry comes from. One still outstanding does not: this tick
        // may be landing moments after the dispatch, and reopening would put a
        // second write alongside a live first. It reopens a tick later instead,
        // which also bounds how long a lost reply can hold the feature.
        autoWrite.advanceTick()
        // Reconcile with the real flag every tick, not only while enabled:
        // polling only when we think it's on would structurally miss the case
        // where it was turned on behind our back.
        refreshState()
        if settings.autoEnableWhenCharging {
            reconcile()             // refreshes the battery sample itself
        } else {
            refreshBattery()
            evaluateSafety()
        }
    }

    func refreshBattery() {
        let info = battery.read()
        batteryPercent = info.percent
        batteryOnAC = info.onAC
        batteryDescription = "\(info.source) · \(info.percent)%"
    }
}
