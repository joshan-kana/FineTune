import Foundation

enum TestModeDetector {
    private static let uiTestingEnvironmentKey = "FINETUNE_UI_TESTING"
    private static let xctestConfigurationEnvironmentKey = "XCTestConfigurationFilePath"

    #if FINETUNE_TESTING
    static let isCompileTimeTestHost = true
    #else
    static let isCompileTimeTestHost = false
    #endif

    static var isRunning: Bool {
        isRunning(in: ProcessInfo.processInfo.environment)
    }

    static func isRunning(in environment: [String: String]) -> Bool {
        environment[uiTestingEnvironmentKey] == "1"
            || !(environment[xctestConfigurationEnvironmentKey]?.isEmpty ?? true)
    }

    static func isUITesting(in environment: [String: String]) -> Bool {
        environment[uiTestingEnvironmentKey] == "1"
    }

    static var xctestClassesLoaded: Bool {
        NSClassFromString("XCTestCase") != nil
    }

    static var xctestBundlesLoaded: Bool {
        (Bundle.allBundles + Bundle.allFrameworks).contains {
            $0.pathExtension == "xctest"
        }
    }
}
