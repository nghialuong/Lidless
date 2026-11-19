import IOKit
import IOKit.pwr_mgt

/// Reports clamshell transitions from IOPMrootDomain on the main run loop.
///
/// `kIOPMMessageClamshellStateChange` is a C macro that Swift cannot import
/// from IOPM.h. Its value below is the documented
/// `iokit_family_msg(sub_iokit_powermanagement, 0x100)` value from that header.
final class ClamshellMonitor {
    private static let rootDomain = "IOPMrootDomain"
    private static let clamshellStateChangeMessage: UInt32 = 0xE003_4100
    private static let clamshellStateBit: UInt32 = 1 << 0

    private let onChange: (Bool) -> Void
    private let root: io_service_t
    private var notificationPort: IONotificationPortRef?
    private var notifier: io_object_t = IO_OBJECT_NULL
    private var runLoopSource: CFRunLoopSource?

    init(onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
        root = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching(Self.rootDomain)
        )

        guard root != IO_OBJECT_NULL,
              let notificationPort = IONotificationPortCreate(kIOMainPortDefault)
        else { return }

        self.notificationPort = notificationPort
        let refcon = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        let result = IOServiceAddInterestNotification(
            notificationPort,
            root,
            kIOGeneralInterest,
            { refcon, _, messageType, messageArgument in
                guard let refcon else { return }
                let monitor = Unmanaged<ClamshellMonitor>
                    .fromOpaque(refcon)
                    .takeUnretainedValue()
                monitor.handle(messageType: messageType, argument: messageArgument)
            },
            refcon,
            &notifier
        )

        guard result == kIOReturnSuccess,
              let source = IONotificationPortGetRunLoopSource(notificationPort)?
                .takeUnretainedValue()
        else {
            if notifier != IO_OBJECT_NULL {
                IOObjectRelease(notifier)
                notifier = IO_OBJECT_NULL
            }
            IONotificationPortDestroy(notificationPort)
            self.notificationPort = nil
            return
        }

        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
    }

    /// Read the current AppleClamshellState value for launch and settings changes.
    var isClosed: Bool? {
        guard root != IO_OBJECT_NULL else { return nil }
        return IORegistryEntryCreateCFProperty(
            root,
            "AppleClamshellState" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? Bool
    }

    private func handle(messageType: UInt32, argument: UnsafeMutableRawPointer?) {
        guard messageType == Self.clamshellStateChangeMessage,
              let argument else { return }
        // The kernel passes the bitfield as the pointer value, not as a pointer
        // to storage. This mirrors the IOPMrootDomain messageClients call.
        let bits = UInt32(truncatingIfNeeded: UInt(bitPattern: argument))
        onChange(bits & Self.clamshellStateBit != 0)
    }

    deinit {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .defaultMode)
        }
        if notifier != IO_OBJECT_NULL {
            IOObjectRelease(notifier)
        }
        if let notificationPort {
            IONotificationPortDestroy(notificationPort)
        }
        if root != IO_OBJECT_NULL {
            IOObjectRelease(root)
        }
    }
}
