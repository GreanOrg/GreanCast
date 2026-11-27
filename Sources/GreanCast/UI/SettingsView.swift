// SettingsView.swift
// Settings window (⌘,): device, team, transport, maintenance, and the MCP server (MCPSettingsView).

import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject var session: DeviceSession

    var body: some View {
        TabView {
            Form {
                Picker("iPhone", selection: $session.udid) {
                    ForEach(session.phones, id: \.udid) { Text("\($0.name) — iOS \($0.osVersion)").tag($0.udid) }
                }
                Picker("Developer team", selection: $session.teamID) {
                    ForEach(session.teams) { Text($0.label).tag($0.id) }
                }
                Section {
                    Toggle("Keep the iPhone awake while connected", isOn: $session.keepAwake)
                } footer: {
                    Text("After 20 s without commands, GreanCast sends an empty hardware-keyboard event that resets the iPhone's Auto-Lock timer. Nothing is typed and nothing changes on screen. Your Auto-Lock setting is not modified, and it applies again as soon as GreanCast disconnects.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Toggle("Use Wi‑Fi instead of USB", isOn: $session.useWiFi)
                    TextField("WebDriverAgent URL", text: $session.wifiURL)
                        .disabled(!session.useWiFi)
                } footer: {
                    Text("USB is used whenever the cable is plugged in. Over Wi‑Fi, WebDriverAgent accepts commands from anyone on the network without authentication: only use it on networks you trust.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Button("Reconnect") { session.start() }
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("General", systemImage: "gearshape") }

            Form {
                Section {
                    LabeledContent("WebDriverAgent revision", value: String(WDAManager.pinnedCommit.prefix(10)))
                    Button("Rebuild WebDriverAgent") { session.rebuildWDA() }
                    Button("Show Support Folder in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([WDAManager.supportDir])
                    }
                    Button("Open Log File") { NSWorkspace.shared.open(Log.shared.fileURL) }
                } footer: {
                    Text("Rebuild after updating Xcode or iOS, or when the signing profile expires.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }

            MCPSettingsView()
                .tabItem { Label("MCP", systemImage: "sparkles") }
        }
        .frame(width: 520, height: 480)
        .task { await session.refreshChecks() }
    }
}

extension DeviceSession {
    /// Deletes the build for the current team and starts over (fetch is kept).
    func rebuildWDA() {
        shutdown()
        try? FileManager.default.removeItem(at: WDAManager.derivedData(team: teamID))
        Log.shared.info("WebDriverAgent build for team \(teamID) removed — rebuilding")
        start()
    }
}
