import CryptoKit
import Foundation

/// Content identity of the embedded helper binary.
///
/// The build number alone can't tell a rebuilt binary from the registered one:
/// a re-sign or rebuild at the same `CFBundleVersion` still produces a binary
/// launchd's stored job can go stale against. Hash the binary's content —
/// not size + whole-second mtime, which can miss two builds inside the same
/// second and reports a bare touch as a change.
public enum HelperFingerprint {
    private static let hexDigits: [Character] = Array("0123456789abcdef")

    /// `<build>-<sha256 of binary>`. Unreadable binary degrades to the build
    /// number alone (the pre-fingerprint behavior).
    public static func compute(build: String, binary: Data?) -> String {
        guard let binary, !binary.isEmpty else { return build }
        let hex = String(SHA256.hash(data: binary).flatMap { byte -> [Character] in
            [hexDigits[Int(byte >> 4)], hexDigits[Int(byte & 0x0F)]]
        })
        return "\(build)-\(hex)"
    }
}
