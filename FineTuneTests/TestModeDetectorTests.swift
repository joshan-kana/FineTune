import Foundation
import Testing
@testable import FineTune

@Suite("Test mode detection")
struct TestModeDetectorTests {

    @Test("recognises the explicit UI-testing flag")
    func explicitUITestingFlag() {
        #expect(FineTuneRuntimeMode.isUITesting(environment: ["FINETUNE_UI_TESTING": "1"]))
        #expect(!FineTuneRuntimeMode.isUITesting(environment: ["FINETUNE_UI_TESTING": "0"]))
    }

    @Test("does not treat an absent UI-testing flag as UI testing")
    func absentUITestingFlag() {
        #expect(!FineTuneRuntimeMode.isUITesting(environment: [:]))
    }
}
