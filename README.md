# GreanCast

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
cd greancast
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

## Security

WebDriverAgent runs an **unauthenticated** HTTP server on the iPhone. GreanCast always uses it over USB through loopback-only ports. However, **WebDriverAgent itself also listens on the iPhone's Wi‑Fi interface while it runs**: anyone on the same network could control the phone during that time. GreanCast stops WebDriverAgent when you quit. Avoid untrusted networks while a session is active. The optional Wi‑Fi mode in Settings has the same caveat. See [SECURITY.md](SECURITY.md).

## Troubleshooting

| Symptom | Fix |
|---|---|
| "Program License Agreement" during build | Accept the new agreement at developer.apple.com/account for that team |
| "Unlock … to Continue" | Unlock the iPhone, then *Device › Reconnect* (⌘R) |
| Runner installed but never starts | Trust the certificate: *Settings › General › VPN & Device Management* |
| Works once, fails a week later | Free account: *Settings › Advanced › Rebuild WebDriverAgent* |
| Anything else | *Settings › Advanced › Open Log File* (`~/Library/Logs/GreanCast.log`) |

## Contributing

[![CI](https://github.com/GreanOrg/GreanCast/actions/workflows/ci.yml/badge.svg)](https://github.com/GreanOrg/GreanCast/actions/workflows/ci.yml)

Issues and pull requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) and our [Code of Conduct](CODE_OF_CONDUCT.md).

## License

GreanCast is released under the [MIT License](LICENSE). WebDriverAgent is BSD-licensed and is downloaded at runtime, not bundled; see [NOTICE](NOTICE).

"GreanCast" and "Grean" are trademarks of Grean ([TRADEMARKS.md](TRADEMARKS.md)). iPhone and Xcode are trademarks of Apple Inc. GreanCast is not affiliated with or endorsed by Apple.
