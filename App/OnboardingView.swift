import ForewarnKit
import SwiftUI

/// First-launch window, four short pages: language, what
/// Forewarn does, privacy, setup.
/// Optional: closing it at any page counts as done, and it never opens again (`make welcome` reopens it).
struct OnboardingView: View {
    static let windowID = "welcome"

    private enum Page: Int, CaseIterable {
        case language, welcome, privacy, setup
    }

    /// Set before restarting in a new language: the new instance opens on the page after the language.
    static let resumeKey = "onboardingResumesAfterLanguage"
    /// The window closes when this instance quits for the restart; that is not "done".
    @MainActor static var restarting = false

    @State private var page = UserDefaults.standard.bool(forKey: resumeKey) ? Page.welcome : Page.language
    @State private var language = LanguageChoice.current
    @AppStorage(SettingsKey.onboarded) private var onboarded = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch page {
                case .language: LanguagePage(selection: $language)
                case .welcome: WelcomePage()
                case .privacy: PrivacyPage()
                case .setup: SetupPage()
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("onboardingPage-\(page)")

            Divider()
            HStack {
                PageDots(count: Page.allCases.count, current: page.rawValue)
                Spacer()
                if page != .language {
                    Button("Back") { page = Page(rawValue: page.rawValue - 1)! }
                        .accessibilityIdentifier("onboardingBack")
                }
                Button(page == .setup ? "Start Using Forewarn" : "Continue") {
                    if page == .language, language != LanguageChoice.atLaunch {
                        // macOS reads the language at launch: restart in it, on the next page.
                        LanguageChoice.set(language)
                        UserDefaults.standard.set(true, forKey: Self.resumeKey)
                        Self.restarting = true
                        LanguageChoice.relaunch()
                    } else if let next = Page(rawValue: page.rawValue + 1) {
                        page = next
                    } else {
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .accessibilityValue(Text("Page \(page.rawValue + 1) of \(Page.allCases.count)"))
                .accessibilityIdentifier("onboardingContinue")
            }
            .controlSize(.large)
            .padding(16)
        }
        .frame(width: 480, height: 640)
        // LSUIElement apps are never active on their own; without this the window opens behind others.
        .onAppear {
            NSApplication.shared.activate()
            UserDefaults.standard.removeObject(forKey: Self.resumeKey)
        }
        .onDisappear {
            if !Self.restarting {
                onboarded = true
            }
        }
    }
}

// MARK: - Pages

private struct LanguagePage: View {
    @Binding var selection: String?

    var body: some View {
        VStack(spacing: 28) {
            PageHeader(
                title: "Choose a Language",
                // swiftlint:disable:next line_length
                subtitle: "Forewarn speaks your Mac's language unless you pick another. You can change it later in Settings."
            ) {
                SymbolBadge(symbol: "globe")
            }
            LanguagePicker(selection: $selection)
                .controlSize(.large)
        }
        .padding(.horizontal, 32)
        .padding(.top, 28)
    }
}

private struct WelcomePage: View {
    @Environment(OverviewStore.self) private var store

