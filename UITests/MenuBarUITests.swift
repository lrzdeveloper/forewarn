import XCTest

/// End-to-end: launches the real app and drives it through the accessibility tree.
/// Locally, the Forewarn icon must be visible: menu bar managers that hide new items make the click miss.
final class MenuBarUITests: XCTestCase {
    @MainActor
    private func openPopover(sample: String, _ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-FWSample", sample, "-onboarded", "YES"] + extra
        app.launch()
        let statusItem = app.statusItems.firstMatch
        XCTAssertTrue(statusItem.waitForExistence(timeout: 5))
        statusItem.click()
        let title = app.descendants(matching: .any)["statusTitle"]
        // A click can land before the item is ready (right after the previous test's app quits), or while macOS asks
        // for the password to enable Automation Mode at the start of a run: try again, a few times.
        for _ in 0 ..< 4 where !title.waitForExistence(timeout: 5) {
            statusItem.click()
        }
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        return app
    }

    /// Popover with a forecast chart leads to Settings.
    @MainActor
    func testPopoverShowsForecastAndLeadsToSettings() {
        let app = openPopover(sample: "risky")
        defer { app.terminate() }
        XCTAssertTrue(app.descendants(matching: .any)["batteryChart"].exists)

        app.buttons["openSettings"].click()
        let settings = app.windows["com_apple_SwiftUI_Settings_window"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.toolbars.buttons.element(boundBy: 0).click() // General; Settings reopens the last pane viewed
        // Assert presence only: toggling would register a real login item.
        XCTAssertTrue(app.switches["launchAtLogin"].waitForExistence(timeout: 5))
        // Only Settings stays open: the popover closes.
        XCTAssertTrue(app.dialogs.firstMatch.waitForNonExistence(timeout: 3))
    }

    /// First launch: the welcome window opens by itself, walks through its three pages and closes.
    @MainActor
    func testOnboardingWalksThroughSetup() {
        let app = XCUIApplication()
        app.launchArguments = ["-FWSample", "fine", "-onboarded", "NO"]
        app.launch()
        defer { app.terminate() }
        let next = app.buttons["onboardingContinue"]
        XCTAssertTrue(next.waitForExistence(timeout: 5))
        for page in ["language", "welcome", "privacy", "setup"] {
            // Wait for the page itself: clicking on before it has replaced the last one loses the click.
            XCTAssertTrue(app.descendants(matching: .any)["onboardingPage-\(page)"].waitForExistence(timeout: 5))
            app.activate()
            let attachment = XCTAttachment(screenshot: app.windows["welcome"].screenshot())
            attachment.name = "onboarding-\(page)"
            attachment.lifetime = .keepAlways
            add(attachment)
            if page == "setup" {
                // Assert presence only: toggling would register a login item or change real settings.
                XCTAssertTrue(app.switches["launchAtLogin"].exists)
                XCTAssertTrue(app.switches["trackDataLimit"].exists)
            }
            next.click()
        }
        XCTAssertTrue(next.waitForNonExistence(timeout: 3))
    }

    /// Screenshots of every state for design review, kept in the .xcresult.
    @MainActor
    func testScreenshots() {
        for sample in ["risky", "fine", "charging", "plugged", "learning", "shortfall"] {
            let app = openPopover(sample: sample)
            let attachment = XCTAttachment(screenshot: app.dialogs.firstMatch.screenshot())
            attachment.name = "popover-\(sample)"
            attachment.lifetime = .keepAlways
            add(attachment)
            if sample == "risky" {
                captureSettings(app)
            }
            app.terminate()
        }
    }

    @MainActor
    private func captureSettings(_ app: XCUIApplication, suffix: String = "") {
        app.buttons["openSettings"].click()
        let window = app.windows["com_apple_SwiftUI_Settings_window"]
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        // By position: the labels are localized.
        for (index, pane) in ["General", "Notifications", "Data", "Privacy", "About"].enumerated() {
            window.toolbars.buttons.element(boundBy: index).click()
            let attachment = XCTAttachment(screenshot: window.screenshot())
            attachment.name = "settings-\(pane)\(suffix)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    // MARK: Languages, appearance, keyboard, accessibility

    static let italian = ["-AppleLanguages", "(it)", "-AppleLocale", "it_IT"]
    static let english = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
    /// The longest words of the 27 languages: the check for truncated text.
    static let german = ["-AppleLanguages", "(de)", "-AppleLocale", "de_DE"]
    static let dark = ["-FWAppearance", "dark"]

    /// Italian and dark appearance: screenshots in light and dark, English and Italian.
    @MainActor
    func testItalianAndDarkScreenshots() {
        let variants = [
            ("en", Self.english), // the README's light screenshot
            ("it", Self.italian),
            ("en-dark", Self.english + Self.dark),
            ("it-dark", Self.italian + Self.dark),
            ("de", Self.german),
        ]
        for (name, arguments) in variants {
            for sample in ["risky", "plugged", "shortfall"] {
                let app = openPopover(sample: sample, arguments)
                let attachment = XCTAttachment(screenshot: app.dialogs.firstMatch.screenshot())
                attachment.name = "popover-\(sample)-\(name)"
                attachment.lifetime = .keepAlways
                add(attachment)
                if sample == "risky", name == "it" {
                    captureSettings(app, suffix: "-it")
                }
                app.terminate()
            }
        }
    }

    /// Everything in the popover works from the keyboard: Refresh (⌘R), Settings (⌘,), and Esc closes it.
    @MainActor
    func testKeyboardPath() {
        var app = openPopover(sample: "fine")
        app.typeKey("r", modifierFlags: .command)
        XCTAssertTrue(app.descendants(matching: .any)["statusTitle"].exists)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(app.dialogs.firstMatch.waitForNonExistence(timeout: 3))
        app.terminate()

        app = openPopover(sample: "fine")
        defer { app.terminate() }
        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(app.windows["com_apple_SwiftUI_Settings_window"].waitForExistence(timeout: 5))
    }

    /// Xcode's accessibility audit (VoiceOver labels, roles, contrast, hit regions, clipped text) on every screen.
    /// Settings and the welcome setup page are standard grouped forms: their footers use the system's secondary
    /// label color, which the contrast check flags; that is Apple's styling, kept on purpose.
    @MainActor
    func testAccessibilityAudit() throws {
        for sample in ["risky", "plugged", "shortfall"] {
            let app = openPopover(sample: sample)
            try audit(app, "popover-\(sample)")
            if sample == "risky" {
                app.buttons["openSettings"].click()
                let window = app.windows["com_apple_SwiftUI_Settings_window"]
                XCTAssertTrue(window.waitForExistence(timeout: 5))
                for index in 0 ..< 5 {
                    window.toolbars.buttons.element(boundBy: index).click()
                    try audit(app, "settings-\(index)", contrast: false)
                }
            }
            app.terminate()
        }
        let app = XCUIApplication()
        app.launchArguments = ["-FWSample", "fine", "-onboarded", "NO"]
        app.launch()
        defer { app.terminate() }
        let next = app.buttons["onboardingContinue"]
        for page in ["language", "welcome", "privacy", "setup"] {
            XCTAssertTrue(app.descendants(matching: .any)["onboardingPage-\(page)"].waitForExistence(timeout: 5))
            try audit(app, "onboarding-\(page)", contrast: page != "setup")
            next.click()
        }
    }

    /// Runs the audit, skipping what SwiftUI itself adds and the app cannot label: the Touch Bar placeholder and the
    /// window's root container.
    @MainActor
    private func audit(_ app: XCUIApplication, _ screen: String, contrast: Bool = true) throws {
        let types: XCUIAccessibilityAuditType = contrast ? .all : XCUIAccessibilityAuditType.all.subtracting(.contrast)
        try app.performAccessibilityAudit(for: types) { issue in
            let element = issue.element
            if element?.elementType == .touchBar {
                return true
            }
            // Containers need no description of their own; their children carry it.
            // The MenuBarExtra panel reports a parent/child mismatch with no element once its content passes a
            // certain height, whatever the content (bisected): the system's structure, not a view of ours.
            if issue.auditType == .parentChild, element == nil, screen.hasPrefix("popover") {
                return true
            }
            if issue.auditType == .sufficientElementDescription, [.group, .dialog].contains(element?.elementType) {
                return true
            }
            print("AUDIT", screen, issue.compactDescription, "|",
                  element.map { "\($0.elementType.rawValue) \($0.label) \($0.frame)" } ?? "nil")
            return false
        }
    }

    /// The battery health and disk rows open their pages inside the popover; Esc and the back button return to the
    /// overview, the popover stays open. Screenshots of each health basis (measured, cycles, charge limit, still
    /// learning: no chart) and the disk page in English, both pages in Italian, German and dark; the accessibility
    /// audit on both pages.
    @MainActor
    func testDetailPages() throws {
        let variants = [
            ("en", Self.english, ["risky", "fine", "plugged", "learning"]),
            ("it", Self.italian, ["risky"]),
            ("de", Self.german, ["risky"]),
            ("en-dark", Self.english + Self.dark, ["risky"]),
        ]
        for (name, arguments, samples) in variants {
            for sample in samples {
                let app = openPopover(sample: sample, arguments)
                let popover = app.dialogs.firstMatch
                let title = app.descendants(matching: .any)["statusTitle"]
                app.descendants(matching: .any)["batteryHealth"].click()
                XCTAssertTrue(app.descendants(matching: .any)["healthHeadline"].waitForExistence(timeout: 3))
                XCTAssertEqual(app.descendants(matching: .any)["healthChart"].exists, sample != "learning")
                XCTAssertTrue(title.waitForNonExistence(timeout: 3))
                shoot(popover, "health-\(sample)-\(name)")
                if name == "en", ["risky", "learning"].contains(sample) {
                    try audit(app, "page-health-\(sample)")
                }
                // The info button beside the cycles explains the design count and the outlook's basis, on request.
                let explanation = app.descendants(matching: .any)["cyclesExplanation"]
                XCTAssertFalse(explanation.exists)
                app.descendants(matching: .any)["cyclesInfo"].click()
                XCTAssertTrue(explanation.waitForExistence(timeout: 3))
                if sample == "risky" {
                    shoot(popover, "health-explained-\(name)")
                }
                app.typeKey(.escape, modifierFlags: [])
                XCTAssertTrue(title.waitForExistence(timeout: 3))
                XCTAssertTrue(popover.exists)

                if ["risky", "learning"].contains(sample) {
                    app.descendants(matching: .any)["disk"].click()
                    XCTAssertTrue(app.descendants(matching: .any)["diskHeadline"].waitForExistence(timeout: 3))
                    shoot(popover, "disk-\(sample)-\(name)")
                    if name == "en" {
                        try audit(app, "page-disk-\(sample)")
                    }
                    app.buttons["back"].click()
                    XCTAssertTrue(title.waitForExistence(timeout: 3))
                }
                app.terminate()
            }
        }
    }

    @MainActor
    private func shoot(_ element: XCUIElement, _ name: String) {
        // Wait for the slide to settle: the screenshot is for the design review.
        Thread.sleep(forTimeInterval: 0.6)
        let attachment = XCTAttachment(screenshot: element.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// The language list: "Same as System" first, then the languages with their flags; typing filters it.
    /// Nothing is picked: a new language restarts the app.
    @MainActor
    func testLanguagePickerFilters() {
        let app = XCUIApplication()
        app.launchArguments = ["-FWSample", "fine", "-onboarded", "NO"] + Self.english
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.descendants(matching: .any)["onboardingPage-language"].waitForExistence(timeout: 5))
        let window = app.windows["welcome"]
        app.activate() // a window behind another app's would screenshot that app instead
        var shot = XCTAttachment(screenshot: window.screenshot())
        shot.name = "onboarding-language"
        shot.lifetime = .keepAlways
        add(shot)

        app.buttons["languagePicker"].click()
        let search = app.textFields["languageSearch"]
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS 'Italiano'")).firstMatch.exists)
        shot = XCTAttachment(screenshot: app.popovers.firstMatch.screenshot())
        shot.name = "language-list"
        shot.lifetime = .keepAlways
        add(shot)

        search.typeText("deu")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS 'Deutsch'")).firstMatch.exists)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label CONTAINS 'Italiano'")).firstMatch.exists)
        app.typeKey(.escape, modifierFlags: [])
    }
}

// MARK: - Settings › About

@MainActor
extension MenuBarUITests {
    /// Settings › About: version, release notes and license texts in sheets, closed with Done or Esc.
    func testAboutPane() throws {
        for (name, arguments) in [("en", Self.english), ("de", Self.german), ("en-dark", Self.english + Self.dark)] {
            let app = openPopover(sample: "fine", arguments)
            app.buttons["openSettings"].click()
            let window = app.windows["com_apple_SwiftUI_Settings_window"]
            XCTAssertTrue(window.waitForExistence(timeout: 5))
            window.toolbars.buttons.element(boundBy: 0).click() // General, shorter than About
            Thread.sleep(forTimeInterval: 0.6) // the window's resize animation
            let middle = window.frame.midY
            window.toolbars.buttons.element(boundBy: 4).click() // About, the last pane
            XCTAssertTrue(app.descendants(matching: .any)["aboutVersion"].waitForExistence(timeout: 3))
            Thread.sleep(forTimeInterval: 0.6)
            // The window grows around its middle, not down from its top edge.
            XCTAssertEqual(window.frame.midY, middle, accuracy: 2)
            shoot(window, "settings-About-\(name)")

            app.buttons["whatsNew"].click()
            let text = app.descendants(matching: .any)["documentText"]
            XCTAssertTrue(text.waitForExistence(timeout: 3))
            shoot(app.sheets.firstMatch, "about-whatsNew-\(name)")
            if name == "en" {
                // Contrast off: it would measure the grouped form's footers in the Settings window behind the sheet,
                // the system styling kept on purpose (see testAccessibilityAudit).
                try audit(app, "about-whatsNew", contrast: false)
            }
            app.buttons["documentDone"].click()
            XCTAssertTrue(text.waitForNonExistence(timeout: 3))

            app.buttons["license-forewarn"].click()
            XCTAssertTrue(text.waitForExistence(timeout: 3))
            app.typeKey(.escape, modifierFlags: [])
            XCTAssertTrue(text.waitForNonExistence(timeout: 3))
            app.terminate()
        }
    }
}
