# Launch Posts

Drafts for the TidyMac v0.1.0 launch. Paste verbatim or tweak before posting. Recommended order: Hacker News first (weekday morning, 9–11 ET), then X thread, then LinkedIn. Cross-link the HN post on X and LinkedIn if it gets traction.

---

## Hacker News

**Title:** Show HN: TidyMac – Free, open-source CleanMyMac alternative

**Text:**

Hi HN, I built TidyMac — a free, open-source Mac maintenance tool. Native SwiftUI, no Electron.

Features: system junk scanner, app uninstaller with remnant detection across 12+ Library locations, large-and-old-files finder with multi-axis filtering, circle-packing disk visualizer (Space Lens), Launch Agent / Daemon manager with broken/orphaned/hung-app detection, maintenance tasks, and an honest health scoring system.

"Honest" because CleanMyMac subtracts points for active app caches existing, which makes the user think they need to clean constantly. TidyMac only flags stale data from uninstalled or unused apps — active caches are healthy and don't reduce your score.

Architecture: MVVM, a `ScanModule` protocol that all modules conform to (so Smart Scan orchestrates them through one pipeline with bulkhead error isolation), XPC-based privileged helper for root-level cleanup, and a three-layer security model for the helper:

1. macOS kernel validates code signatures of both binaries.
2. XPC connection-level check rejects callers whose code requirement doesn't match TidyMac signed by our team.
3. The helper's own path validator: every path resolved through symlinks before checking against an allowlist + denylist (denylist wins on conflict). The symlink resolution prevents a TOCTOU race where `/Library/Caches/foo → /System/Library/Kernels/kernel` could redirect a delete into a protected location.

Built this as a CE learning project — each feature maps to OS concepts (launchd, APFS, Spotlight `MDQuery`, TCC permissions, code signing chains). I used Claude Code for implementation and Claude for architecture and systems design.

GitHub: https://github.com/countingaces/TidyMac

Install: `brew tap countingaces/tap && brew install --cask tidymac`

Looking for feedback on the security architecture especially. The privileged helper's allowlist/denylist approach and the TOCTOU protections are where I want the most scrutiny.

---

## X (Twitter) thread

**Tweet 1**

I built a free, open-source alternative to CleanMyMac.

CleanMyMac costs $48–$120/year and inflates your "health score" to make you clean files that should exist.

TidyMac does the same job honestly. Native SwiftUI, source on GitHub.

🧵

**Tweet 2**

What it does:
- Scans system junk (caches, logs, Xcode artifacts, iOS backups)
- Uninstalls apps completely (finds orphans across 12+ Library locations)
- Visualizes disk usage with interactive circle packing
- Manages Launch Agents (flags broken + suspicious ones)
- Honest health scoring

**Tweet 3**

The thing I'm most proud of: the health score.

CleanMyMac subtracts points for active app caches.

That's like a doctor scoring you unhealthy because you ate lunch.

TidyMac only counts stale caches from uninstalled apps. Your score reflects actual system health.

**Tweet 4**

Built as a learning project for computer engineering concepts:
- macOS boot sequence + launchd
- XPC inter-process communication
- Code signing chains + privilege escalation
- APFS + Spotlight indexing
- TCC permissions

Each feature taught me something about how the OS actually works.

**Tweet 5**

Free, open source (MIT), no telemetry, no upsells.

GitHub: https://github.com/countingaces/TidyMac

Install: `brew tap countingaces/tap && brew install --cask tidymac`

Contributions welcome.

---

## LinkedIn

**I built a free, open-source alternative to CleanMyMac.**

CleanMyMac costs up to $120/year. It inflates your "health score" by penalizing normal system caches to make you think your Mac needs cleaning. Its malware scanner fails standard detection tests. Every scan ends with an upsell.

So I built TidyMac — an open-source Mac maintenance tool that does the same job honestly:

→ System junk scanner that only shows files it can actually delete (no silent failures)
→ App uninstaller that finds every orphaned file across 12+ Library locations
→ Circle-packing disk visualizer (Space Lens equivalent)
→ Large & Old Files finder with multi-axis filtering
→ Launch Agent manager with security heuristics for detecting broken or suspicious background processes
→ Health scoring that doesn't subtract points for caches that are supposed to exist
→ Completely free, no telemetry, no upsells

Built as a native SwiftUI macOS app with MVVM architecture, an XPC-based privileged helper for root-level cleanup, and a modular scanner protocol that makes adding new cleanup modules trivial.

I built this as a computer engineering learning project — each feature taught me something about how macOS works under the hood: the boot sequence, launchd process management, APFS file systems, Spotlight metadata queries, code signing chains, and inter-process communication.

The code is at github.com/countingaces/TidyMac — contributions welcome.

#opensource #macos #swiftui #computerengineering

---

## Posting tips

- **Hacker News:** Tuesday–Thursday, 9–11 AM ET. The Show HN tag is required for product posts. Don't editorialize the title beyond what the spec suggests.
- **X:** Post the thread mid-morning ET. Pin Tweet 1 to your profile for the launch week.
- **LinkedIn:** Tuesday–Thursday morning. Tag the platforms / tools you used (#swiftui, #opensource) but keep them at the bottom — the body should read as a story.
- **Cross-linking:** Once HN gets traction, quote-post the HN link on X and add a comment to your LinkedIn post pointing to it. The HN link is signal — it tells your professional network "this got reviewed by technical strangers and survived."
- **Don't post on Friday afternoon or weekends.**
