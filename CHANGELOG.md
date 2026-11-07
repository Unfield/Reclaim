# Changelog

All notable changes to Reclaim are listed here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

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