    var body: some View {
        VStack(spacing: 20) {
            PageHeader(
                title: "Welcome to Forewarn",
                // swiftlint:disable:next line_length
                subtitle: "Forewarn learns how you use this Mac and warns you before something runs out, with the time it will happen."
            ) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .frame(width: 88, height: 88)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 16) {
                Feature(symbol: "battery.25percent", title: "Battery",
                        // swiftlint:disable:next line_length
                        detail: "Learns when you usually plug in, and warns you if the battery would run low before then.")
                Feature(symbol: "internaldrive", title: "Disk space",
                        detail: "Warns weeks before the disk fills up.")
                Feature(symbol: "moon.zzz", title: "Battery drain during sleep",
                        // swiftlint:disable:next line_length
                        detail: "Spots nights that cost far more battery than usual, and names the app that kept the Mac awake.")
                Feature(symbol: "cellularbars", title: "Mobile data, if you want",
                        detail: "Keeps an eye on a monthly hotspot or data plan limit. You can turn it on in a moment.")
            }
            // Teach where it lives with the real thing: the same label that sits in the menu bar.
            HStack(spacing: 10) {
                MenuBarPreview(overview: store.overview)
                Text("Forewarn lives in the menu bar. Click it any time to see the forecast.")
                    .foregroundStyle(.subdued)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .card()
        }
        .padding(.horizontal, 32)
        .padding(.top, 28)
    }
}

private struct PrivacyPage: View {
    var body: some View {
        VStack(spacing: 24) {
            PageHeader(
                title: "Everything stays on this Mac",
                subtitle: "Forewarn needs no account and asks for no special permissions."
            ) {
                SymbolBadge(symbol: "hand.raised.fill")
            }
            VStack(alignment: .leading, spacing: 16) {
                Feature(symbol: "lock", title: "Measured and stored locally",
                        // swiftlint:disable:next line_length
                        detail: "Battery level, free disk space, network totals and sleep events, kept in your Library folder.")
                Feature(symbol: "network.slash", title: "Nothing is sent anywhere",
                        detail: "No analytics, no tracking. Forecasts are computed on this Mac.")
                Feature(symbol: "eye.slash", title: "Totals, never content",
                        detail: "Forewarn counts how much data goes through a network, not what is in it.")
                Feature(symbol: "leaf", title: "Light on the battery",
                        // swiftlint:disable:next line_length
                        detail: "Forewarn measures its own energy use and shows it in the menu. The goal: under 0.05% of the battery a day.")
            }
        }
        .padding(.horizontal, 32)
        .padding(.top, 28)
    }
}

private struct SetupPage: View {
    var body: some View {
        VStack(spacing: 0) {
            // No picture here: the controls need the room, and they grow when the data limit is on.
            PageHeader(title: "Set up Forewarn", subtitle: "Both optional. You can change them later in Settings.") {
                EmptyView()
            }
            .padding(.horizontal, 32)
            .padding(.top, 36)

            Form {
                LaunchAtLoginSection()
                MeteredDataSection()
                Section {
                    Explainer(symbol: "personalhotspot", title: "Counts only expensive networks",
                              // swiftlint:disable:next line_length
                              detail: "iPhone hotspots and connections macOS marks as metered. Wi-Fi and Ethernet are not counted.")
                    Explainer(symbol: "bell", title: "Warns before you run out",
                              // swiftlint:disable:next line_length
                              detail: "If this month's pace would use up the limit before the reset day, Forewarn tells you when.")
                }
            }
            .formStyle(.grouped)
        }
    }
}

// MARK: - Parts

private struct PageHeader<Art: View>: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    @ViewBuilder let art: Art

    var body: some View {
        VStack(spacing: 10) {
            art
            Text(title)
                .font(.largeTitle.weight(.semibold))
                .multilineTextAlignment(.center)
            Text(subtitle)
                .font(.title3)
                .foregroundStyle(.subdued)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// A large symbol in a tinted circle, for pages that have no picture of their own.
private struct SymbolBadge: View {
    let symbol: String

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 34, weight: .medium))
            .foregroundStyle(.tint)
            .frame(width: 72, height: 72)
            .background(.tint.quaternary, in: Circle())
            .accessibilityHidden(true)
    }
}

/// Symbol, title and one sentence, as in Apple's own "Welcome to…" screens.
private struct Feature: View {
    let symbol: String
    let title: LocalizedStringKey
    let detail: LocalizedStringKey

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail)
                    .foregroundStyle(.subdued)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct PageDots: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0 ..< count, id: \.self) { index in
                Circle()
                    .fill(index == current ? Color.primary : Color.primary.opacity(0.45)) // 3:1 for indicators
                    .frame(width: 7, height: 7)
            }
        }
        .accessibilityHidden(true) // the Continue button says the page (`accessibilityValue`)
    }
}

#Preview {
    OnboardingView()
        .environment(OverviewStore())
}
