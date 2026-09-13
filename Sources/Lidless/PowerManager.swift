import Foundation

enum PowerWriteFailure: Error, Equatable {
    case cancelled
    case denied
    case timedOut
    case execution(String)

    var message: String {
        switch self {
        case .cancelled:
            return "Authorization cancelled."
        case .denied:
            return "Administrator authorization was denied."
        case .timedOut:
            return "The authorization request timed out."
        case .execution(let message):
            return message
        }
    }
}

/// Controls the macOS `SleepDisabled` flag.
///
/// The privileged helper is the safety-critical path. This interactive fallback
/// has one serialized mutation owner; newer OFF cancels an older enable, then
/// runs after its process has stopped.
struct PowerManager {
    func isSleepDisabled(deadline: ProcessDeadline,
                         completion: @escaping (Bool?) -> Void) {
        Shell.capture("/usr/bin/pmset", ["-g"], deadline: deadline) { output in
            completion(output.flatMap(PowerParsers.sleepDisabled(pmsetG:)))
        }
    }

    func isSleepDisabled(completion: @escaping (Bool?) -> Void) {
        isSleepDisabled(deadline: ProcessDeadline(after: SafetyTiming.readTimeout),
                        completion: completion)
    }

    func setSleepDisabled(_ enabled: Bool,
                          deadline: ProcessDeadline,
                          completion: @escaping (Result<Void, PowerWriteFailure>) -> Void) {
        let value = enabled ? "1" : "0"
        let script = "do shell script \"/usr/bin/pmset -a disablesleep \(value)\" with administrator privileges"

        Shell.runMutation("/usr/bin/osascript",
                          ["-e", script],
                          enabling: enabled,
                          deadline: deadline) { result in
            switch result {
            case .success:
                completion(.success(()))

            case .failure(.timedOut):
                completion(.failure(.timedOut))

            case .failure(.cancelled):
                completion(.failure(.cancelled))

            case .failure(.launch(let message)):
                completion(.failure(.execution(message)))

            case .failure(.terminationUnconfirmed):
                completion(.failure(.execution(
                    "The authorization process could not be confirmed stopped."
                )))

            case .failure(.exited(status: _, standardError: let standardError)):
                switch AuthorizationFailurePolicy.classify(standardError: standardError) {
                case .cancelled:
                    completion(.failure(.cancelled))
                case .denied:
                    completion(.failure(.denied))
                case .executionFailure:
                    completion(.failure(.execution(
                        standardError.isEmpty ? "The authorization command failed." : standardError
                    )))
                }
            }
        }
    }

    func setSleepDisabled(_ enabled: Bool,
                          completion: @escaping (Result<Void, PowerWriteFailure>) -> Void) {
        setSleepDisabled(
            enabled,
            deadline: ProcessDeadline(after: SafetyTiming.authorizationTimeout),
            completion: completion
        )
    }
}
