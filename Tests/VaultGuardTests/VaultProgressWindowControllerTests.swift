import XCTest
@testable import VaultGuard

final class VaultProgressWindowControllerTests: XCTestCase {

    private var controller: VaultProgressWindowController!

    override func setUp() {
        super.setUp()
        controller = VaultProgressWindowController(title: "Test Operation…")
    }

    override func tearDown() {
        if controller.isVisible { controller.dismiss() }
        controller = nil
        super.tearDown()
    }

    // MARK: - Initial state

    func testWindowTitleIsVaultGuard() {
        XCTAssertEqual(controller.window?.title, "VaultGuard")
    }

    func testTitleLabelReflectsInitArg() {
        XCTAssertEqual(controller.titleLabel.stringValue, "Test Operation…")
    }

    func testInitialStatusLabelText() {
        XCTAssertEqual(controller.statusLabel.stringValue, "Preparing…")
    }

    func testInitialProgressBarIsIndeterminate() {
        XCTAssertTrue(controller.progressBar.isIndeterminate,
                      "Progress bar should start indeterminate before any update()")
    }

    func testPanelNotVisibleBeforeShow() {
        XCTAssertFalse(controller.isVisible,
                       "Panel must not be visible before show() is called")
    }

    func testPanelIsFloating() {
        XCTAssertTrue(controller.window?.isFloatingPanel == true)
    }

    // MARK: - show / dismiss

    func testShowMakesPanelVisible() {
        controller.show()
        XCTAssertTrue(controller.isVisible, "Panel should be visible after show()")
    }

    func testDismissOnMainThreadClosesPanelImmediately() {
        controller.show()
        XCTAssertTrue(controller.isVisible)

        controller.dismiss()          // synchronous on main thread

        XCTAssertFalse(controller.isVisible,
                       "dismiss() on main thread must close the panel immediately, not deferred")
    }

    func testDismissWithoutShowDoesNotCrash() {
        XCTAssertFalse(controller.isVisible)
        XCTAssertNoThrow(controller.dismiss(),
                         "dismiss() without a prior show() must not crash")
    }

    func testMultipleShowCallsDoNotCrash() {
        controller.show()
        controller.show()   // idempotent — already ordered front
        XCTAssertTrue(controller.isVisible)
    }

    func testDismissCalledFromBackgroundClosesPanel() {
        controller.show()
        XCTAssertTrue(controller.isVisible)

        let exp = expectation(description: "background dismiss")
        DispatchQueue.global().async {
            self.controller.dismiss()       // background path → DispatchQueue.main.async
            DispatchQueue.main.async {
                XCTAssertFalse(self.controller.isVisible,
                               "Panel must be closed after dismiss() from a background thread")
                exp.fulfill()
            }
        }
        wait(for: [exp], timeout: 2)
    }

    // MARK: - update()

    func testUpdateSwitchesProgressBarToDeterminate() {
        let exp = expectation(description: "update dispatched to main")

        controller.update(fraction: 0.5, status: "Copying…")

        // update() dispatches to main async; run after that block completes
        DispatchQueue.main.async {
            XCTAssertFalse(self.controller.progressBar.isIndeterminate,
                           "Progress bar should switch to determinate after first update()")
            XCTAssertEqual(self.controller.progressBar.doubleValue, 0.5, accuracy: 0.001)
            XCTAssertEqual(self.controller.statusLabel.stringValue, "Copying…")
            exp.fulfill()
        }

        wait(for: [exp], timeout: 2)
    }

    func testUpdateFractionClampedWithinRange() {
        let exp = expectation(description: "fraction clamped")

        controller.update(fraction: 1.0, status: "Done")

        DispatchQueue.main.async {
            XCTAssertLessThanOrEqual(self.controller.progressBar.doubleValue, 1.0)
            XCTAssertGreaterThanOrEqual(self.controller.progressBar.doubleValue, 0.0)
            exp.fulfill()
        }

        wait(for: [exp], timeout: 2)
    }

    func testUpdateCalledTwiceKeepsLatestValues() {
        let exp = expectation(description: "two updates")

        controller.update(fraction: 0.3, status: "Step 1")
        controller.update(fraction: 0.7, status: "Step 2")

        DispatchQueue.main.async {
            XCTAssertEqual(self.controller.progressBar.doubleValue, 0.7, accuracy: 0.001)
            XCTAssertEqual(self.controller.statusLabel.stringValue, "Step 2")
            exp.fulfill()
        }

        wait(for: [exp], timeout: 2)
    }

    func testUpdateDoesNotShowPanelByItself() {
        let exp = expectation(description: "panel stays hidden")

        controller.update(fraction: 0.5, status: "Working…")

        DispatchQueue.main.async {
            XCTAssertFalse(self.controller.isVisible,
                           "update() alone must not show the panel — show() must be called explicitly")
            exp.fulfill()
        }

        wait(for: [exp], timeout: 2)
    }

    // MARK: - Show → update → dismiss lifecycle

    func testFullLifecycle() {
        controller.show()
        XCTAssertTrue(controller.isVisible)

        let exp = expectation(description: "update then dismiss")
        controller.update(fraction: 1.0, status: "Complete")

        DispatchQueue.main.async {
            XCTAssertFalse(self.controller.progressBar.isIndeterminate)
            self.controller.dismiss()
            XCTAssertFalse(self.controller.isVisible,
                           "Panel must be gone immediately after dismiss() on main thread")
            exp.fulfill()
        }

        wait(for: [exp], timeout: 2)
    }
}
