import XCTest

final class QuotioIOSUITests: XCTestCase {
    @MainActor
    private func card(_ app: XCUIApplication, containing text: String) -> XCUIElement {
        app.buttons.containing(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    @MainActor func testFirstLaunchHasWorkingSharedStorage() {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.buttons["Explore demo"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Saved connections could not be loaded."].exists)
    }

    @MainActor func testDemoNavigationPrivacyAndConnectionForm() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--blur-account-names", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.buttons["Demo Mac"].waitForExistence(timeout: 10))
        XCTAssertTrue(card(app, containing: "39 percent remaining").exists)
        // Healthy state shows no connection banner.
        XCTAssertFalse(app.buttons["Retry"].exists)
        app.tabBars.buttons["Settings"].tap()
        let blurAccountNames = app.switches["Blur account names"]
        XCTAssertEqual(blurAccountNames.value as? String, "1")
        app.tabBars.buttons["Usage"].tap()
        let firstCard = card(app, containing: "39 percent remaining")
        XCTAssertTrue(firstCard.exists)
        let accountName = firstCard.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.2))
        accountName.tap()
        XCTAssertTrue(app.buttons["Demo Mac"].exists)
        let revealedAttachment = XCTAttachment(screenshot: app.screenshot())
        revealedAttachment.name = "One account name revealed"
        revealedAttachment.lifetime = .keepAlways
        add(revealedAttachment)
        accountName.tap()
        let toggledBackAttachment = XCTAttachment(screenshot: app.screenshot())
        toggledBackAttachment.name = "Account name blurred by second tap"
        toggledBackAttachment.lifetime = .keepAlways
        add(toggledBackAttachment)
        accountName.tap()
        app.tabBars.buttons["Settings"].tap()
        app.tabBars.buttons["Usage"].tap()
        let privacyAttachment = XCTAttachment(screenshot: app.screenshot())
        privacyAttachment.name = "Account name blurred again after leaving Usage"
        privacyAttachment.lifetime = .keepAlways
        add(privacyAttachment)
        app.tabBars.buttons["Settings"].tap()
        app.buttons["Add computer"].tap()
        XCTAssertTrue(app.buttons["Scan pairing code"].waitForExistence(timeout: 3))
        app.buttons["Advanced: HTTPS proxy"].tap()
        XCTAssertTrue(app.secureTextFields["Read-only device token"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["Connect"].isEnabled)
        app.buttons["Cancel"].tap()
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor func testChangingProviderScrollsToTop() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        XCTAssertTrue(app.buttons["Demo Mac"].waitForExistence(timeout: 10))
        let first = card(app, containing: "39 percent remaining")
        let top = first.frame.minY
        app.swipeUp()
        XCTAssertLessThan(first.frame.minY, top - 20)

        app.buttons["Codex"].tap()
        XCTAssertTrue(first.waitForExistence(timeout: 3))
        XCTAssertEqual(first.frame.minY, top, accuracy: 2)

        app.swipeUp()
        XCTAssertLessThan(first.frame.minY, top - 20)
        app.buttons["All"].tap()
        XCTAssertEqual(first.frame.minY, top, accuracy: 2)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Usage returned to top after changing provider"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor func testDemoShowsMenuBarParityAndLastCardClearsTabBar() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.buttons["Demo Mac"].waitForExistence(timeout: 10))
        // Credits, truncated percent, plan and grouped quotas from the menu bar are visible.
        let amp = card(app, containing: "Plan Megawatt")
        for _ in 0..<3 where !amp.isHittable { app.swipeUp() }
        XCTAssertTrue(amp.label.contains("Orb usage, 47 percent remaining"), amp.label)
        XCTAssertTrue(amp.label.contains("$136.57"), amp.label)
        let factory = card(app, containing: "Factory")
        for _ in 0..<4 where !factory.isHittable { app.swipeUp() }
        XCTAssertTrue(factory.label.contains("Standard"), factory.label)
        XCTAssertTrue(factory.label.contains("Core"), factory.label)
        XCTAssertTrue(factory.label.contains("0 percent remaining"), factory.label)

        for _ in 0..<6 { app.swipeUp() }
        let last = card(app, containing: "Not loaded yet")
        XCTAssertTrue(last.waitForExistence(timeout: 3))
        XCTAssertLessThanOrEqual(last.frame.maxY, app.tabBars.firstMatch.frame.minY)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Bottom of usage list"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor func testOfflineShowsExactlyOneConnectionMessage() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--offline", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.buttons["Retry"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons.matching(identifier: "Retry").count, 1)
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label == %@", "Can't reach your Mac")).count, 1)
        // Cards keep the last good data and do not repeat the error.
        XCTAssertTrue(card(app, containing: "39 percent remaining").exists)
        app.staticTexts["Can't reach your Mac"].tap()
        XCTAssertTrue(app.staticTexts["Make sure your Mac is awake and Quotio is running."].waitForExistence(timeout: 3))
    }
}
