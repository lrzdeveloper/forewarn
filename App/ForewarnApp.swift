import SwiftUI

@main
struct ForewarnApp: App {
    var body: some Scene {
        MenuBarExtra("Forewarn", systemImage: "gauge.with.dots.needle.67percent") {
            MenuBarView()
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
        }
    }
}

struct MenuBarView: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Still learning your habits")
                .font(.headline)
            Divider()
            HStack {
                Button("Settings…") {
                    // LSUIElement apps are never active on their own; without this the window opens behind others.
                    NSApplication.shared.activate()
                    openSettings()
                }
                .keyboardShortcut(",")
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            }
        }
        .padding()
        .frame(width: 320)
    }
}
