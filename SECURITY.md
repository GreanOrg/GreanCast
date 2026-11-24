# Security

## Threat model

GreanCast controls an iPhone through WebDriverAgent (WDA), an XCUITest-based HTTP server running on the device. Anyone who can reach that server can do what the user can do on the unlocked phone: tap, type, read the screen and open apps.

| Component | Exposure | Mitigation |
|---|---|---|
| WDA on the iPhone, port 8100 (commands) and 9100 (video) | Listens on **all** iPhone interfaces while it runs, including Wi‑Fi, **without authentication** | GreanCast stops WDA when it quits. Avoid untrusted Wi‑Fi during a session. |
| GreanCast's USB relay | Local ports bound to **127.0.0.1 only** | Not reachable from the network. Other local processes on the Mac can use it while GreanCast runs. |
| Optional Wi‑Fi mode | Plain HTTP over the LAN | Disabled by default; the Settings window shows a warning. |

Planned: a patched WDA build that binds to the loopback interface on the iPhone, so that it is reachable only through USB.

## Reporting a vulnerability

Please report vulnerabilities privately through GitHub Security Advisories on the GreanOrg/GreanCast repository, rather than in a public issue.
