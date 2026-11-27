# Contributing to GreanCast

Thanks for your interest!

## Build and run

Open `GreanCast.xcodeproj` in **Xcode 16 or later** and press ⌘R. Or, from a terminal:

```bash
make run        # Release build → build/GreanCast.app, then open it
make debug      # Debug build
make selftest   # connect to the plugged-in iPhone, measure fps and latency, save a frame, exercise the MCP server
make icon       # regenerate the app icon from scripts/make-icon.swift
```

### Signing

- **No Apple account:** the project builds and runs as is. It is signed to run locally (ad-hoc).
- **With your certificate:** copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig` (git-ignored) and set your `DEVELOPMENT_TEAM`. With a stable signature, macOS remembers the app's permissions (such as Local Network, used in Wi‑Fi mode) across rebuilds. `make` also picks your *Apple Development* certificate automatically.

Don't commit your team ID in `project.pbxproj`: build settings live in `Config/GreanCast.xcconfig`.

## Project layout

The Xcode project uses a **synchronized folder**: every file under `Sources/GreanCast` is part of the app target automatically. Add or move files on disk; you don't need to edit `project.pbxproj`, which avoids merge conflicts.

| Path | Contents |
|---|---|
| `Sources/GreanCast/App` | Entry point, menus, Settings scene |
| `Sources/GreanCast/Transport` | `usbmuxd` client and loopback port relay |
| `Sources/GreanCast/WDA` | WebDriverAgent HTTP client, MJPEG stream, fetch/build/run manager |
| `Sources/GreanCast/Setup` | Prerequisite checks (Xcode, teams, devices) |
| `Sources/GreanCast/Session` | `DeviceSession`: connection flow and command queue |
| `Sources/GreanCast/MCP` | Built-in MCP server: HTTP listener, protocol router, tool catalog and execution, settings |
| `Sources/GreanCast/UI` | Mirror view (input mapping), main window, setup assistant, settings |
| `Sources/GreanCast/Assets.xcassets` | App icon and accent color |
| `Resources` | `Info.plist`, entitlements (not copied as resources) |
| `Config` | Build settings (`GreanCast.xcconfig`), optional `Local.xcconfig` |
| `scripts` | Icon generator, release script (Developer ID + notarization + DMG) |

## Workflow

1. Fork the repository and create a branch from `main` (e.g. `fix/scroll-speed`).
2. Make your change, build it, and test it on a real iPhone (`make selftest`).
3. Open a pull request against `main` and fill in the template. CI checks that the Debug and universal Release builds compile without warnings.
4. A maintainer reviews it. Pull requests are squash-merged, so one PR becomes one commit on `main`.

For larger changes, please open an issue first to discuss the approach.

## Guidelines

- Keep the app dependency-free (Apple frameworks only). WebDriverAgent is fetched at runtime at a pinned revision (`WDAManager.pinnedCommit`).
- When you bump the WDA revision, run `make selftest` on a real device and mention the iOS/Xcode versions you tested in the PR.
- Report measured latencies, not estimates.
- By contributing, you agree that your contributions are licensed under the MIT License.
