import Combine
import Sparkle
import SwiftUI

/// Owns the app's single Sparkle updater for its entire lifetime and exposes the
/// bits of state SwiftUI needs to drive the "Check for Updates…" menu item and the
/// Settings toggle.
///
/// Lidless is an `LSUIElement` menu-bar app with no app menu, so Sparkle's
/// documented `CommandGroup` integration doesn't surface. Instead we publish
/// `canCheckForUpdates` (to enable/disable the menu item) and proxy
/// `automaticallyChecksForUpdates` (Sparkle persists this itself in UserDefaults,
/// so it stays the single source of truth — no `SettingsStore` key for it).
@MainActor
final class UpdaterController: ObservableObject {
    /// Drives the enabled state of the "Check for Updates…" controls.
    @Published private(set) var canCheckForUpdates = false
    /// Two-way bound by the Settings toggle; written through to Sparkle.
    @Published var automaticallyChecksForUpdates: Bool

    private let controller: SPUStandardUpdaterController
    private var cancellables = Set<AnyCancellable>()

    init() {
        // startingUpdater: true begins scheduled background checks immediately.
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )

        let updater = controller.updater
        automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates

        updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .assign(to: &$canCheckForUpdates)

        // Propagate the Settings toggle back into Sparkle. `dropFirst` skips the
        // initial seeded value so we don't write back what we just read.
        $automaticallyChecksForUpdates
            .dropFirst()
            .sink { [weak updater] enabled in
                updater?.automaticallyChecksForUpdates = enabled
            }
            .store(in: &cancellables)
    }

    func checkForUpdates() {
        controller.updater.checkForUpdates()
    }
}
