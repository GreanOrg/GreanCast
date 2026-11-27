// GreanCastApp.swift
// Entry point: one window, a Device menu with keyboard shortcuts, a Settings window, and the
// built-in MCP server (off until enabled in Settings).

import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    var onTerminate: (() -> Void)?
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { onTerminate?() }
}

@main
struct GreanCastApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var session = DeviceSession()
    @StateObject private var mcp = MCPServer()

    var body: some Scene {
        Window("GreanCast", id: "main") {
            MainView(session: session)
                .environmentObject(mcp)
                .onAppear {
                    // Stop WebDriverAgent when the app quits: it would otherwise keep listening.
                    appDelegate.onTerminate = { [session, mcp] in
                        MainActor.assumeIsolated { mcp.stop(); session.shutdown() }
                    }
                    session.start()
                    mcp.attach(session)
                    SelfTest.runIfRequested(session, mcp: mcp)
                }
        }
        .defaultSize(width: 480, height: 940)
        .commands {
            CommandMenu("Device") {
                Button("Home") { session.home() }.keyboardShortcut("h", modifiers: [.command, .shift])
                Button("App Switcher") { session.appSwitcher() }.keyboardShortcut("a", modifiers: [.command, .shift])
                Button("Control Center") { session.controlCenter() }
                Divider()
                Button("Volume Up") { session.volume(up: true) }.keyboardShortcut(.upArrow, modifiers: [.command, .option])
                Button("Volume Down") { session.volume(up: false) }.keyboardShortcut(.downArrow, modifiers: [.command, .option])
                Divider()
                Toggle("Keep iPhone Awake", isOn: $session.keepAwake)
                Divider()
                Button("Copy Screenshot") { session.copyScreenshot() }.keyboardShortcut("c", modifiers: [.command, .shift])
                Button("Reconnect") { session.start() }.keyboardShortcut("r", modifiers: .command)
            }
        }

        Settings {
            SettingsView(session: session)
                .environmentObject(mcp)
        }
    }
}
