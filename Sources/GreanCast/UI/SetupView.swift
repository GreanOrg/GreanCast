// SetupView.swift
// First-run assistant: shows each prerequisite with its status and how to fix it.

import SwiftUI

struct SetupView: View {
    @ObservedObject var session: DeviceSession
    @State private var checking = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Set up GreanCast").font(.largeTitle.bold())
                    Text("GreanCast drives your iPhone through WebDriverAgent, Apple's UI-testing engine. It needs a few developer prerequisites, checked below.")
                        .foregroundStyle(.secondary)
                }

                CheckRow(ok: session.xcodeVersion != nil,
                         title: "Xcode",
                         detail: session.xcodeVersion ?? "Full Xcode is required (Command Line Tools are not enough).") {
                    if session.xcodeVersion == nil {
                        Link("Get Xcode", destination: URL(string: "macappstore://apps.apple.com/app/xcode/id497799835")!)
                    }
                }

                CheckRow(ok: session.selectedTeam != nil,
                         title: "Apple developer team",
                         detail: session.teams.isEmpty
                            ? "Add your Apple ID in Xcode › Settings › Accounts. A free account works but must re-sign every 7 days."
                            : "Used to sign WebDriverAgent for your iPhone. GreanCast registers an app ID (greancast.wda.<team>) and this iPhone in the team you choose.") {
                    if !session.teams.isEmpty {
                        Picker("Team", selection: $session.teamID) {
                            if session.selectedTeam == nil { Text("Choose a team…").tag("") }
                            ForEach(session.teams) { Text($0.label).tag($0.id) }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 360)
                    }
                }

                CheckRow(ok: session.selectedPhone != nil && (session.usbAttached || session.useWiFi),
                         title: "iPhone connected",
                         detail: phoneDetail) {
                    if session.phones.count > 1 {
                        Picker("iPhone", selection: $session.udid) {
                            ForEach(session.phones, id: \.udid) { Text("\($0.name) — iOS \($0.osVersion)").tag($0.udid) }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 360)
                    }
                }

                CheckRow(ok: session.selectedPhone?.developerMode ?? false,
                         title: "Developer Mode",
                         detail: "On the iPhone: Settings › Privacy & Security › Developer Mode, then restart it.") { EmptyView() }

                GroupBox {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("On first launch", systemImage: "info.circle").font(.headline)
                        Text("GreanCast downloads WebDriverAgent (~5 MB), builds it with your team and installs it on the iPhone. Then, on the iPhone, trust your certificate in Settings › General › VPN & Device Management.")
                        Text("Unlock the iPhone before connecting: WebDriverAgent can't type your passcode. Once connected, GreanCast keeps it awake (toolbar ☕️ button).")
                    }
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack {
                    Button {
                        checking = true
                        Task { await session.refreshChecks(); checking = false }
                    } label: { Label("Check again", systemImage: "arrow.clockwise") }
                    if checking { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Continue") { session.start() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!session.prerequisitesMet)
                }
            }
            .padding(32)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
    }

    private var phoneDetail: String {
        guard let p = session.selectedPhone else { return "Connect your iPhone with a cable and tap “Trust” on it." }
        if session.usbAttached { return "\(p.name) — iOS \(p.osVersion), connected over USB." }
        if session.useWiFi { return "\(p.name) — iOS \(p.osVersion), using Wi‑Fi (see Settings)." }
        return "\(p.name) is known but not connected over USB. Plug in the cable."
    }
}

private struct CheckRow<Accessory: View>: View {
    let ok: Bool
    let title: String
    let detail: String
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.title2)
                .foregroundStyle(ok ? Color.green : Color.orange)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                accessory()
            }
            Spacer(minLength: 0)
        }
    }
}
