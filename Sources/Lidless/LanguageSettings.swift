import AppKit

extension AppState {
    /// Changing the app's language requires a fresh Bundle localization lookup.
    /// Use the existing restart path; choosing Later leaves this session intact.
    func setInterfaceLanguage(_ language: InterfaceLanguage) {
        guard language != InterfaceLanguage.current() else { return }
        language.save()

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = L10n.tr("Restart Lidless to change language?")
        alert.informativeText = L10n.tr("The new language will be used the next time Lidless opens. You can restart now or continue using the current language.")
        alert.addButton(withTitle: L10n.tr("Restart Now"))
        alert.addButton(withTitle: L10n.tr("Later"))
        if alert.runModal() == .alertFirstButtonReturn {
            relaunch()
        }
    }
}
