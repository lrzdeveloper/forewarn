import ForewarnKit
import ServiceManagement
import SwiftUI

/// UserDefaults keys shared by Settings and the features that read them.
enum SettingsKey {
    static let menuBarStyle = "menuBarStyle"
    static let menuBarIcon = "menuBarIcon"
    static let meteredLimitEnabled = "meteredLimitEnabled"
    static let meteredLimitGB = "meteredLimitGB"
    static let meteredResetDay = "meteredResetDay"
    static let onboarded = "onboarded"
    /// The Settings pane shown; a notification action can pick one before opening Settings.
    static let settingsPane = "settingsPane"
    static func notify(_ feature: String) -> String {
        "notify.\(feature)"
    }
}

/// Toolbar panes with grouped forms, like the system's own settings windows (HIG, Settings).
struct SettingsView: View {
    @AppStorage(SettingsKey.settingsPane) private var pane = "general"
    @State private var window: NSWindow?
    @State private var centre = KeepsVerticalCentre()

    var body: some View {
        TabView(selection: $pane) {
            Tab("General", systemImage: "gearshape", value: "general") { GeneralPane() }
            Tab("Notifications", systemImage: "bell.badge", value: "notifications") { NotificationsPane() }
            Tab("Data", systemImage: "cellularbars", value: "data") { DataPane() }
            Tab("Privacy", systemImage: "hand.raised", value: "privacy") { PrivacyPane() }
            Tab("About", systemImage: "info.circle", value: "about") { AboutPane() }
        }
        .frame(width: 520)
        .background(HostingWindowReader(window: $window).accessibilityHidden(true))
        .onChange(of: window) {
            if let window {
                centre.attach(window)
            }
        }
    }
}

// MARK: - General

private struct GeneralPane: View {
    @AppStorage(SettingsKey.menuBarStyle) private var style = MenuBarStyle.iconAndTime
    @AppStorage(SettingsKey.menuBarIcon) private var icon = MenuBarIcon.battery
    @Environment(OverviewStore.self) private var store

