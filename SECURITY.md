# Security

## Threat model

GreanCast controls an iPhone through WebDriverAgent (WDA), an XCUITest-based HTTP server running on the device. Anyone who can reach that server can do what the user can do on the unlocked phone: tap, type, read the screen and open apps.

| Component | Exposure | Mitigation |
|---|---|---|
| WDA on the iPhone, port 8100 (commands) and 9100 (video) | Listens on **all** iPhone interfaces while it runs, including Wi‑Fi, **without authentication** | GreanCast stops WDA when it quits. Avoid untrusted Wi‑Fi during a session. |
| GreanCast's USB relay | Local ports bound to **127.0.0.1 only** | Not reachable from the network. Other local processes on the Mac can use it while GreanCast runs. |
| Optional Wi‑Fi mode | Plain HTTP over the LAN | Disabled by default; the Settings window shows a warning. |
| Built-in MCP server, this Mac | Plain HTTP on **127.0.0.1** (port 8765 by default), **without authentication**: any process of any user on the Mac can see the screen and control the iPhone | Disabled by default. Requests with a non-local `Origin` or `Host` are refused, so a web page cannot reach it (DNS rebinding). Each kind of action has its own switch in Settings › MCP. |
| Built-in MCP server, local network | Plain HTTP on all interfaces. The URL contains a 128-bit random token; whoever has the URL has full access, and the traffic (screen included) is not encrypted | Disabled by default, separately from local access. Only private and link-local source addresses are accepted. The token can be regenerated. Use trusted networks only. |

### MCP clients

An AI client connected to the MCP server acts with the permissions enabled in Settings › MCP, on whatever the iPhone shows. Text on the iPhone screen (a web page, a message, a notification) reaches the model and can try to steer it (prompt injection). Leave "Install apps" and "Read and write the clipboard" off unless you need them, review what your client is allowed to do without confirmation, and turn the server off when you don't use it. Every tool call is written to the log (inspector and `~/Library/Logs/GreanCast.log`).

Planned: a patched WDA build that binds to the loopback interface on the iPhone, so that it is reachable only through USB.

## Reporting a vulnerability

Please report vulnerabilities privately through GitHub Security Advisories on the GreanOrg/GreanCast repository, rather than in a public issue.
