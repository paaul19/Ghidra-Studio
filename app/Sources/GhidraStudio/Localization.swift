import AppKit
import Foundation

/// Translates a UI string. Keys are the Spanish source texts (with %@ for interpolations);
/// English lives in en.lproj/Localizable.strings (generated from app/Localization/en.json).
func tr(_ key: String, _ args: String...) -> String {
    let format = Bundle.main.localizedString(forKey: key, value: key, table: nil)
    guard !args.isEmpty else { return format }
    return String(format: format, arguments: args.map { $0 as NSString })
}

enum AppLanguage: String, CaseIterable, Identifiable {
    case system, es, en
    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: tr("Sistema")
        case .es: tr("Español")
        case .en: tr("English")
        }
    }

    static var current: AppLanguage {
        AppLanguage(rawValue: UserDefaults.standard.string(forKey: "studioLanguage") ?? "") ?? .system
    }

    /// Language actually in use ("es" / "en"), passed to the engine for its messages.
    static var effectiveCode: String {
        Bundle.main.preferredLocalizations.first?.hasPrefix("en") == true ? "en" : "es"
    }

    /// Stores the choice (AppleLanguages for this app only) and offers to relaunch.
    static func select(_ lang: AppLanguage) {
        guard lang != current else { return }
        let defaults = UserDefaults.standard
        defaults.set(lang.rawValue, forKey: "studioLanguage")
        switch lang {
        case .system: defaults.removeObject(forKey: "AppleLanguages")
        case .es: defaults.set(["es"], forKey: "AppleLanguages")
        case .en: defaults.set(["en"], forKey: "AppleLanguages")
        }
        defaults.synchronize()

        let alert = NSAlert()
        alert.messageText = tr("Cambiar idioma")
        alert.informativeText = tr("Ghidra Studio necesita reiniciarse para cambiar el idioma.") + "\n"
            + tr("Los cambios sin guardar se guardarán automáticamente.")
        alert.addButton(withTitle: tr("Reiniciar ahora"))
        alert.addButton(withTitle: tr("Más tarde"))
        if alert.runModal() == .alertFirstButtonReturn {
            relaunch()
        }
    }

    static func relaunch() {
        let path = Bundle.main.bundlePath
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 2; /usr/bin/open \"\(path)\""]
        try? p.run()
        NSApp.terminate(nil)
    }
}
