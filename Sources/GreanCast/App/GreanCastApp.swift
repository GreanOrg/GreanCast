// GreanCastApp.swift
// Entry point: one window, a Device menu with keyboard shortcuts, and a Settings window.

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

    var body: some Scene {
        Window("GreanCast", id: "main") {
            MainView(session: session)
                .onAppear {
                    // Stop WebDriverAgent when the app quits: it would otherwise keep listening.
                    appDelegate.onTerminate = { [session] in
                        MainActor.assumeIsolated { session.shutdown() }
                    }
                    session.start()
                    SelfTest.runIfRequested(session)
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
                Button("Copy Screenshot") { session.copyScreenshot() }.keyboardShortcut("c", modifiers: [.command, .shift])
                Button("Reconnect") { session.start() }.keyboardShortcut("r", modifiers: .command)
            }
        }

        Settings {
            SettingsView(session: session)
        }
    }
}
