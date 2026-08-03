# FineTune development guide

FineTune is a GPLv3 macOS menu-bar audio application. The production branch follows `upstream/main`; the fork adds Audio Unit hosting, multichannel processing, and Nix-based build and release tooling.

## Safety and ownership

- Preserve uncommitted work and inspect the worktree before invasive Git operations.
- Keep `origin` on `joshan-kana/FineTune` and `upstream` on `ronitsingh10/FineTune`.
- Never force-push `main`. Automation branches may use `--force-with-lease`.
- Do not erase FineTune settings or remove legacy audio devices before a validated fork installation and explicit review.
- Build outputs belong under `.build/`, package output under `dist/`, and both are disposable.

## Audio callback rules

Code reached by `processAudioCallback` runs on Core Audio's real-time thread. It must not allocate, lock, message Objective-C, log, perform I/O, or block. Audio Unit instances and all scratch buffers are prepared before the callback. Chain replacement uses immutable snapshots and deferred destruction.

Channel roles come from `AudioStreamFormatDescription`, not channel count alone. The Audio Unit order for 5.1 and 7.1 is L, R, C, LFE, Ls, Rs[, Lrs, Rrs]. Unsupported layouts bypass the affected effect and preserve the source buffer.

## Validation

```bash
direnv allow
nix run .#doctor
nix run .#lint
nix run .#check
nix run .#build
nix build .#FineTune --impure --option sandbox false
nix run .#test
nix run .#package
nix run .#install
```

`check`, `doctor`, and `lint` are read-only. `fix`, `format`, `clean`, `install`, and `legacy-audio-fix` are state-changing commands.

## Contributions

Keep commits focused. Retain attribution for the Audio Unit work: “Based in part on the implementation from ronitsingh10/FineTune#305 by @iscle.” Upstream-facing changes should separate fork-specific packaging and identity decisions from portable audio behavior.

## Completion report

Report repository refs, exact validation commands, build/signing status, audio layouts/devices exercised, installation backup path, and genuine remaining limitations. Never describe ad-hoc signing as notarization.
