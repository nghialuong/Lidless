import Foundation
import IOKit.ps
import OSLog

/// Owns the live IOPowerSources subscription and produces conservative samples.
///
/// The IOKit provider and `pmset` parser must agree. A failed or contradictory
/// sample is `.unknown`, which the safety policy treats as unable to authorize
/// keep-awake.
final class BatteryMonitor {
    private static let logger = Logger(
        subsystem: LidlessIdentity.diagnosticSubsystem(
            appBundleID: Bundle.main.bundleIdentifier
        ),
        category: "power-source"
    )

    private var runLoopSource: CFRunLoopSource?
    private var onChange: (() -> Void)?

    func read(deadline: ProcessDeadline,
              completion: @escaping (BatteryInfo) -> Void) {
        let iokitState: PowerSourceState?
        if let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let source = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() {
            switch source as String {
            case "AC Power":      iokitState = .ac
            case "Battery Power": iokitState = .battery
            default:              iokitState = nil
            }
        } else {
            iokitState = nil
        }

        guard let iokitState else {
            completion(.unknown)
            return
        }
        Shell.capture("/usr/bin/pmset", ["-g", "batt"], deadline: deadline) { output in
            let parsed = output.map(BatteryParsers.parse(pmsetBatt:)) ?? .unknown
            completion(PowerSourceCrossCheck.reconcile(iokit: iokitState,
                                                       parsed: parsed))
        }
    }

    func read(completion: @escaping (BatteryInfo) -> Void) {
        read(deadline: ProcessDeadline(after: SafetyTiming.readTimeout),
             completion: completion)
    }

    /// Schedule notifications on the main run loop's common modes so menu
    /// tracking cannot defer an unplug callback. A false return is a fail-closed
    /// authorization result: polling may observe state but cannot replace a live
    /// transition source.
    @discardableResult
    func start(onChange: @escaping () -> Void) -> Bool {
        stop()
        self.onChange = onChange
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            Unmanaged<BatteryMonitor>
                .fromOpaque(context)
                .takeUnretainedValue()
                .onChange?()
        }, context)?.takeRetainedValue() else {
            self.onChange = nil
            Self.logger.error("subscription_failed")
            return false
        }
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        Self.logger.info("subscription_started mode=common")
        return true
    }

    func stop() {
        guard let source = runLoopSource else {
            onChange = nil
            return
        }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        CFRunLoopSourceInvalidate(source)
        runLoopSource = nil
        onChange = nil
    }

    deinit {
        stop()
    }
}