    var body: some View {
        Form {
            LanguageSection()
            LaunchAtLoginSection()
            Section {
                Picker("Show", selection: $style) {
                    ForEach(MenuBarStyle.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.radioGroup)
                Picker("Icon", selection: $icon) {
                    Label("Battery", systemImage: "battery.75percent").tag(MenuBarIcon.battery)
                    Label("Hourglass", systemImage: "hourglass").tag(MenuBarIcon.hourglass)
                }
                .pickerStyle(.radioGroup)
                LabeledContent("Preview") {
                    MenuBarPreview(overview: store.overview)
                }
            } header: {
                Text("Menu bar")
            } footer: {
                Text("Time left follows how you use the Mac right now. While charging it shows the time to full.")
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// The app's language. Same storage as System Settings' per-app language; applies on restart.
private struct LanguageSection: View {
    @State private var language = LanguageChoice.current

    var body: some View {
        Section {
            LabeledContent("Language") {
                LanguagePicker(selection: $language)
            }
            .onChange(of: language) { LanguageChoice.set(language) }
            if language != LanguageChoice.atLaunch {
                Button("Restart Forewarn") { LanguageChoice.relaunch() }
                    .accessibilityIdentifier("restartForLanguage")
            }
        } footer: {
            Text("Forewarn switches language when it restarts.")
        }
    }
}

/// Shared by Settings › General and the welcome window.
struct LaunchAtLoginSection: View {
    // SMAppService is the source of truth; no mirrored UserDefaults key.
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var errorMessage: String?

    var body: some View {
        Section {
            // Closure, not a method reference: Swift 6.3 crashes in IRGen on the method-reference thunk.
            Toggle("Open at login", isOn: Binding(get: { launchAtLogin }, set: { setLaunchAtLogin($0) }))
                .accessibilityIdentifier("launchAtLogin")
        } footer: {
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red)
            } else {
                Text("Forewarn starts quietly in the menu bar and checks in only when something changes.")
            }
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

// MARK: - Notifications

private struct NotificationsPane: View {
    @Environment(OverviewStore.self) private var overviewStore
    @AppStorage(Recorder.scanDownloadsKey) private var scanDownloads = false

    /// Kinds whose threshold the feedback loop raised, in toggle order.
    private var raised: [String] {
        guard let log = try? overviewStore.recorder?.store.notifications() else { return [] }
        let steps = Thresholds.steps(log)
        return Insight.Kind.allCases.filter { (steps[$0] ?? 0) > 0 }.map(NotificationText.placeholder)
    }

    var body: some View {
        Form {
            Section {
                FeatureToggle(key: "battery", title: "Battery running low", symbol: "battery.25percent",
                              detail: "Before the battery reaches 10%, if that comes before you usually plug in.")
                FeatureToggle(key: "disk", title: "Disk filling up", symbol: "internaldrive",
                              detail: "When the disk is expected to fill within three weeks.")
                FeatureToggle(key: "sleep", title: "Battery drain during sleep", symbol: "moon.zzz",
                              detail: "When a night costs far more battery than usual, and which app kept it awake.")
                FeatureToggle(key: "data", title: "Mobile data", symbol: "cellularbars",
                              detail: "When you are on pace to use up your monthly limit.")
                FeatureToggle(key: "health", title: "Battery health", symbol: "bolt.heart",
                              detail: "At most once a month, only when something changed.")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    if !raised.isEmpty {
                        Text(
                            // swiftlint:disable:next line_length
                            "You closed three warnings in a row, so Forewarn now warns you later about: \(raised.formatted(.list(type: .and)))."
                        )
                    }
                    Text("Forewarn asks for permission the first time a warning would help.")
                }
            }
            Section {
                Toggle(isOn: $scanDownloads) {
                    Text("Look in Downloads too")
                    Text("Disk warnings can name what grew there. macOS asks for permission the first time.")
                }
            } header: {
                Text("Disk suggestions")
            } footer: {
                Text(
                    // swiftlint:disable:next line_length
                    "Once a week, on power, Forewarn adds up folder sizes: Xcode build files, caches, and Downloads if allowed. It never opens your files."
                )
            }
            Section {
                Button("Open Notification Settings…") {
                    NSWorkspace.shared
                        .open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                }
            } footer: {
                Text("Banners, sounds and Focus are set in System Settings.")
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct FeatureToggle: View {
    @AppStorage private var isOn: Bool
    let title: LocalizedStringKey
    let symbol: String
    let detail: LocalizedStringKey

    init(key: String, title: LocalizedStringKey, symbol: String, detail: LocalizedStringKey) {
        _isOn = AppStorage(wrappedValue: true, SettingsKey.notify(key))
        self.title = title
        self.symbol = symbol
        self.detail = detail
    }

    var body: some View {
        Toggle(isOn: $isOn) {
            Label {
                Text(title)
                Text(detail)
            } icon: {
                Image(systemName: symbol)
                    .frame(width: 24)
            }
        }
    }
}

// MARK: - Data

private struct DataPane: View {
    var body: some View {
        Form {
            MeteredDataSection()
            Section("How it works") {
                Explainer(symbol: "personalhotspot", title: "Counts only expensive networks",
                          // swiftlint:disable:next line_length
                          detail: "macOS marks iPhone hotspots and some cellular connections as expensive. Wi-Fi and Ethernet are not counted.")
                Explainer(symbol: "number", title: "Reads totals, not content",
                          // swiftlint:disable:next line_length
                          detail: "Every 5 minutes on an expensive network, Forewarn reads the byte counters macOS keeps for each network interface. It never sees what you send or receive.")
                Explainer(symbol: "lock", title: "Stays on this Mac",
                          detail: "Only the totals are stored, next to the rest of Forewarn's data.")
                Explainer(symbol: "bell", title: "Warns before you run out",
                          // swiftlint:disable:next line_length
                          detail: "If this month's pace would reach your limit before the reset day, Forewarn tells you when.")
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Opt-in monthly limit for expensive networks. Shared by Settings › Data and the welcome window.
struct MeteredDataSection: View {
    @AppStorage(SettingsKey.meteredLimitEnabled) private var limitEnabled = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(SettingsKey.meteredLimitGB) private var limitGB = 20
    @AppStorage(SettingsKey.meteredResetDay) private var resetDay = 1

    var body: some View {
        Section {
            Toggle("Track a monthly data limit", isOn: $limitEnabled)
                .accessibilityIdentifier("trackDataLimit")
            if limitEnabled {
                Stepper(value: $limitGB, in: 1 ... 500) {
                    LabeledContent("Monthly limit") {
                        Text(Measurement(value: Double(limitGB), unit: UnitInformationStorage.gigabytes)
                            .formatted(.measurement(width: .abbreviated)))
                            .monospacedDigit()
                    }
                }
                Picker("Resets on day", selection: $resetDay) {
                    ForEach(1 ... 28, id: \.self) { Text("\($0)").tag($0) }
                }
            }
        } header: {
            Text("Mobile data")
        } footer: {
            Text("For when you work from an iPhone hotspot or a data plan with a monthly allowance.")
        }
        .animation(reduceMotion ? nil : .default, value: limitEnabled)
    }
}

/// A read-only settings row: symbol, title and a sentence, like the explanations in System Settings.
struct Explainer: View {
    let symbol: String
    let title: LocalizedStringKey
    let detail: LocalizedStringKey

    var body: some View {
        Label {
            Text(title)
            Text(detail)
        } icon: {
            Image(systemName: symbol)
                .frame(width: 24)
        }
    }
}

// MARK: - Privacy

private struct PrivacyPane: View {
    @Environment(OverviewStore.self) private var overviewStore
    @State private var confirmingDelete = false
    @State private var errorMessage: String?

    private var store: Store? { overviewStore.recorder?.store }

    var body: some View {
        Form {
            Section {
                LabeledContent("Measurements") {
                    Text("Stay on this Mac")
                }
                LabeledContent("Location") {
                    Text("~/Library/Application Support/Forewarn")
                        .textSelection(.enabled)
                }
                LabeledContent("Network") {
                    Text("No connections")
                }
            } footer: {
                Text("Forewarn reads battery, disk, network counters and sleep events. Nothing leaves this Mac.")
            }
            Section {
                LabeledContent("Your data") {
                    HStack {
                        Button("Export…", systemImage: "square.and.arrow.up", action: export)
                        Button("Delete…", systemImage: "trash") { confirmingDelete = true }
                            .accessibilityIdentifier("deleteData")
                    }
                }
                .disabled(store == nil)
            } footer: {
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                } else {
                    Text("Export saves every measurement as a CSV file. Delete removes them; forecasts start over.")
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
        // Chosen on purpose, so the button is not styled destructive; Cancel is there and is not the default.
        .alert("Delete all Forewarn data?", isPresented: $confirmingDelete) {
            Button("Delete", action: delete)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every measurement and event recorded on this Mac is removed. This can't be undone.")
        }
    }

    private func export() {
        guard let store else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = String(localized: "Forewarn data.csv")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.exportCSV().write(to: url, atomically: true, encoding: .utf8)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete() {
        do {
            try store?.deleteAll()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        overviewStore.refresh()
    }
}

#Preview { SettingsView().environment(OverviewStore()) }
