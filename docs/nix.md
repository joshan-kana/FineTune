# Nix workflow

The flake pins Nixpkgs, treefmt-nix, and git-hooks inputs. It supports aarch64-darwin and x86_64-darwin, with Linux evaluation for static tooling. Full Xcode remains a host input because Apple does not redistribute it through Nix.

`nix run .#build` writes disposable output under `.build`. `nix build .#FineTune --impure --option sandbox false` produces `result/Applications/FineTune.app` when full Xcode is selected. The derivation prints the Xcode and SDK versions, uses a temporary home, disables automatic signing during compilation, then ad-hoc signs and verifies the copied app.

The build and test wrappers disable SwiftPM's manifest sandbox explicitly for full-Xcode package resolution. This keeps the FluidMenuBarExtra and other package targets on the same path under current Xcode versions; the resolved package graph remains pinned in `FineTune.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`.

For a local installation, run `nix run .#doctor` followed by `nix run .#install`. The install command validates the build and test first, backs up any existing fork app under `~/Library/Application Support/FineTune/Backups/`, and ad-hoc signs the installed copy. It does not remove audio devices or FineTune settings.
