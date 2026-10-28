import AppKit
import SwiftUI

/// A language Forewarn is translated into. A flag stands for a country, so each
/// language takes the country most associated with it (🇬🇧 English, 🇦🇩 Catalan, which has no flag of its own).
struct AppLanguage: Identifiable, Hashable {
    let code: String
    let flag: String
    var id: String { code }

    /// The language's name in itself: "Deutsch".
    var nativeName: String {
        let locale = Locale(identifier: code)
        return locale.localizedString(forIdentifier: code)?.capitalized(with: locale) ?? code
    }

    /// The name in the language Forewarn is showing now: "Tedesco".
    var localizedName: String {
        Locale.current.localizedString(forIdentifier: code)?.capitalized(with: .current) ?? code
    }

    func matches(_ query: String) -> Bool {
        [nativeName, localizedName, code].contains { $0.localizedStandardContains(query) }
    }

    /// English plus the official languages of the European Union, Norwegian, Catalan and Ukrainian.
    static let all: [AppLanguage] = [
        ("bg", "🇧🇬"), ("ca", "🇦🇩"), ("cs", "🇨🇿"), ("da", "🇩🇰"), ("de", "🇩🇪"), ("el", "🇬🇷"), ("en", "🇬🇧"),
        ("es", "🇪🇸"), ("et", "🇪🇪"), ("fi", "🇫🇮"), ("fr", "🇫🇷"), ("ga", "🇮🇪"), ("hr", "🇭🇷"), ("hu", "🇭🇺"),
        ("it", "🇮🇹"), ("lt", "🇱🇹"), ("lv", "🇱🇻"), ("mt", "🇲🇹"), ("nb", "🇳🇴"), ("nl", "🇳🇱"), ("pl", "🇵🇱"),
        ("pt-PT", "🇵🇹"), ("ro", "🇷🇴"), ("sk", "🇸🇰"), ("sl", "🇸🇮"), ("sv", "🇸🇪"), ("uk", "🇺🇦"),
    ]
    .map { AppLanguage(code: $0.0, flag: $0.1) }
    .sorted { $0.nativeName.localizedCompare($1.nativeName) == .orderedAscending }

    /// The language Forewarn offers for a stored code, which System Settings or `defaults` may write with a region
    /// ("de-DE"): matched the way macOS picks a localization, and only within the same language. Nil when Forewarn
    /// is not translated into it.
    static func supported(_ code: String) -> AppLanguage? {
        if let exact = all.first(where: { $0.code == code }) {
            return exact
        }
        let match = Bundle.preferredLocalizations(from: all.map(\.code), forPreferences: [code]).first
        let language = Locale(identifier: code).language.languageCode
        return all.first { $0.code == match && Locale(identifier: $0.code).language.languageCode == language }
    }
}

/// The app's language. Stored where System Settings › General › Language & Region › Applications stores it (the
/// app's own `AppleLanguages`), so the two stay in step; no key means the same as the system. macOS reads it at
/// launch, so a change takes effect after a restart.
enum LanguageChoice {
    private static let key = "AppleLanguages"

    /// The chosen code, `nil` for the same as the system.
    static var current: String? {
        guard let id = Bundle.main.bundleIdentifier else { return nil }
        return (UserDefaults.standard.persistentDomain(forName: id)?[key] as? [String])?.first
    }

    /// What was chosen when this process started: a change since needs a restart.
    static let atLaunch = current

