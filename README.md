<div align="center">

<img src="docs/icon.png" width="128" height="128" alt="Reclaim icon">

# Reclaim

**Free, open-source disk cleanup for macOS.** Find out what's eating your disk, then clean it up safely.

[![CI](https://github.com/Unfield/Reclaim/actions/workflows/ci.yml/badge.svg)](https://github.com/Unfield/Reclaim/actions/workflows/ci.yml)
[![Latest release](https://img.shields.io/github/v/release/Unfield/Reclaim?sort=semver)](https://github.com/Unfield/Reclaim/releases/latest)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black)

[**Download**](https://github.com/Unfield/Reclaim/releases/latest) · [Features](#features) · [Command line](#command-line-tool) · [Contributing](CONTRIBUTING.md)

<img src="docs/screenshot.png" width="820" alt="Reclaim overview">

</div>

## Install

1. Download **Reclaim-x.y.z.dmg** from the [latest release](https://github.com/Unfield/Reclaim/releases/latest).
2. Open it and drag **Reclaim** to **Applications**.
3. The first time, **right-click Reclaim → Open → Open**. Releases aren't notarized by Apple yet, so macOS asks once. If it says the app is "damaged", run:
   ```sh
   xattr -dr com.apple.quarantine /Applications/Reclaim.app
   ```
4. Optional, for complete results: add Reclaim under **System Settings → Privacy & Security → Full Disk Access**.

It's a universal app for Apple silicon and Intel and needs macOS 14 or later. It gets the Liquid Glass look on macOS 26.

## Features

- **Smart cleanup:** caches, logs, Trash, Xcode data, Simulator caches and package-manager caches. Each category is labelled **Safe**, **Review** or **Caution**, and only Safe items are preselected.
- **Developer tools:** Homebrew cleanup, Docker pruning (containers, images, build cache, volumes) and Time Machine local snapshots.
- **App uninstaller:** finds apps you haven't opened in months and removes them along with their leftover support files.
- **Space Explorer:** drill into any folder or disk to see what's using space, with sizes filling in live.
- **Large Files:** finds the biggest files anywhere.
- **Memory:** live memory pressure and the apps using the most RAM, with one-click Quit. There's also an optional cache purge. It comes without the usual "RAM cleaner" snake oil: Reclaim explains what actually helps.
- **Every disk:** usage for internal, external and network disks, cleanup of each disk's own Trash, and an Eject button.
- **Menu bar:** disk usage at a glance, one-click cleanup, and a notification when space runs low.
- **Command-line tool:** everything is also scriptable from Terminal.

### What it cleans

| Category | Safety |
| --- | --- |
| App caches (`~/Library/Caches`) | Safe |
| Logs | Safe |
| Trash (all disks) | Safe, permanent |
| Xcode DerivedData, Simulator caches | Safe |
| Homebrew downloads & old versions | Safe |
| Mail downloads, device support files, package-manager caches | Review |
| Docker unused data | Review |
| Time Machine local snapshots | Review |
| iPhone/iPad backups, Xcode archives, old downloads | Caution |

## Safety

Reclaim is careful by design:

- **Files go to the Trash by default.** Permanent deletion is opt-in.
- Category cleanup only removes items **directly inside** known cache and data folders. It never removes the folders themselves or anything outside them.
- The uninstaller only touches `.app` bundles in Applications folders and support files matched by **exact bundle ID** in `~/Library`. Apple apps are never offered.
- Tool cleanups (Homebrew, Docker, tmutil) use **each tool's own commands**.
- Nothing runs as root unless you approve the standard macOS password prompt.
- Everything happens **on your Mac**. No network access, no analytics, no accounts.

## Command-line tool

The CLI is included in each release (`reclaim-cli-*.tar.gz`), or you can build it yourself.

```sh
reclaim status                       # usage for all disks
reclaim scan --details               # what can be reclaimed
reclaim clean --all-safe --dry-run   # preview
reclaim clean xcode-derived-data docker --all-images
reclaim apps --days 180              # apps unused for 6 months
reclaim uninstall "Some App"         # app + support files to the Trash
reclaim explore ~/Library            # what's using space here
reclaim large / --min 2GB            # big files anywhere
reclaim memory                       # memory pressure + heaviest apps
```

Run `reclaim help` for every option, and `reclaim list` for the category and tool IDs.

## Build from source

You need macOS 14+ and Swift 6 with the macOS 26 SDK (Xcode 26, or the matching Command Line Tools).

```sh
git clone https://github.com/Unfield/Reclaim.git && cd Reclaim
./scripts/test.sh                  # tests
./scripts/build-app.sh             # build/Reclaim.app and build/reclaim
./scripts/build-app.sh --install   # ...and copy the app to /Applications
./scripts/package.sh               # release DMG, zip and CLI tarball in dist/
```

### Project layout

```
Sources/
  ReclaimCore/     Scanning, sizing, cleaning, disks, apps, tools (no UI)
  reclaim/         Command-line tool
  ReclaimApp/      SwiftUI app, menu bar, settings
Tests/             Swift Testing suites
scripts/           build, package, test, icon generation
.github/           CI and release workflows
```

## Contributing

Contributions are welcome, especially new cleanup categories with good safety reasoning. See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[MIT](LICENSE)
