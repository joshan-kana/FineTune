# Build and install

```bash
cd /Users/joshan/repos/FineTune
direnv allow
nix run .#doctor
nix run .#check
nix run .#build
nix build .#FineTune --impure --option sandbox false
nix run .#install
```

The install command requires a successful doctor, release build, tests, and signature verification. It backs up an existing `/Applications/FineTune.app` under `~/Library/Application Support/FineTune/Backups/<timestamp>/` before replacing it. The fork bundle identifier is `com.joshankana.FineTune`; macOS may require audio-recording permission again.
