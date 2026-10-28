import SwiftUI

@main
struct ForewarnApp: App {
    @State private var store = OverviewStore()
    @AppStorage(SettingsKey.onboarded) private var onboarded = false

    init() {
        // Screenshots and UI tests only (`-FWAppearance dark`): the app has no appearance setting of its own (HIG).
        if UserDefaults.standard.string(forKey: "FWAppearance") == "dark" {
            NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        }
    }

    var body: some Scene {
        // A popover, not a menu: the forecast chart is too rich for a menu (HIG, The menu bar › Menu bar extras).
        MenuBarExtra {
            PopoverView(overview: store.overview, onRefresh: { store.refresh() })
                .environment(store)
                .onAppear { store.refresh() }
        } label: {
            MenuBarLabel(overview: store.overview)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(store)
        }

        Window("Welcome to Forewarn", id: OnboardingView.windowID) {
            OnboardingView()
                .environment(store)
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .restorationBehavior(.disabled)
        // Opens by itself only on the first launch.
        .defaultLaunchBehavior(onboarded ? .suppressed : .presented)

        Window("Forewarn Debug", id: DebugView.windowID) {
            DebugView()
                .environment(store)
        }
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(UserDefaults.standard.bool(forKey: "FWDebug") ? .presented : .suppressed)
    }
}
