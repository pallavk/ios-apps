import XCTest
@testable import PocketTray

@MainActor
final class AppLockTests: XCTestCase {
    private final class Settings: AppLockSettings {
        var isAppLockEnabled: Bool

        init(isEnabled: Bool = false) {
            isAppLockEnabled = isEnabled
        }
    }

    private final class Authenticator: AppAuthenticating {
        var results: [Bool]
        private(set) var requestCount = 0

        init(results: [Bool]) {
            self.results = results
        }

        func authenticate() async -> Bool {
            requestCount += 1
            return results.isEmpty ? false : results.removeFirst()
        }
    }

    func testAppLockIsOffAndUnlockedByDefault() {
        let controller = AppLockController(
            settings: Settings(),
            authenticator: Authenticator(results: [])
        )

        XCTAssertFalse(controller.isEnabled)
        XCTAssertFalse(controller.isLocked)
    }

    func testEnablingRequiresSuccessfulAuthentication() async {
        let settings = Settings()
        let authenticator = Authenticator(results: [true])
        let controller = AppLockController(settings: settings, authenticator: authenticator)

        await controller.setEnabled(true)

        XCTAssertTrue(settings.isAppLockEnabled)
        XCTAssertTrue(controller.isEnabled)
        XCTAssertFalse(controller.isLocked)
        XCTAssertEqual(authenticator.requestCount, 1)
    }

    func testFailedEnableLeavesAppLockOff() async {
        let settings = Settings()
        let controller = AppLockController(
            settings: settings,
            authenticator: Authenticator(results: [false])
        )

        await controller.setEnabled(true)

        XCTAssertFalse(settings.isAppLockEnabled)
        XCTAssertFalse(controller.isEnabled)
        XCTAssertFalse(controller.isLocked)
        XCTAssertNotNil(controller.errorMessage)
    }

    func testEnabledAppLocksInBackgroundAndRetryCanUnlock() async {
        let settings = Settings(isEnabled: true)
        let authenticator = Authenticator(results: [false, true])
        let controller = AppLockController(settings: settings, authenticator: authenticator)

        XCTAssertTrue(controller.isLocked)
        await controller.unlock()
        XCTAssertTrue(controller.isLocked)
        XCTAssertNotNil(controller.errorMessage)

        await controller.unlock()
        XCTAssertFalse(controller.isLocked)
        XCTAssertNil(controller.errorMessage)

        controller.sceneDidEnterBackground()
        XCTAssertTrue(controller.isLocked)
    }

    func testDisablingUnlocksWithoutAnotherAuthentication() async {
        let settings = Settings(isEnabled: true)
        let authenticator = Authenticator(results: [true])
        let controller = AppLockController(settings: settings, authenticator: authenticator)
        await controller.unlock()

        await controller.setEnabled(false)

        XCTAssertFalse(settings.isAppLockEnabled)
        XCTAssertFalse(controller.isEnabled)
        XCTAssertFalse(controller.isLocked)
        XCTAssertEqual(authenticator.requestCount, 1)
    }
}
