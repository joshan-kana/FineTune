# Release

Tag or manually dispatch the release workflow after CI is green. It builds the Universal 2 app, runs tests, produces DMG/ZIP/checksum/metadata artifacts, and publishes a GitHub release. Metadata includes commit, upstream commit, version, Xcode, SDK, architecture, date, signature type, and test result.

Local development artifacts are ad-hoc signed. This project does not claim Developer ID signing or notarization unless a future release has actually performed and verified those steps.
