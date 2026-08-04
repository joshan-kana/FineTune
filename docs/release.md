# Fork releases

Releases are published by `.github/workflows/release.yml` on a `vMAJOR.MINOR.PATCH` tag or by manually dispatching the workflow with an exact tag input. A manually selected tag is validated against the selected commit; a new tag is created at that commit by the GitHub release API.

The workflow runs the complete Nix check and package commands, publishes the DMG, ZIP, checksums, and build metadata, and attests the packaged artifacts. Re-running a release updates an existing release and replaces its assets instead of creating a duplicate.

Fork artifacts are ad-hoc signed and are not notarized. Users may need to approve the app and grant Screen & System Audio Recording permission on first launch. The authoritative installation path is the repository's Nix workflow; release downloads are linked from the fork README when artifacts are available.
