# Upstream synchronization

`upstream/main` is the source of current upstream history. The scheduled workflow updates `automation/upstream-sync`, aborts on conflicts, records the two SHAs in an issue, and explicitly dispatches CI for the automation branch. It never alters `main` directly.

Flake input updates use the separate weekly `automation/flake-update` branch. This separation keeps source integration and toolchain updates independently reviewable.
