# Nix workflow

The flake pins Nixpkgs, treefmt-nix, and git-hooks inputs. It supports aarch64-darwin and x86_64-darwin, with Linux evaluation for static tooling. Full Xcode remains a host input because Apple does not redistribute it through Nix.

`nix run .#build` writes disposable output under `.build`. `nix build .#FineTune --impure --option sandbox false` produces `result/Applications/FineTune.app` when full Xcode is selected. The derivation prints the Xcode and SDK versions, uses a temporary home, disables automatic signing during compilation, then ad-hoc signs and verifies the copied app.
