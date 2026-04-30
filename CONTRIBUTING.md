# Contributing to TidyMac

Thanks for considering a contribution. TidyMac is a free, open-source Mac maintenance tool, and improvements from the community are what keep it honest.

## Building from source

You'll need:

- **Xcode 15** or later
- **macOS 14 (Sonoma)** or later as both build host and deployment target

Clone and open the project:

```bash
git clone https://github.com/countingaces/TidyMac.git
cd TidyMac
open TidyMac.xcodeproj
```

The project has two targets:

- **TidyMac** — the main SwiftUI app
- **TidyMacHelper** — a Command Line Tool that runs as a privileged daemon (built and embedded automatically by the main app's build phases)

A plain Debug build works without any signing setup — Xcode ad-hoc-signs both targets. The helper compiles and embeds correctly, but won't actually run as root without a Developer ID; the main app handles that case gracefully (admin items show an "Install Helper" prompt instead of failing).

## Running tests

There aren't unit tests yet. Adding them is one of the most valuable things you can contribute — see the **Testing** bullet under "Where help is most welcome" below.

A manual smoke test for any change should at minimum:

1. Build the Debug configuration cleanly.
2. Launch the app, confirm Smart Scan, System Junk, and Space Lens all open without crashing.
3. Run a Smart Scan end-to-end and verify the health score appears.
4. Use the menu bar widget — open it, check live stats update, close it, reopen.

## Pull request guidelines

- **Open an issue first** for anything that touches the architecture, adds a new module, changes the privileged helper, or alters the cleaning safety rules. A 5-minute design conversation prevents a 2-day rework.
- **Keep PRs focused.** One concern per PR. If you find an unrelated bug while working, open a separate PR for it.
- **Match the existing style.** No SwiftLint config yet, but follow the conventions you see: explicit type annotations on `@Published` properties, `// MARK:` section dividers, comments that explain *why* (not *what*), and short single-line doc comments only when the WHY is non-obvious.
- **Don't add comments that re-state the code.** Don't include task references in comments (e.g. "added for issue #123") — that's what the PR description is for.
- **Avoid scope creep.** A bug fix doesn't need surrounding refactors; a one-shot helper doesn't need to become a generic utility. Three similar lines is better than a premature abstraction.
- **Update the README** if you add a feature visible to users, change install instructions, or shift permissions/privacy.
- **Reference any issue** the PR closes in the description (`Closes #N`).

## Where help is most welcome

- **New scan categories.** Implement `ScanModuleProtocol` for additional cleanup targets (Mail attachments, browser caches, broken symlinks, etc.).
- **Improved heuristics.** Better detection of orphaned files, suspicious launch agents, or stale data. The orphan detector, the launch-agent classification rules, and the staleness thresholds are all tunable.
- **UI polish.** Animations, accessibility (VoiceOver labels, keyboard navigation), localization, error-state copy.
- **Testing.** Unit tests for scanner logic — especially path validation in the privileged helper, the safety classification of junk items, and the orchestrator's bulkhead error handling.
- **Documentation.** README clarifications, an architecture document, walkthroughs of how each module works.

## What's out of scope

- **Telemetry, analytics, or "anonymous usage data."** TidyMac never phones home. PRs adding any of these will be declined regardless of how they're framed.
- **Malware scanning.** Out of scope by design (see the README's comparison table). Real malware detection needs a maintained threat database.
- **Subscription or paid tiers.** TidyMac is and will remain free.

## Code of conduct

Be kind. Assume the other person is acting in good faith. If you see behavior that violates that standard, raise it in an issue.

---

Thanks for helping make TidyMac better.
