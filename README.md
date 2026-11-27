# GreanCast

**English** | [Français](README.fr.md)

**Control your iPhone from your Mac.** See its screen live, click to tap, drag to swipe, type with your Mac keyboard.

GreanCast is an open-source macOS app for developers. It's similar to [scrcpy](https://github.com/Genymobile/scrcpy) on Android, but for iPhone. It drives the iPhone through [WebDriverAgent](https://github.com/appium/appium-ios/tree/main/packages/webdriveragent), a server maintained by Appium that is built on Apple's XCUITest framework. The default connection is a USB cable.

> Status: early preview (0.1). Tested on macOS 27.2 + Xcode 27 with an iPhone 17 Pro on iOS 27.3.

## Why GreanCast

GreanCast is made by **[Grean](https://www.grean.fr)**. Grean is a tool for qualifying real estate and boats, to keep track of them over time or to sell them.

We build and test apps all day. With an iPhone on the desk, that means taking your hands off the keyboard, grabbing the phone, tapping through, typing on a tiny keyboard, then going back to the Mac. We wanted the iPhone **inside a Mac window**: click through a flow, type test data with a real keyboard, paste from the clipboard, grab a screenshot, all without leaving the Mac.

Our first idea was to make the Mac pretend to be a Bluetooth keyboard and mouse for the iPhone. It doesn't work: macOS refuses to publish the Bluetooth HID service, just like iOS does. Apple's iPhone Mirroring isn't available everywhere (not in the EU, for one). The existing open-source options were automation servers or browser-based tools, not a simple native app. So we built GreanCast on top of WebDriverAgent for our own use.

It quickly became part of how we code and test. We figured other developers have the same phone on the same desk, so we're sharing it. Feedback, issues and pull requests are very welcome.

## Features

- Live screen mirror (MJPEG, ~25–30 fps)
- Click → tap, long click → long press, drag → finger path, scroll wheel/trackpad → scroll
- Typing from the Mac keyboard. Accents, dead keys (^ e → ê), ⌥ combos and ⌘V (paste the Mac clipboard) all work, whatever the iPhone's keyboard layout.
- Home, App Switcher, Control Center, volume, open an app by bundle ID, copy a screenshot
- **USB by default:** ~1 ms transport round trip, no Wi‑Fi needed, nothing exposed on the network
- Setup assistant: checks Xcode, your Apple developer team, the iPhone and Developer Mode. It then downloads, builds, signs and launches WebDriverAgent for you.
- **Keep awake:** while connected, GreanCast stops the iPhone from auto-locking without changing its settings (on by default, toolbar ☕️ button)
- Lock-screen detection, with a wake & unlock button for iPhones without a passcode
- **Built-in MCP server:** let an AI assistant (Claude Code, Codex, Cursor, VS Code…) see the iPhone and use it — see [AI assistants](#ai-assistants-mcp-server)

## Limitations (read this first)

- **Latency.** Each action takes **~0.3–0.5 s**: tap ≈ 440 ms, typing ≈ 320 ms per burst, Home ≈ 50 ms. That time is spent inside XCTest on the iPhone; the transport isn't the bottleneck. GreanCast is comfortable for remote control, demos and testing, but not for games.
- **Start with the iPhone unlocked.** WebDriverAgent can't type a passcode. Once connected, *Keep awake* stops Auto-Lock from kicking in. It works by sending an empty hardware-keyboard event (HID usage 0x07/0x00) after 20 s without commands: nothing is typed and nothing changes on screen. Locking the iPhone yourself (side button) still works.
- **No arrow keys.** WebDriverAgent can't synthesize navigation keys.
- **The on-screen keyboard hides while you type.** Typing goes through a simulated hardware keyboard, so iOS hides the on-screen keyboard and may highlight the focused field with the app's tint color. A tap brings the keyboard back.

## Requirements

| | |
|---|---|
| Mac | macOS 14 or later |
| Xcode | **Full Xcode** (not only the Command Line Tools), with your Apple ID added in *Xcode › Settings › Accounts* |
| Apple account | Free or paid. Free accounts must re-sign WebDriverAgent **every 7 days**; paid accounts last a year. |
| iPhone | Connected with a cable and trusted ("Trust This Computer"), **Developer Mode** on (*Settings › Privacy & Security*) |

The first launch signs WebDriverAgent with your team and installs it on the iPhone. After that, trust your certificate on the iPhone in *Settings › General › VPN & Device Management*.

## Install

### From source

```bash
git clone https://github.com/GreanOrg/GreanCast.git
cd GreanCast
make run
```

Or open `GreanCast.xcodeproj` in Xcode 16 or later and press ⌘R.

`make` builds `build/GreanCast.app` with `xcodebuild`. It signs with your *Apple Development* certificate if you have one, so macOS keeps the app's permissions across rebuilds. Otherwise it signs to run locally (ad-hoc), and no Apple account is needed to build. In Xcode, put your team in `Config/Local.xcconfig` (see `Config/Local.xcconfig.example`).

### Prebuilt

Signed and notarized DMGs will be published on the Releases page.

## How it works

```
Mac (GreanCast)                                  iPhone
┌─────────────────────┐   usbmuxd (USB)    ┌─────────────────────────────┐
│ mirror view / input ├──127.0.0.1:x ─────►│ WebDriverAgent :8100 (HTTP) │
│ MJPEG decoder       │◄─127.0.0.1:y ──────┤ MJPEG stream   :9100        │
│ xcodebuild (runner) ├───── Xcode ───────►│ XCUITest runner             │
└─────────────────────┘                    └─────────────────────────────┘
```

1. **WebDriverAgent** is fetched at a pinned revision into `~/Library/Application Support/GreanCast/`. It is built with `xcodebuild build-for-testing`, signed with your team, and started with `xcodebuild test-without-building`. The runner's bundle ID is `greancast.wda.<team id>`.
2. **Transport:** GreanCast talks to `usbmuxd` (the same protocol as `iproxy`) and relays two local ports, bound to 127.0.0.1 only, to the iPhone's ports 8100 and 9100.
3. **Input:** clicks and drags become W3C pointer actions, typing goes through `/wda/keys` (batched while a request is in flight), and hardware buttons use WDA's dedicated endpoints.

## AI assistants (MCP server)

GreanCast includes a [Model Context Protocol](https://modelcontextprotocol.io) server, so an AI coding assistant can look at the iPhone and operate it while the app is open. There is nothing to install and no login.

1. Open **Settings › MCP** and turn on **Allow AI clients on this Mac**.
2. Add the server to your client. Settings shows the commands, ready to copy:

   ```sh
   claude mcp add --transport http greancast http://127.0.0.1:8765/mcp   # Claude Code
   codex mcp add greancast --url http://127.0.0.1:8765/mcp               # Codex
   ```

   Cursor, VS Code and other clients take the same URL in their MCP configuration (type `http`).
3. Ask for something: "take a screenshot of the iPhone", "open Settings and go to General".

| Tools | What they do |
|---|---|
| `screenshot`, `screenshot_with_metadata` | The screen as a JPEG, served from the live video stream; optionally with device, iOS version, frontmost app, time, connection, resolution, orientation, battery |
| `describe_ui`, `wait_for` | The on-screen elements (labels, values, frames) from the accessibility tree; wait for an element to appear |
| `tap`, `tap_element`, `swipe`, `type_text` | Tap, double tap or long press at coordinates, tap an element by its label, drag or scroll, type |
| `press_button` | Home, volume, App Switcher, Control Center, lock |
| `list_apps`, `launch_app`, `terminate_app`, `app_state`, `open_url` | Installed apps, open or close one, open a web link or deep link |
| `get_alert`, `accept_alert`, `dismiss_alert`, `set_orientation`, `dismiss_keyboard` | Alerts, rotation, keyboard |
| `get_clipboard`, `set_clipboard`, `install_app` | Off by default: the iPhone clipboard, and installing a `.app`/`.ipa` from the Mac |

Coordinates are in pixels of the screenshot. Action tools accept `screenshot: true` to return the screen after the action in the same call.

Each group of tools has its own switch in Settings › MCP; a tool that is turned off is hidden from clients. **Allow AI clients on the local network** makes the server reachable from other computers through a URL that contains a secret token. The server speaks Streamable HTTP only: clients that can only launch local commands (stdio), such as the Claude desktop app, are not supported yet.

## Security

WebDriverAgent runs an **unauthenticated** HTTP server on the iPhone. GreanCast always uses it over USB through loopback-only ports. However, **WebDriverAgent itself also listens on the iPhone's Wi‑Fi interface while it runs**: anyone on the same network could control the phone during that time. GreanCast stops WebDriverAgent when you quit. Avoid untrusted networks while a session is active. The optional Wi‑Fi mode in Settings has the same caveat.

The MCP server is off by default. Once enabled, any program on the Mac can see and control the iPhone through it, without authentication; over the network, anyone who has the URL can. See [SECURITY.md](SECURITY.md).

## Troubleshooting

| Symptom | Fix |
|---|---|
| "Program License Agreement" during build | Accept the new agreement at developer.apple.com/account for that team |
| "Unlock … to Continue" | Unlock the iPhone, then *Device › Reconnect* (⌘R) |
| Runner installed but never starts | Trust the certificate: *Settings › General › VPN & Device Management* |
| AI client can't reach the MCP server | Check *Settings › MCP*: the server must be on, and the port must match the URL in your client. "Port … already in use" means another program has it: choose another port |
| Network clients get no answer | Allow GreanCast under *System Settings › Privacy & Security › Local Network*, then restart it |
| Works once, fails a week later | Free account: *Settings › Advanced › Rebuild WebDriverAgent* |
| Anything else | *Settings › Advanced › Open Log File* (`~/Library/Logs/GreanCast.log`) |

## Contributing

[![CI](https://github.com/GreanOrg/GreanCast/actions/workflows/ci.yml/badge.svg)](https://github.com/GreanOrg/GreanCast/actions/workflows/ci.yml)

Issues and pull requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) and our [Code of Conduct](CODE_OF_CONDUCT.md).

## License

GreanCast is released under the [MIT License](LICENSE). WebDriverAgent is BSD-licensed and is downloaded at runtime, not bundled; see [NOTICE](NOTICE).

"GreanCast" and "Grean" are trademarks of Grean ([TRADEMARKS.md](TRADEMARKS.md)). iPhone and Xcode are trademarks of Apple Inc. GreanCast is not affiliated with or endorsed by Apple.
