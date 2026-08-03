# Troubleshooting

- If `xcodebuild` reports that Command Line Tools are selected, install full Xcode and set `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.
- If audio is silent after adding an effect, inspect its compatibility line. Unsupported layouts fail open and should leave the dry signal intact.
- If the fork does not capture audio, grant Screen & System Audio Recording permission to the fork bundle in System Settings → Privacy & Security.
- Use `nix run .#logs -- --live` for unified logs and `nix run .#legacy-audio-check` to inspect, without changing, old virtual audio devices.
- Use the printed rollback backup path if an installation validation fails. Settings are not removed by uninstall.
