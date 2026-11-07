# Contributing to Reclaim

Thanks for helping out! Bug reports, new cleanup categories and fixes are all welcome.

## Getting started

You need macOS 14+ and a Swift 6 toolchain. Building with the Liquid Glass APIs needs the macOS 26 SDK (Xcode 26 or the matching Command Line Tools).

```sh
git clone https://github.com/Unfield/Reclaim.git
cd Reclaim
./scripts/test.sh                 # run the tests
swift run reclaim scan            # try the CLI
./scripts/build-app.sh && open build/Reclaim.app
```

No Xcode project is needed; everything is a Swift package. You can also open `Package.swift` in Xcode.

## Ground rules for cleanup code

Reclaim deletes files, so safety comes first:

- **Never widen what can be deleted without a guard.** Category cleanup only removes *direct children* of a category's roots. The uninstaller only touches `.app` bundles in Applications folders and known `~/Library` locations. Keep it that way, and add a test when you touch this code.
- **Be honest with safety levels.** `Safe` means the data is rebuilt automatically with no loss. If it costs a re-download, use `Review`. If it might hold personal data, use `Caution`.
- **Category roots must not overlap.** A test checks this. If a subfolder is handled elsewhere (like Homebrew's cache), use `excludedNames`.
- **Prefer a tool's own cleanup command** (e.g. `brew cleanup`) over deleting its files directly.

## Adding things

- **A file category:** add it to `CategoryCatalog.all(home:oldDownloadsDays:)` in `Sources/ReclaimCore/CategoryCatalog.swift`. Then give it an SF Symbol in `CleanupCategory.symbolName` and a chart colour in `ChartPalette`, both in `Sources/ReclaimApp/Views/Components.swift`.
- **A maintenance tool:** conform to `MaintenanceTool` (see `Sources/ReclaimCore/Tools/`) and register it in `ToolCatalog.all()`. Put output parsing in `static` functions and add tests with sample output.
- **User-facing text:** the app is translated (English and German, in `Localization/*.lproj`). SwiftUI literals like `Text("…")` are localized automatically; text built as a `String` (alerts, notifications, computed messages, anything in `ReclaimCore`) needs `String(localized: "…")`. Write whole sentences rather than gluing fragments together. Then add the German translation to `Localization/de.lproj/Localizable.strings` (or `.stringsdict` if it depends on a count) and run `./scripts/check-localization.py`, which lists missing keys and mismatched format specifiers. The CLI stays English.

## Pull requests

- Keep PRs focused, and describe how you tested them.
- `./scripts/test.sh` must pass (CI runs it too).
- Match the existing style: small types, no force-unwraps in core code, and comments that explain *why*.

## Releasing (maintainers)

1. Bump `ReclaimInfo.version` in `Sources/ReclaimCore/Version.swift`.
2. Move the `Unreleased` notes in `CHANGELOG.md` under the new version.
3. Commit, then tag and push: `git tag v0.4.0 && git push origin main v0.4.0`.

The **Release** workflow tests, builds a universal app, and publishes the DMG, zip, CLI tarball and checksums to GitHub Releases.

### Signing and notarization (optional)

Without these secrets, releases are ad-hoc signed and users have to right-click → Open the first time. To ship notarized builds, add these repository secrets:

| Secret | Value |
| --- | --- |
| `MACOS_CERTIFICATE` | Base64 of your *Developer ID Application* `.p12` (`base64 -i cert.p12 \| pbcopy`) |
| `MACOS_CERTIFICATE_PASSWORD` | Password of the `.p12` |
| `DEVELOPER_ID` | Identity name, e.g. `Developer ID Application: Jane Doe (ABCDE12345)` |
| `NOTARY_APPLE_ID` | Apple ID email |
| `NOTARY_TEAM_ID` | Team ID |
| `NOTARY_PASSWORD` | App-specific password for that Apple ID |
