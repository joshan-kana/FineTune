# Testing

Unit tests cover existing DSP behavior, Audio Unit persistence/hosting, layout descriptions, channel capability matching, and fail-open behavior. `FineTuneAudioProbe`/`nix run .#audio-probe -- --layout 7.1` provides deterministic channel markers for manual output verification.

Integration checks should exercise multiple applications, per-app and per-device chain ordering, output switching, hot-plug, sleep/wake, sample-rate changes, and 2.0/5.1/7.1 LPCM. Apple system Audio Units are used in automated tests; third-party plugin tests remain manual.
