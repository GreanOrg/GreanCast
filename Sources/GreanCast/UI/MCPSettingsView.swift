// MCPSettingsView.swift
// Settings › MCP: turn the built-in MCP server on for this Mac and/or the local network, copy the
// URL or the command that adds it to an AI client, and choose what clients are allowed to do.

import SwiftUI
import AppKit

struct MCPSettingsView: View {
    @EnvironmentObject private var mcp: MCPServer

    var body: some View {
        // The settings object is owned by the server; observe it directly for the toggles.
        MCPSettingsForm(mcp: mcp, settings: mcp.settings)
    }
}

private struct MCPSettingsForm: View {
    @ObservedObject var mcp: MCPServer
    @ObservedObject var settings: MCPSettings

    var body: some View {
        Form {
            Section {
                Toggle("Allow AI clients on this Mac", isOn: $settings.local)
                Toggle("Allow AI clients on the local network", isOn: $settings.network)
                TextField("Port", value: $settings.port, format: .number.grouping(.never))
                LabeledContent("Status") { status }
            } footer: {
                Text("The MCP server lets an AI assistant see the iPhone screen and control it through GreanCast, while the app is open. There is no login: any program on this Mac can connect once it is enabled. Over the network, the address contains a secret token; anyone who has it can see and control the iPhone, and traffic is not encrypted. Only enable it on networks you trust.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if settings.local {
                Section("Connect a client on this Mac") {
                    CopyRow(title: "URL", value: mcp.localURL)
                    CopyRow(title: "Claude Code", value: "claude mcp add --transport http greancast \(mcp.localURL)")
                    CopyRow(title: "Codex", value: "codex mcp add greancast --url \(mcp.localURL)")
                    CopyRow(title: "Cursor, VS Code…", value: "{ \"greancast\": { \"type\": \"http\", \"url\": \"\(mcp.localURL)\" } }")
                }
            }

            if settings.network {
                Section {
                    if let url = mcp.networkURL {
                        CopyRow(title: "URL", value: url)
                    } else {
                        LabeledContent("URL", value: "This Mac has no local network address")
                    }
                    Button("Regenerate Token") { settings.regenerateToken() }
                } header: {
                    Text("Connect a client on the local network")
                } footer: {
                    Text("macOS asks once whether GreanCast may use the local network; until you allow it (System Settings › Privacy & Security › Local Network), other computers get no answer. Regenerating the token disconnects every client that uses the current address.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section {
                ForEach(MCPPermission.allCases) { permission in
                    Toggle(permission.label, isOn: Binding(get: { settings.allows(permission) },
                                                           set: { settings.set(permission, $0) }))
                }
            } header: {
                Text("Clients may")
            } footer: {
                Text("Tools that are turned off are hidden from clients and refused if called. Changes apply immediately.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private var status: some View {
        switch mcp.state {
        case .stopped:
            Text(settings.isEnabled ? "Starting…" : "Off").foregroundStyle(.secondary)
        case .listening:
            Text("Listening" + (mcp.lastClient.map { " — last client: \($0)" } ?? ""))
        case .failed(let message):
            Text(message).foregroundStyle(.red)
        }
    }
}

/// A value shown in monospace with a button that copies it.
private struct CopyRow: View {
    let title: String
    let value: String

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                Text(value)
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(value, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy")
            }
        }
    }
}
