# Upstream synchronization

The fork keeps `origin` on `joshan-kana/FineTune` and tracks portable upstream changes from `ronitsingh10/FineTune` through the scheduled **Upstream synchronization** workflow.

The workflow first compares `upstream/main` with `origin/main`. A run with no upstream-only commits exits without creating a branch, pull request, or CI run. When changes exist, it recreates `automation/upstream-sync` from the fork's current `main`, merges upstream, and maintains one open pull request. The required CI workflow is dispatched explicitly for that branch, and guarded auto-merge is enabled so GitHub performs the merge only after required checks pass.

Merge conflicts create one open issue titled **Upstream sync requires manual resolution** and stop before pushing a branch or dispatching CI. A later successful synchronization closes that issue. Fork-specific identity, packaging, and release decisions remain reviewable in the synchronization pull request.

The **Flake update** workflow follows the same one-PR and explicit-CI pattern for `flake.lock`. It exits without a commit or pull request when the lock file is unchanged.
