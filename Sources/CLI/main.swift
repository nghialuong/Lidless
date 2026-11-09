import AppKit
import Foundation

// `lidless` — status and off for scripts and coding agents. Embedded at
// `Lidless.app/Contents/Helpers/lidless`; Settings links it onto the PATH.

#if DEBUG
let appBundleID = "com.nghialuong.lidless.dev"
#else
let appBundleID = "com.nghialuong.lidless"
#endif

/// Long enough for the admin prompt the app falls back to without the helper.
let offTimeout: TimeInterval = 30

let usage = """
Usage: lidless [status|off]

  status   Show whether the Mac is being kept awake (default).
  off      Turn keep-awake off, the same as the menu-bar switch.
           Also disarms "Automatically enable when charging", so it stays off.

Exit status: 0 on success, 1 when the state is unknown or off didn't take, 2 on bad usage.
"""

func readFlag() -> Bool? {
    guard let out = Shell.capture("/usr/bin/pmset", ["-g"]) else { return nil }
    return PowerParsers.sleepDisabled(pmsetG: out)
}

func appIsRunning() -> Bool {
    !NSRunningApplication.runningApplications(withBundleIdentifier: appBundleID).isEmpty
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

/// The app's settings domain. Readable and writable from outside because the
/// app isn't sandboxed; `SettingsStore` keeps the keys in one place.
let store = UserDefaults(suiteName: appBundleID).map { SettingsStore(defaults: $0) }

func status() -> Never {
    let flag = readFlag()
    print("Keep awake: \(flag.map { $0 ? "on" : "off" } ?? "unknown")")
    print("Lidless app: \(appIsRunning() ? "running" : "not running")")
    if let store, store.load().autoEnableWhenCharging {
        print("Mode: automatic when charging (\(store.loadArmed() ? "armed" : "disarmed"))")
    } else {
        print("Mode: manual")
    }
    exit(flag == nil ? 1 : 0)
}

func off() -> Never {
    guard appIsRunning() else {
        // Nobody to flip the switch, but the armed intent can still be cleared
        // so the next launch doesn't turn keep-awake back on.
        store?.saveArmed(false)
        switch readFlag() {
        case false?:
            print("Keep awake is off.")
            exit(0)
        case true?:
            fail("Lidless isn't running, so it can't turn keep-awake off. Open Lidless and run this again, or run: sudo pmset -a disablesleep 0")
        case nil:
            fail("Couldn't read the SleepDisabled flag from pmset.")
        }
    }

    DistributedNotificationCenter.default().postNotificationName(
        Notification.Name(LidlessCLI.stopNotificationName(appBundleID: appBundleID)),
        object: nil, userInfo: nil, deliverImmediately: true
    )

    let deadline = Date().addingTimeInterval(offTimeout)
    while Date() < deadline {
        if readFlag() == false {
            print("Keep awake is off.")
            exit(0)
        }
        Thread.sleep(forTimeInterval: 0.25)
    }
    fail("Lidless didn't confirm keep-awake off within \(Int(offTimeout))s. Check the Lidless menu for an error.")
}

switch LidlessCLI.parse(Array(CommandLine.arguments.dropFirst())) {
case .status?: status()
case .off?:    off()
case .help?:   print(usage)
case nil:
    FileHandle.standardError.write(Data((usage + "\n").utf8))
    exit(2)
}
