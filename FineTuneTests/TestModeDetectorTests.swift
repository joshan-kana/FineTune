import Foundation
import Testing
@testable import FineTune

@Suite("Test mode detection")
struct TestModeDetectorTests {

    @Test("recognises the explicit UI-testing flag")
    func explicitUITestingFlag() {
        #expect(TestModeDetector.isRunning(in: ["FINETUNE_UI_TESTING": "1"]))
        #expect(!TestModeDetector.isRunning(in: ["FINETUNE_UI_TESTING": "0"]))
    }

    @Test("recognises the XCTest hosted-process environment")
    func xctestHostedProcess() {
        let environment = ["XCTestConfigurationFilePath": "/tmp/FineTune.xctestconfiguration"]

        #expect(TestModeDetector.isRunning(in: environment))
    }

    @Test("does not treat an absent or empty marker as test mode")
    func absentOrEmptyMarkers() {
        #expect(!TestModeDetector.isRunning(in: [:]))
        #expect(!TestModeDetector.isRunning(in: ["XCTestConfigurationFilePath": ""]))
    }
}