    static func set(_ code: String?) {
        if let code {
            UserDefaults.standard.set([code], forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    /// The system's own language, as Forewarn would show it. Read from the global domain: `Locale.preferredLanguages`
    /// starts with this app's own choice once one is set.
    static var systemName: String {
        let system = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?[key] as? [String]
        let preferred = Bundle.preferredLocalizations(
            from: Bundle.main.localizations, forPreferences: system ?? Locale.preferredLanguages
        ).first ?? "en"
        return AppLanguage.all.first { $0.code == preferred }?.nativeName ?? preferred
    }

    /// Starts a new instance, then quits this one: the new instance reads the language at launch. If macOS could
    /// not start it, this one keeps running and `failed` runs, so the caller can say so and offer it again.
    @MainActor
    static func relaunch(failed: @escaping @MainActor () -> Void) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { app, error in
            let started = app != nil && error == nil
            Task { @MainActor in
                if started {
                    NSApplication.shared.terminate(nil)
                } else {
                    failed()
                }
            }
        }
    }

    static var restartFailedMessage: String {
        String(localized: "Forewarn couldn't restart. Try again, or quit Forewarn and open it again.")
    }
}

/// A pop-up style button for the language; its list opens in a popover with a search field on top (type to filter,
/// Return picks the first match). "Same as System" always comes first, set apart by a separator.
struct LanguagePicker: View {
    /// `nil` is the same as the system.
    @Binding var selection: String?
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 6) {
                LanguageMark(language: language)
                Text(name)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.subdued)
                    .accessibilityHidden(true)
            }
        }
        .popover(isPresented: $open, arrowEdge: .bottom) {
            LanguageList(selection: $selection) { open = false }
        }
        .accessibilityLabel(Text("Language"))
        .accessibilityValue(Text(name))
        .accessibilityIdentifier("languagePicker")
    }

    private var language: AppLanguage? {
        selection.flatMap(AppLanguage.supported)
    }

    /// A choice Forewarn has no translation for (set outside it) is still a choice: named, not shown as the system.
    private var name: String {
        if let language {
            return language.nativeName
        }
        guard let selection else { return String(localized: "Same as System") }
        return Locale.current.localizedString(forIdentifier: selection) ?? selection
    }
}

private struct LanguageList: View {
    @Binding var selection: String?
    let close: () -> Void
    @State private var query = ""
    @FocusState private var searching: Bool

    private var matches: [AppLanguage] {
        query.isEmpty ? AppLanguage.all : AppLanguage.all.filter { $0.matches(query) }
    }

    private var systemMatches: Bool {
        query.isEmpty || String(localized: "Same as System").localizedStandardContains(query)
            || LanguageChoice.systemName.localizedStandardContains(query)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.subdued).accessibilityHidden(true)
                TextField("Search", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searching)
                    .onSubmit(pickFirst)
                    .accessibilityIdentifier("languageSearch")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(.quinary, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .padding(10)

            Divider()
            ScrollView {
                VStack(spacing: 2) {
                    if systemMatches {
                        LanguageRow(
                            language: nil, detail: LanguageChoice.systemName, selected: selection == nil
                        ) { pick(nil) }
                        Divider().padding(.vertical, 4)
                    }
                    ForEach(matches) { language in
                        LanguageRow(
                            language: language, detail: language.localizedName,
                            selected: selection.flatMap(AppLanguage.supported) == language
                        ) { pick(language.code) }
                    }
                    if matches.isEmpty, !systemMatches {
                        Text("No Results")
                            .foregroundStyle(.subdued)
                            .padding(.vertical, 20)
                    }
                }
                .padding(6)
            }
        }
        .frame(width: 300, height: 380)
        .onAppear { searching = true }
    }

    /// Return picks the first row shown: "Same as System" whenever it is listed, then the first language.
    private func pickFirst() {
        if systemMatches {
            pick(nil)
        } else if let first = matches.first {
            pick(first.code)
        }
    }

    private func pick(_ code: String?) {
        selection = code
        close()
    }
}

private struct LanguageRow: View {
    let language: AppLanguage?
    let detail: String
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                LanguageMark(language: language)
                    .font(.title3)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(language?.nativeName ?? String(localized: "Same as System"))
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.subdued)
                }
                Spacer()
                if selected {
                    Image(systemName: "checkmark")
                        .fontWeight(.semibold)
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(
                hovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear),
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The flag, or a globe for "Same as System".
private struct LanguageMark: View {
    let language: AppLanguage?

    var body: some View {
        if let language {
            Text(language.flag).accessibilityHidden(true)
        } else {
            Image(systemName: "globe").foregroundStyle(.subdued).accessibilityHidden(true)
        }
    }
}
