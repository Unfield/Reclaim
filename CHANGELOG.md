# Changelog

All notable changes to Reclaim are listed here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.5.0] - 2026-11-07

### Added
- **Recently Removed / Undo:** everything Reclaim moves to the Trash (cleanups, uninstalls, explorer, duplicates, projects, leftovers…) can be put back (⌥⌘Z, `reclaim undo`).
- **Exclusions:** "Never Clean This" in category lists, a Settings tab, and `reclaim exclude`.
- **Developer Projects:** finds `node_modules`, `target`, `.venv`, `.build`, Gradle, Pods and other rebuildable folders in projects you haven't touched in a while (`reclaim projects`).
- **App Leftovers:** support files of apps that are no longer installed (`reclaim leftovers`).
- **Duplicates:** identical files verified with SHA-256, clone-aware, always keeping one copy (`reclaim duplicates`).
- **AI Models:** Ollama, LM Studio, Hugging Face, GPT4All and PyTorch models, with per-model removal (`reclaim models`).
- **iCloud Drive:** removes local copies of files you haven't opened in a while. They stay in iCloud (`reclaim icloud`).
- **CPU & Energy:** overall load, thermal state and the busiest apps (`reclaim cpu`).
- **Login Items:** launch agents and daemons, with on/off and removal of broken items (`reclaim login-items`).
- **Disk History:** free space over time with a forecast of when each disk fills up. The Overview shows it too (`reclaim history`).
- **Scheduled cleanup** (daily, weekly or monthly, optionally only when space is low) and an optional weekly summary notification.
- **Space Explorer treemap.**
- New categories: old editor extensions (VS Code, Cursor, Windsurf), old JetBrains IDE data, Android emulator images, Unity cache, leftover installers. New tool: Xcode Simulators.
- Drag an app onto the Applications screen or Reclaim's Dock icon to uninstall it.
- In-app updates (Sparkle), Homebrew cask (`brew install --cask unfield/tap/reclaim`), and the `reclaim` command bundled inside the app.
- German translation, with a Language setting (System Default, English, Deutsch) in Settings → General.
- Collapsible sidebar sections.

### Changed
- Scheduled cleanups never empty the Trash, so everything they remove can be put back.

## [0.4.0] - 2026-11-07

### Added
- Memory screen: memory pressure, an Activity Monitor-style breakdown (app, wired, compressed, cached), swap, and the apps using the most memory, with Quit and Force Quit. A helper process is counted under the app it belongs to.
- "Clear Memory Caches" (`purge`), with an honest explanation of when it helps.
- Memory usage and pressure in the menu bar.
- `reclaim memory` command (`--purge --admin` to clear caches).

### Fixed
- Scanning no longer stalls while a macOS privacy prompt (e.g. for Downloads) is waiting for an answer.

## [0.3.0] - 2026-11-07

First public release.

### Added
- Cleanup categories for app caches, logs, Trash, Mail downloads, iOS backups, Xcode data, Simulator caches, package-manager caches and old downloads.
- Maintenance tools for Homebrew (`brew cleanup`, `autoremove`), Docker (containers, images, build cache, volumes) and Time Machine local snapshots.
- Applications screen: finds unused apps and uninstalls them along with their support files.
- Space Explorer for drilling into folders, and a Large Files finder.
- Multi-disk support: usage for every mounted disk, per-disk Trash cleanup, and an Eject button.
- Menu bar item with disk usage, one-click cleanup of Safe items, and low-space notifications.
- `reclaim` command-line tool with `status`, `scan`, `clean`, `apps`, `uninstall`, `explore` and `large`.
- Liquid Glass design on macOS 26, with fallbacks for macOS 14 and 15.
