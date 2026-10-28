import AppKit
import ForewarnKit
import os
import UserNotifications

/// The words of each warning. Title-style titles that carry the news, a sentence or two of why,
/// one useful action (HIG, Notifications).
enum NotificationText {
    static func title(_ insight: Insight) -> String {
        switch insight {
        case let .batteryLow(at, _, _):
            String(localized: "Battery Reaches 10% Around \(at.formatted(date: .omitted, time: .shortened))")
        case let .diskFilling(at, _, _, _):
            if let at, at.timeIntervalSinceNow > 86400 {
                String(localized: "Disk Full in About \(relative(at))")
            } else {
                String(localized: "Disk Almost Full")
            }
        case let .sleepDrain(lost, _, _, _):
            String(localized: "Lost \(percent(lost)) While Asleep")
        case let .dataRunsOut(at, _, _):
            String(localized: "Mobile Data Runs Out \(at.formatted(.dateTime.weekday(.wide).day().month()))")
        case let .batteryHealth(health, _):
            String(localized: "Battery Health \(percent(health))")
        }
    }

    static func body(_ insight: Insight) -> String {
        switch insight {
        case let .batteryLow(_, plugIn, _):
            if let plugIn {
                String(localized: """
                You usually plug in around \(plugIn.formatted(date: .omitted, time: .shortened)). \
                Charge when you can.
                """)
            } else {
                String(localized: "That is at this pace. Charge when you can.")
            }
        case let .diskFilling(_, free, folder, growth):
            if let folder, let growth {
                String(localized: """
                \(bytes(free)) free. \(URL(filePath: folder).lastPathComponent) grew by \(bytes(growth)) this week.
                """)
            } else {
                String(localized: "\(bytes(free)) free.")
            }
        case let .sleepDrain(_, hours, usual, blockers):
            if let first = blockers.first {
                String(localized: "Usually about \(percent(usual * hours)) a night. \(first) kept the Mac awake.")
            } else {
                String(localized: "Usually about \(percent(usual * hours)) a night.")
            }
        case let .dataRunsOut(_, used, limit):
            String(
                localized: "\(bytes(used)) of \(bytes(limit)) used. At this pace you reach the limit before it resets."
            )
        case let .batteryHealth(_, previous):
            if let previous {
                String(localized: "Down from \(percent(previous)) at the last report.")
            } else {
                String(localized: "At this pace it reaches 80% within six months.")
            }
        }
    }

    /// Shown when previews are hidden: what it is about, nothing more (HIG).
    static func placeholder(_ kind: Insight.Kind) -> String {
        switch kind {
        case .battery: String(localized: "Battery")
        case .disk: String(localized: "Disk space")
        case .sleep: String(localized: "Sleep")
        case .data: String(localized: "Mobile data")
        case .health: String(localized: "Battery health")
        }
    }

    private static func percent(_ value: Double) -> String {
        (value / 100).formatted(.percent.precision(.fractionLength(0)))
    }

    private static func bytes(_ value: Double) -> String {
        Int64(value).formatted(.byteCount(style: .file))
    }

    private static func relative(_ date: Date) -> String {
        Duration.seconds(date.timeIntervalSinceNow)
            .formatted(.units(allowed: [.weeks, .days], width: .wide, maximumUnitCount: 1))
    }
}

