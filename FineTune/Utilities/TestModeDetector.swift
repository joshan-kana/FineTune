import Foundation

enum FineTuneRuntimeMode {
    private static let uiTestingEnvironmentKey = "FINETUNE_UI_TESTING"

    #if FINETUNE_TESTING
    static let isTestHost = true
    #else
    static let isTestHost = false
    #endif

    static func isUITesting(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        environment[uiTestingEnvironmentKey] == "1"
    }
}
