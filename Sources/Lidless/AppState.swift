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

    /// True when using the privileged helper; false when on the M1 admin-prompt fallback.
    @Published var usingHelper = false

    /// User-tunable safety preferences (persisted).
    @Published var settings: SafetySettings = .default

    /// Auto-mode master-toggle intent (persisted): whether the user wants
    /// keep-awake armed. In auto mode the *live* state (`isEnabled`) is derived
    /// from `armed` gated by power + safety; in manual mode this simply mirrors
    /// `isEnabled`. See `reconcile()`.
    @Published var armed = false

    /// The currently-unmet checks to surface in the popover's auto-mode warning,
    /// or empty when there's nothing to warn about. Non-empty only when auto mode
    /// is on, the feature is armed, but keep-awake isn't live right now.
    var autoWarningReasons: [SafetyReason] {
        guard settings.autoEnableWhenCharging, armed, !isEnabled else { return [] }
        let info = BatteryInfo(percent: batteryPercent, onAC: batteryOnAC)
        return SafetyEvaluator.allUnmetReasons(battery: info,
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

    private let helper = HelperManager()
    private let fallback = PowerManager()
    private let battery = BatteryMonitor()
    private let store = SettingsStore()
    private let loginItem = LoginItemManager()
    private lazy var onboarding = OnboardingController(state: self)

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
    /// True while the onboarding window is open and not yet completed.
    private var onboardingActive = false
    private var didBecomeActiveObserver: NSObjectProtocol?

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
        // conditions allow, or force it off otherwise (in case a prior session
        // left it on). `force` because the async `refreshState()` above may not
        // have reported the real state back yet.
        if settings.autoEnableWhenCharging { reconcile(force: true) }
        batteryTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        // Re-check the helper whenever the app comes forward — e.g. when the user
        // returns from approving it in System Settings — so we notice it being
        // enabled without requiring a manual restart.
        didBecomeActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.recheckHelper() }
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

    func updateSettings(_ new: SafetySettings) {
        let wasAuto = settings.autoEnableWhenCharging
        settings = new
        store.save(new)
        if new.autoEnableWhenCharging {
            if !wasAuto {
                // Entering auto mode: seed the armed intent from the current live
                // state, and drop any manual auto-off countdown (auto mode manages
                // activation itself, so a countdown would just fight it).
                armed = isEnabled
                store.saveArmed(armed)
                cancelAutoOff()
            }
            reconcile()
        } else {
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
            setEnabled(on, userInitiated: true)
        }
    }

    /// Set the auto-mode armed intent, persist it, and reconcile the live state.
    private func setArmed(_ on: Bool) {
        armed = on
        store.saveArmed(on)
        reconcile()
    }

    /// Auto mode: derive the live keep-awake state from `armed` gated by external
    /// power + safety, flipping only the live state (never the `armed` intent) and
    /// without alerts. When conditions aren't met the feature stays armed and the
    /// popover's warning explains why it isn't currently active.
    func reconcile(force: Bool = false) {
        guard settings.autoEnableWhenCharging else { return }
        let shouldBeOn = armed && AutoEnablePolicy.canActivate(battery: battery.read(),
                                                               thermalSerious: thermalSerious(),
                                                               settings: settings)
        guard force || shouldBeOn != isEnabled else { return }
        setEnabled(shouldBeOn, note: nil)
    }

    /// Change the auto-off duration. Re-arms (or cancels) the live timer when
    /// keep-awake is currently on.
    func setAutoOffMinutes(_ minutes: Int) {
        autoOffMinutes = minutes
        store.saveAutoOffMinutes(minutes)
        if isEnabled { armAutoOff() } else { cancelAutoOff() }
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
            setEnabled(false, note: reason.message)
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

    func refreshState() {
        if helperInstalled {
            helper.getState { [weak self] value in self?.isEnabled = value }
        } else {
            isEnabled = fallback.isSleepDisabled()
        }
    }

    /// User flipped the toggle: treat it as user-initiated so any failure or
    /// refusal surfaces a visible alert (not just the easy-to-miss inline note).
    func toggle() { setEnabled(!isEnabled, userInitiated: true) }

    /// Set keep-awake. `note` is shown to the user on a successful change
    /// (used when an auto-pause or the auto-off timer disables it); nil clears
    /// any prior message. When `userInitiated` is true (the user flipped the
    /// toggle), a failure or policy refusal also pops a blocking alert so it
    /// can't go unnoticed; background callers leave it false to stay quiet.
    func setEnabled(_ target: Bool, note: String? = nil, userInitiated: Bool = false) {
        // Refuse to enable if it would immediately violate the safety policy.
        if target {
            let info = battery.read()
            if let blocker = SafetyEvaluator.reasonToDisable(battery: info,
                                                             thermalSerious: thermalSerious(),
                                                             settings: settings) {
                lastError = blocker.message
                if userInitiated {
                    presentFailureAlert(target: target, message: blocker.blockedMessage)
                }
                return
            }
        }
        let resultMessage = note
        if helperInstalled {
            helper.setKeepAwake(target) { [weak self] ok, err in
                guard let self else { return }
                if ok {
                    self.isEnabled = target
                    self.lastError = resultMessage
                    self.manageHeartbeat()
                    self.updateAutoOff(for: target)
                } else {
                    // The helper can fail without a message (e.g. a dropped XPC
                    // reply, or the daemon failing to launch after an update);
                    // surface it instead of letting the toggle silently no-op.
                    let message = err ?? "The background helper didn’t respond."
                    self.lastError = message
                    if userInitiated { self.presentHelperFailureAlert(message: message) }
                    self.refreshState()
                }
            }
        } else {
            do {
                try fallback.setSleepDisabled(target)
                isEnabled = target
                lastError = resultMessage
                updateAutoOff(for: target)
            } catch {
                lastError = error.localizedDescription
                if userInitiated { presentFailureAlert(target: target, message: error.localizedDescription) }
                isEnabled = fallback.isSleepDisabled()
            }
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
            setEnabled(false, note: "Auto-off: \(AutoOff.optionLabel(minutes: minutes)) elapsed.")
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
        refreshBattery()
        if settings.autoEnableWhenCharging {
            reconcile()
        } else {
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
