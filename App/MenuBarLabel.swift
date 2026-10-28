import ForewarnKit
import SwiftUI

/// What the menu bar item shows (Settings › General › Menu bar).
enum MenuBarStyle: String, CaseIterable, Identifiable {
    case iconAndTime, iconOnly, percentAndTime, timeOnly
    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .iconAndTime: "Icon and time left"
        case .iconOnly: "Icon only"
        case .percentAndTime: "Icon, percentage and time left"
        case .timeOnly: "Time left only"
        }
    }
}

enum MenuBarIcon: String, CaseIterable, Identifiable {
    case battery, hourglass
    var id: Self { self }
}

/// At-a-glance state in the menu bar. Template symbols only; state is shown by shape, not colour.
/// Battery: the level, a bolt while charging, a warning triangle when something needs attention.
/// Hourglass: Forewarn's mark, the app icon's silhouette, always an hourglass; emptied when something needs attention.
/// The system's own battery item already shows charging.
struct MenuBarLabel: View {
    let overview: Overview
    @AppStorage(SettingsKey.menuBarStyle) private var style = MenuBarStyle.iconAndTime
    @AppStorage(SettingsKey.menuBarIcon) private var iconStyle = MenuBarIcon.battery

    var body: some View {
        let details = [style == .percentAndTime ? percent : nil, remaining].compactMap(\.self).joined(separator: "  ")
        switch style {
        case .timeOnly where !details.isEmpty:
            Text(details)
        case .iconOnly:
            icon
        default:
            // Separate views: MenuBarExtra drops images interpolated into Text. The space gives the digits room.
            icon
            if !details.isEmpty {
                Text(" " + details)
            }
        }
    }

    /// The label sits on the image alone: on a group of views it recursed through its children and crashed.
    private var icon: some View {
        Image(systemName: symbol)
            .accessibilityLabel(overview.needsAttention ? String(localized: "Forewarn, needs attention") : "Forewarn")
    }

    private var symbol: String {
        guard let battery = overview.battery else { return iconStyle == .battery ? "internaldrive" : "hourglass" }
        if overview.needsAttention {
            return iconStyle == .battery ? "exclamationmark.triangle.fill" : "hourglass.bottomhalf.filled"
        }
        guard iconStyle == .battery else { return "hourglass" }
        return battery.isCharging ? "battery.100percent.bolt" : battery.levelSymbol
    }

    private var percent: String? {
        overview.battery.map { ($0.percent / 100).formatted(.percent.precision(.fractionLength(0))) }
    }

    /// On battery: until the forecast reaches 10%, else macOS's estimate (which follows current use).
    /// Charging: macOS's time to full. On power and not charging: nothing.
    private var remaining: String? {
        guard let battery = overview.battery else { return nil }
        let seconds: Double? = if battery.isCharging {
            battery.systemEstimateMinutes.map { Double($0 * 60) }
        } else if battery.isOnAC {
            nil
        } else {
            battery.runsLowAt.map(\.timeIntervalSinceNow) ?? battery.systemEstimateMinutes.map { Double($0 * 60) }
        }
        guard let seconds, seconds > 0 else { return nil }
        return Duration.seconds(seconds)
            .formatted(.units(allowed: [.hours, .minutes], width: .narrow, maximumUnitCount: 2))
    }
}

extension Overview.Battery {
    /// SF Symbol matching the charge level, as in the system's battery menu.
    var levelSymbol: String {
        switch percent {
        case ..<13: "battery.0percent"
        case ..<38: "battery.25percent"
        case ..<63: "battery.50percent"
        case ..<88: "battery.75percent"
        default: "battery.100percent"
        }
    }
}

/// The menu bar label drawn inside a window, as in Settings and the welcome window.
/// The HStack matters: the label is several sibling views, and padding on them alone would wrap each one.
struct MenuBarPreview: View {
    let overview: Overview

    var body: some View {
        HStack(spacing: 0) { MenuBarLabel(overview: overview) }
            .foregroundStyle(.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(.quaternary, in: Capsule())
    }
}
