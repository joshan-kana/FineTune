// FineTune/Utilities/UpdateManager.swift
import Foundation
import Combine
import Sparkle

/// Keeps the fork's in-app update surface disabled; updates use Nix/GitHub.
@MainActor
final class UpdateManager: NSObject, ObservableObject {
    private let updaterController: SPUStandardUpdaterController

    @Published var canCheckForUpdates = false

    override init() {
        // Create the updater controller without auto-starting (prevents popup on launch)
        updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        super.init()

        // The upstream appcast is intentionally disabled for this fork. Updates
        // are delivered through the pinned Nix/GitHub workflow instead.
        canCheckForUpdates = false
    }

    /// Check for updates manually
    func checkForUpdates() {
        // Fork builds use `nix run .#update-install`; never consult upstream.
    }

    /// Whether automatic update checks are enabled
    var automaticallyChecksForUpdates: Bool {
        get { false }
        set { }
    }

    /// Whether to automatically download updates
    var automaticallyDownloadsUpdates: Bool {
        get { false }
        set { }
    }

    /// Last update check date
    var lastUpdateCheckDate: Date? {
        nil
    }
}
