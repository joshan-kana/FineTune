import Foundation

enum TestModeDetector {
    private static let uiTestingEnvironmentKey = "FINETUNE_UI_TESTING"
    private static let xctestConfigurationEnvironmentKey = "XCTestConfigurationFilePath"

    static var isRunning: Bool {
        isRunning(in: ProcessInfo.processInfo.environment)
    }

    static func isRunning(in environment: [String: String]) -> Bool {
        environment[uiTestingEnvironmentKey] == "1"
            || !(environment[xctestConfigurationEnvironmentKey]?.isEmpty ?? true)
    }
}
