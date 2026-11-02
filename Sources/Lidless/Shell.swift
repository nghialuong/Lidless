import Foundation

/// Runs fixed app-side commands through the shared deadline-aware process
/// runner. Reads may proceed concurrently; privileged mutations have one serial
/// owner so an older enable can never execute after a newer corrective OFF.
/// Completions always return on the main queue.
enum Shell {
    private static let readQueue = DispatchQueue(
        label: LidlessIdentity.diagnosticQueueLabel(
            appBundleID: Bundle.main.bundleIdentifier,
            component: "process.read"
        ),
        qos: .userInitiated,
        attributes: .concurrent
    )
    private static let mutationQueue = DispatchQueue(
        label: LidlessIdentity.diagnosticQueueLabel(
            appBundleID: Bundle.main.bundleIdentifier,
            component: "process.mutation"
        ),
        qos: .userInitiated
    )
    private static let mutationLock = NSLock()
    private static var latestMutation: UInt64 = 0

    static func run(_ path: String,
                    _ args: [String],
                    deadline: ProcessDeadline,
                    completion: @escaping (Result<DeadlineProcessOutput, DeadlineProcessFailure>) -> Void) {
        readQueue.async {
            let result = DeadlineProcessRunner.run(
                executable: path,
                arguments: args,
                deadline: deadline
            )
            DispatchQueue.main.async { completion(result) }
        }
    }

    static func run(_ path: String,
                    _ args: [String],
                    timeout: TimeInterval,
                    completion: @escaping (Result<DeadlineProcessOutput, DeadlineProcessFailure>) -> Void) {
        // Construct before dispatch so queue residence consumes the timeout.
        run(path,
            args,
            deadline: ProcessDeadline(after: timeout),
            completion: completion)
    }

    static func runMutation(_ path: String,
                            _ args: [String],
                            enabling: Bool,
                            deadline: ProcessDeadline,
                            completion: @escaping (Result<DeadlineProcessOutput, DeadlineProcessFailure>) -> Void) {
        let operation = beginMutation()
        mutationQueue.async {
            let result = DeadlineProcessRunner.run(
                executable: path,
                arguments: args,
                deadline: deadline,
                cancelled: {
                    AuthorizationMutationPolicy.shouldCancel(
                        requestedEnable: enabling,
                        isCurrent: isCurrent(operation)
                    )
                }
            )
            DispatchQueue.main.async { completion(result) }
        }
    }

    static func capture(_ path: String,
                        _ args: [String],
                        deadline: ProcessDeadline,
                        completion: @escaping (String?) -> Void) {
        run(path, args, deadline: deadline) { result in
            switch result {
            case .success(let output):
                completion(String(data: output.standardOutput, encoding: .utf8))
            case .failure:
                completion(nil)
            }
        }
    }

    static func capture(_ path: String,
                        _ args: [String],
                        timeout: TimeInterval = SafetyTiming.readTimeout,
                        completion: @escaping (String?) -> Void) {
        capture(path,
                args,
                deadline: ProcessDeadline(after: timeout),
                completion: completion)
    }

    private static func beginMutation() -> UInt64 {
        mutationLock.lock()
        defer { mutationLock.unlock() }
        latestMutation &+= 1
        return latestMutation
    }

    private static func isCurrent(_ operation: UInt64) -> Bool {
        mutationLock.lock()
        defer { mutationLock.unlock() }
        return operation == latestMutation
    }
}
