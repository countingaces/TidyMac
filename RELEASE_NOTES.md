# TidyMac 0.1.0 — Initial Release

A free, open-source Mac maintenance tool. Native SwiftUI, no telemetry, no upsells.

## Features

- **Smart Scan** with honest health scoring (active app caches don't count against you).
- **System Junk Scanner** — caches, logs, Xcode build artifacts, iOS device backups, broken preferences.
- **Space Lens** — interactive circle-packing disk visualization, click into directories to drill down.
- **App Uninstaller** — removes apps and every associated file across 12+ Library locations. Detects orphans from apps you've already deleted.
- **Large & Old Files** — multi-axis filtering (kind / size tier / access date) with dependent facet counts.
- **Optimization** — login items + Launch Agents and Daemons. Flags broken, orphaned, and hung apps. Per-row enable/disable, batch removal.
- **Maintenance** — purgeable space (Time Machine snapshot thinning), DNS flush, Spotlight reindex, Mail index rebuild, font cache clear. Each task has a dry-run preview.
- **Menu Bar Widget** — health-score summary plus live CPU / memory / disk stats. Persists when the main window is closed.
- **Privileged helper architecture** — XPC, kernel-level code signing validation, allowlist/denylist with symlink-resolution-before-check (TOCTOU-safe). Requires a Developer ID to deploy as root; without one, all user-owned cleanup still works.

## Requirements

- macOS 14.0 (Sonoma) or later
- Full Disk Access recommended for complete scanning (System Settings → Privacy & Security → Full Disk Access)

## Installation

### Homebrew

```bash
brew tap countingaces/tap
brew install --cask tidymac
```

### Manual

Download `TidyMac-0.1.0.zip`, unzip, and drag `TidyMac.app` to your Applications folder.

This release is **not code-signed or notarized**. macOS will block the first launch with a "TidyMac Not Opened — Apple could not verify…" dialog. To get past it:

- **macOS 15+:** Dismiss the dialog, open **System Settings → Privacy & Security**, scroll to the "TidyMac was blocked…" row, and click **Open Anyway**.
- **macOS 14:** Right-click the app in `/Applications` and choose **Open** from the context menu.
- **Power users:** `xattr -d com.apple.quarantine /Applications/TidyMac.app` skips the dialog entirely.

macOS remembers the decision; subsequent launches don't prompt.

## Known Limitations

- The privileged helper can't be deployed without an Apple Developer ID. Admin-required items (root-owned caches, system logs) appear with an "Admin" badge and can be skipped or installed-helper-prompted from the UI.
- No localization yet — English only.
- No unit tests yet — see [CONTRIBUTING.md](CONTRIBUTING.md) if that's your kind of contribution.

## What's Next

Notarized .dmg distribution, a Homebrew tap that updates with each release, additional scan modules driven by community PRs.

---

Source: <https://github.com/countingaces/TidyMac>