/// Sends warnings through `UNUserNotificationCenter` and records what people do with them: permission
/// asked the first time a warning would help, interruption level `.active`, one category per feature with its action,
/// dismissals reported so the feedback loop can count them.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    private let store: Store
    private let center = UNUserNotificationCenter.current()
    private let log = Logger(subsystem: "io.github.lrzdeveloper.forewarn", category: "notifications")
    /// What people did with a warning, when storing it failed: tried again on each check, `maximumAttempts` times.
    /// The feedback loop reads only what is stored, so a lost dismissal would move a threshold silently.
    private var pendingActions: [PendingAction] = []
    private static let maximumAttempts = 12 // an hour of 5-minute checks
    /// Opens Settings on a pane ("data" for Adjust Limit). Outside a view there is no `openSettings`; the app menu's
    /// own Settings… item (⌘,) opens the SwiftUI Settings scene the same way.
    private func openSettings(_ pane: String) {
        UserDefaults.standard.set(pane, forKey: SettingsKey.settingsPane)
        NSApplication.shared.activate()
        guard let appMenu = NSApplication.shared.mainMenu?.items.first?.submenu,
              let index = appMenu.items.firstIndex(where: { $0.keyEquivalent == "," }) else { return }
        appMenu.performActionForItem(at: index)
    }

    private enum ActionID {
        static let acknowledge = "acknowledge", willHavePower = "willHavePower", open = "open"
    }

    init(store: Store) {
        self.store = store
        super.init()
        center.delegate = self
        center.setNotificationCategories(Set(Insight.Kind.allCases.map(Self.category)))
    }

    private static func category(_ kind: Insight.Kind) -> UNNotificationCategory {
        let ok = UNNotificationAction(
            identifier: ActionID.acknowledge, title: String(localized: "OK"), options: [],
            icon: UNNotificationActionIcon(systemImageName: "checkmark")
        )
        let actions: [UNNotificationAction] = switch kind {
        case .battery: [ok, UNNotificationAction(
                identifier: ActionID.willHavePower, title: String(localized: "I'll Have Power"), options: [],
                icon: UNNotificationActionIcon(systemImageName: "powerplug.portrait")
            )]
        case .disk: [UNNotificationAction(
                identifier: ActionID.open, title: String(localized: "Show Me"), options: [.foreground],
                icon: UNNotificationActionIcon(systemImageName: "folder")
            )]
        case .sleep: [UNNotificationAction(
                identifier: ActionID.open, title: String(localized: "Show Details"), options: [.foreground],
                icon: UNNotificationActionIcon(systemImageName: "moon.zzz")
            )]
        case .data: [UNNotificationAction(
                identifier: ActionID.open, title: String(localized: "Adjust Limit"), options: [.foreground],
                icon: UNNotificationActionIcon(systemImageName: "slider.horizontal.3")
            )]
        case .health: [ok]
        }
        return UNNotificationCategory(
            identifier: kind.rawValue, actions: actions, intentIdentifiers: [],
            hiddenPreviewsBodyPlaceholder: NotificationText.placeholder(kind), options: [.customDismissAction]
        )
    }

    /// Logs and sends each insight. Logged even without permission: the popover lists recent warnings, and the
    /// rate limiter must not resend what was already decided. Logged before the first wait, so a check running
    /// meanwhile already sees them. One that Notification Center refuses is marked undelivered: the rate limiter
    /// lets it be tried again.
    func send(_ insights: [Insight], now: Date = .now) async {
        retryPendingActions()
        let logged = insights
            .compactMap { insight in (try? store.logNotification(insight, at: now)).map { (insight, $0) } }
        guard !logged.isEmpty else { return }
        var settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
            settings = await center.notificationSettings()
        }
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
        else { return }
        for (insight, id) in logged {
            let content = UNMutableNotificationContent()
            content.title = NotificationText.title(insight)
            content.body = NotificationText.body(insight)
            content.categoryIdentifier = insight.kind.rawValue
            content.interruptionLevel = .active
            // Only the battery warning makes a sound: it is the one with a deadline today.
            content.sound = insight.kind == .battery ? .default : nil
            content.userInfo = insight.details
            do {
                try await center.add(UNNotificationRequest(identifier: String(id), content: content, trigger: nil))
            } catch {
                log.error("not delivered: \(error.localizedDescription, privacy: .public)")
                save(.undelivered, forNotification: id)
            }
        }
    }

    private func save(_ action: SentNotification.Action, forNotification id: Int64) {
        do {
            try store.setAction(action, forNotification: id)
        } catch {
            log.error("action not saved, will retry: \(error.localizedDescription, privacy: .public)")
            pendingActions.append(PendingAction(id: id, action: action, attempts: 1))
        }
    }

    private func retryPendingActions() {
        pendingActions = pendingActions.compactMap { pending in
            do {
                try store.setAction(pending.action, forNotification: pending.id)
                return nil
            } catch {
                guard pending.attempts + 1 < Self.maximumAttempts else {
                    log.error("action dropped: \(error.localizedDescription, privacy: .public)")
                    return nil
                }
                return PendingAction(id: pending.id, action: pending.action, attempts: pending.attempts + 1)
            }
        }
    }

    /// Sends an example of each warning without logging it (debug window): for checking the words and actions.
    func preview(_ insight: Insight) async {
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
        let content = UNMutableNotificationContent()
        content.title = NotificationText.title(insight)
        content.body = NotificationText.body(insight)
        content.categoryIdentifier = insight.kind.rawValue
        content.interruptionLevel = .active
        content.userInfo = insight.details
        let id = "preview-\(insight.kind.rawValue)-\(Date.now.timeIntervalSince1970)"
        try? await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    static func examples(now: Date = .now) -> [Insight] {
        [
            .batteryLow(at: now + 3 * 3600, plugIn: now + 5 * 3600, chance: 0.8),
            .diskFilling(at: now + 16 * 86400, freeBytes: 42e9, folder: URL.cachesDirectory.path, folderGrowth: 6e9),
            .sleepDrain(lost: 14, hours: 8, usualPerHour: 0.25, blockers: ["Docker"]),
            .dataRunsOut(at: now + 6 * 86400, usedBytes: 15e9, limitBytes: 20e9),
            .batteryHealth(percent: 88, previous: 91),
        ]
    }

    // MARK: UNUserNotificationCenterDelegate

    /// A menu bar app is rarely in front, but when it is the warning still shows.
    nonisolated func userNotificationCenter(
        _: UNUserNotificationCenter, willPresent _: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(
        _: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let id = Int64(response.notification.request.identifier)
        let kind = Insight.Kind(rawValue: response.notification.request.content.categoryIdentifier)
        let details = response.notification.request.content.userInfo as? [String: String] ?? [:]
        let action = response.actionIdentifier
        await MainActor.run { handle(action: action, id: id, kind: kind, details: details) }
    }

    private func handle(action: String, id: Int64?, kind: Insight.Kind?, details: [String: String]) {
        let recorded: SentNotification.Action? = switch action {
        case ActionID.acknowledge: .acknowledged
        case ActionID.willHavePower: .willHavePower
        case ActionID.open, UNNotificationDefaultActionIdentifier: .opened
        case UNNotificationDismissActionIdentifier: .dismissed
        default: nil
        }
        if let id, let recorded {
            save(recorded, forNotification: id)
        }
        if recorded == .opened, let kind {
            open(Insight(kind: kind, details: details))
        }
    }

    /// Where each warning's action (or a click on it) leads: the folder, Battery settings, or the data limit.
    private func open(_ insight: Insight?) {
        switch insight {
        case let .diskFilling(_, _, folder?, _):
            NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: folder)])
        case .diskFilling:
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.settings.Storage")!)
        case .sleepDrain, .batteryLow, .batteryHealth:
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension")!)
        case .dataRunsOut:
            openSettings("data")
        case nil:
            break
        }
    }
}

/// A person's response to a warning that could not be stored yet.
private struct PendingAction {
    let id: Int64
    let action: SentNotification.Action
    let attempts: Int
}
