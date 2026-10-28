import ServiceManagement
import SwiftUI

/// Shared by Settings › General and the welcome window.
struct LaunchAtLoginSection: View {
    // SMAppService is the source of truth; no mirrored UserDefaults key. Read again whenever Forewarn comes to the
    // front: the person may have changed it, or approved it, in System Settings meanwhile.
    @State private var status = SMAppService.mainApp.status
    @State private var errorMessage: String?

    var body: some View {
        Section {
            // Closure, not a method reference: Swift 6.3 crashes in IRGen on the method-reference thunk.
            // Waiting for approval counts as on: it was asked for, and turning it off withdraws the request.
            Toggle("Open at login", isOn: Binding(
                get: { status == .enabled || status == .requiresApproval }, set: { setLaunchAtLogin($0) }
            ))
            .accessibilityIdentifier("launchAtLogin")
            if status == .requiresApproval, errorMessage == nil {
                Button("Open Login Items Settings") { SMAppService.openSystemSettingsLoginItems() }
                    .accessibilityIdentifier("openLoginItems")
            }
        } footer: {
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red)
            } else if status == .requiresApproval {
                Text("Waiting for your approval in System Settings › General › Login Items.")
            } else {
                Text("Forewarn starts quietly in the menu bar and checks in only when something changes.")
            }
        }
        .onAppear { status = SMAppService.mainApp.status }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            status = SMAppService.mainApp.status
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
        status = SMAppService.mainApp.status
    }
}
