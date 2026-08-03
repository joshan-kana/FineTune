import XCTest

final class FineTuneUITests: XCTestCase {
    @MainActor
    func testApplicationLaunches() {
        let application = XCUIApplication()
        application.launchEnvironment["FINETUNE_UI_TESTING"] = "1"
        application.launch()

        // FineTune is an accessory/menu-bar application, so XCTest reports it
        // as running in the background even while its menu bar item is active.
        XCTAssertTrue(application.wait(for: .runningBackground, timeout: 10))
    }
}
