# Getfor

Local-first password manager for macOS and Android.

## Project layout

- `lib/`: Flutter application.
- `native/getfor_core/`: shared Rust core with a stable C ABI.
- `docs/`: architecture decisions and platform research.

## Checks

```sh
flutter analyze
cargo test --manifest-path native/getfor_core/Cargo.toml
```

Platform builds also require the corresponding Rust target. Android builds use Java 17+, NDK 28.2.13676358, Arm64 and x86_64; macOS builds produce an Arm64/x86_64 universal binary.

## CI and releases

GitHub Actions builds Android APKs and universal macOS packages on pushes to `main`, version tags, and pull requests. Download packages from the workflow's artifacts.

To publish a release, change `version` in `pubspec.yaml` (for example, `0.1.1`) and push to `main`. After secret scanning, tests, and both platform builds pass, CI creates `v0.1.1` and publishes the APK, macOS DMG/ZIP, and `SHA256SUMS.txt`. Existing published versions are never overwritten. Versions such as `0.2.0-rc.1` become prereleases. A manually pushed `v*` tag must match `pubspec.yaml`. The optional `+build` suffix sets Flutter's build number; otherwise CI uses its run number.

Android signing requires four repository Secrets: `ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, and `ANDROID_KEY_PASSWORD`. The persistent key must be preserved for APK updates. Pull requests use a temporary debug signing key and never receive signing Secrets.

macOS packages require macOS 26+. The first release is ad-hoc signed and **not notarized**; if macOS blocks it, allow it in System Settings → Privacy & Security. These community packages omit the system AutoFill extension, which needs Developer ID signing and provisioning. Local signed Xcode builds retain the extension. Developer ID signing and notarization will be added separately.

Never commit keystores, Apple signing certificates/profiles, `.env` files, or vault databases. Gitleaks scans the full published history; its configuration only exempts specific code identifiers and a public test vector.
