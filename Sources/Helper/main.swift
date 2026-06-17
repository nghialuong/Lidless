import Foundation

// Entry point for the privileged helper (a LaunchDaemon running as root).
// It listens on a Mach service and serves LidlessHelperProtocol over XPC.
let delegate = HelperListenerDelegate()
let listener = NSXPCListener(machServiceName: lidlessHelperMachLabel)
listener.delegate = delegate
listener.resume()
RunLoop.current.run()
